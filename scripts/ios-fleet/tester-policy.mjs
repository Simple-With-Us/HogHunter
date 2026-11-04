// The TestFlight tester policy for one app.
//
// Two policies exist:
//
//   internal-group   the default.  An internal all-builds group holds the
//                    standing testers, so they install every build with no
//                    Beta App Review.  This is what every fleet app had
//                    before a policy existed, and it stays the default.
//
//   public-group     one external group with its public link on holds the
//                    same people, and every new build must be assigned to
//                    that group and submitted for Beta App Review before
//                    anyone can install it.
//
// The policy is per app, named in apps.json.  An app that says nothing about
// its testers keeps the internal group, so adding a policy to one app never
// changes another app's behaviour.
//
// Pure functions only, no I/O: CI can test them without App Store Connect.

export const TESTER_POLICY_INTERNAL = "internal-group";
export const TESTER_POLICY_PUBLIC = "public-group";
export const DEFAULT_TESTER_POLICY = TESTER_POLICY_INTERNAL;

// The name the public group carries when it has to be created.
export const PUBLIC_GROUP_NAME = "Public Beta";

// An unknown value is not a guess: it falls back to the default policy, which
// is the one every app already behaves under.
export function resolveTesterPolicy(value) {
  const raw = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
  if (raw === TESTER_POLICY_PUBLIC) return TESTER_POLICY_PUBLIC;
  if (raw === TESTER_POLICY_INTERNAL) return TESTER_POLICY_INTERNAL;
  return DEFAULT_TESTER_POLICY;
}

// True when the policy keeps an internal all-builds group.
export function policyUsesInternalGroup(policy) {
  return resolveTesterPolicy(policy) === TESTER_POLICY_INTERNAL;
}

export function isExternalGroup(group) {
  return Boolean(group && group.attributes && group.attributes.isInternalGroup === false);
}

export function hasPublicLink(group) {
  return Boolean(group && group.attributes && group.attributes.publicLinkEnabled === true);
}

// The one external group the public policy reuses.
//
// The group whose public link is ON comes first, because that is the group
// that actually distributes builds, and the named group second.  Preferring
// the name first would let a link-off "Public Beta" win over a link-on group,
// and turning its link on would then leave two link-on groups, which is the
// opposite of the one-public-group rule (Kody review on HogHunter PR #259,
// Nov 3 2026).  Null when the app has no external group at all, which is the
// caller's cue to create one.
export function selectPublicGroup(groups) {
  const list = Array.isArray(groups) ? groups : [];
  const external = list.filter(isExternalGroup);
  return (
    external.find(hasPublicLink) ||
    external.find((g) => g && g.attributes && g.attributes.name === PUBLIC_GROUP_NAME) ||
    external[0] ||
    null
  );
}

// The other external groups that still have their public link on.  Under the
// public policy there must be exactly one, so the caller turns the rest off.
export function otherLinkOnGroups(groups, chosen) {
  const list = Array.isArray(groups) ? groups : [];
  return list.filter(
    (g) =>
      isExternalGroup(g) &&
      hasPublicLink(g) &&
      !(chosen && g.id !== undefined && g.id === chosen.id)
  );
}

// Testers are people, not memberships: one address in two groups is one
// tester, and a blank address is nobody.
export function countUniqueTesters(emails) {
  const seen = new Set();
  for (const email of emails || []) {
    const value = String(email || "").trim().toLowerCase();
    if (value) seen.add(value);
  }
  return seen.size;
}

// The people in a group, counted so that nobody is dropped.
//
// A tester who joins through a public link can be recorded with NO email at
// all, so counting only the non-blank emails would report a group that holds
// people as empty, and the readiness check would then claim that nobody can
// install the build (Kody review on HogHunter PR #259, Nov 3 2026).  A tester
// with an email is one person however many rows carry it; a tester without one
// has no address to deduplicate by, so each such row is a person of its own.
//
// The input is a list of { email, id } records, which is what App Store
// Connect returns for beta testers.
export function countInstallableTesters(testers) {
  const byEmail = new Set();
  let withoutEmail = 0;
  for (const tester of testers || []) {
    const email = String((tester && tester.email) || "").trim().toLowerCase();
    if (email) byEmail.add(email);
    else withoutEmail += 1;
  }
  return byEmail.size + withoutEmail;
}

// The policy also decides where a new build has to go.  Under the public
// policy it goes to the external group and needs Beta App Review; under the
// internal policy the internal group already carries every build.
export function policyNeedsBuildAssignment(policy) {
  return resolveTesterPolicy(policy) === TESTER_POLICY_PUBLIC;
}

// The email list is only required when the policy adds people to a group.
// Under the public policy the group already holds the standing people, so an
// empty list is not a failure: the build still has to reach that group.
export function policyRequiresTesterList(policy) {
  return resolveTesterPolicy(policy) === TESTER_POLICY_INTERNAL;
}

// The standing list is three people.  Five is the hard ceiling, so a list
// that runs past it is refused rather than truncated under the policy that
// manages the list itself.
export const TESTER_LIST_MAX = 5;

// What to do with a tester list under a policy.
//
// The internal policy manages the list itself, so a malformed address or an
// oversized list refuses the whole thing and nothing changes.  The public
// policy does NOT manage the list:  the group already holds the people, so a
// wrong list is a warning about the list and never a reason to stop the build
// from reaching the group (Kody review on HogHunter PR #259, Nov 3 2026).
//
// Returns { ok, reason, malformed, count, add }:  ok=false means the caller
// must refuse and change nothing.
export function planTesterList(policy, emails, isWellFormed = () => true) {
  const list = Array.isArray(emails) ? emails : [];
  const malformed = list.filter((email) => !isWellFormed(email)).length;
  const fatal = policyRequiresTesterList(policy);
  if (fatal && malformed > 0) {
    return { ok: false, reason: "malformed", malformed, count: list.length, add: [] };
  }
  if (fatal && list.length > TESTER_LIST_MAX) {
    return { ok: false, reason: "too-many", malformed, count: list.length, add: [] };
  }
  return {
    ok: true,
    reason: malformed > 0 ? "malformed" : list.length > TESTER_LIST_MAX ? "too-many" : "",
    malformed,
    count: list.length,
    add: list.filter((email) => isWellFormed(email)).slice(0, TESTER_LIST_MAX)
  };
}
