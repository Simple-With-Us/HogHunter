// The TestFlight tester policy for one app.
//
// ONE policy is supported (owner ruling, Nov 4 2026, HH-217):
//
//   public-group     one external group with its public link on holds the
//                    standing testers, so they install each build through the
//                    link, and every new build must be assigned to that group
//                    and submitted for Beta App Review before anyone can
//                    install it.
//
// The internal all-builds group is GONE.  The lane never creates one, never
// requires one and never waits for one.  An app record that still carries one
// from before keeps it:  the lane does not delete it, does not use it and does
// not fail because it exists.
//
// A request for the old "internal-group" policy is REFUSED, never honoured
// and never quietly turned into the public policy:  a caller that asks for it
// gets a readable reason and stops, because doing something else without
// saying so is how a ruling gets lost.
//
// The policy is named per app in apps.json.  An app that says nothing about
// its testers gets the public group, which is the only policy there is.
//
// Pure functions only, no I/O: CI can test them without App Store Connect.

export const TESTER_POLICY_PUBLIC = "public-group";
// The legacy value.  It is kept ONLY so a request for it can be recognised
// and refused with a message; nothing honours it any more.
export const TESTER_POLICY_INTERNAL = "internal-group";
export const DEFAULT_TESTER_POLICY = TESTER_POLICY_PUBLIC;

// The name the public group carries when it has to be created.
export const PUBLIC_GROUP_NAME = "Public Beta";

// What a caller asked for, normalised:  lower case, trimmed, "" for nothing.
function normalizePolicy(value) {
  return String(value === undefined || value === null ? "" : value).trim().toLowerCase();
}

// Why a policy request is refused, or "" when the request is fine.
//
// The message is the point:  the caller prints it and stops, so the reader
// sees WHY nothing happened instead of a silent no-op.
export function testerPolicyRefusal(value) {
  if (normalizePolicy(value) === TESTER_POLICY_INTERNAL) {
    return (
      `the tester policy "${TESTER_POLICY_INTERNAL}" is not supported any more (HH-217):  ` +
      `iOS TestFlight uses the public group only, so there is no internal group to create, ` +
      `require or wait for.  Use "${TESTER_POLICY_PUBLIC}".`
    );
  }
  return "";
}

// The policy a request resolves to.
//
// An unknown value is not a guess:  it falls back to the default, which is the
// public group.  The legacy internal value resolves to null, which IS the
// refusal:  a caller checks for null and stops with testerPolicyRefusal().
// It never resolves to the public policy instead, because a silent swap would
// hide the very request the owner ruled out.
export function resolveTesterPolicy(value) {
  if (normalizePolicy(value) === TESTER_POLICY_INTERNAL) return null;
  return DEFAULT_TESTER_POLICY;
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
//
// An internal group is never returned, whatever it is called:  it is not a
// way in any more, and the caller must never pick one as its public group.
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

// The standing list is three people.  Five is the hard ceiling, so a list
// that runs past it is trimmed rather than refused:  the list is a note about
// the list, never a reason to stop the build reaching the public group.
export const TESTER_LIST_MAX = 5;

// What to do with a tester list.
//
// The public policy does NOT manage the list:  the group already holds the
// people, so a wrong list is a warning about the list and never a reason to
// stop the build from reaching the group (Kody review on HogHunter PR #259,
// Nov 3 2026).  No policy manages it any more, so a malformed or oversized
// list is always a warning.
//
// Returns { reason, malformed, count, add }:  reason is "" when the list is
// clean, otherwise what is wrong with it.  add holds the addresses that are
// well formed, up to the ceiling.
export function planTesterList(emails, isWellFormed = () => true) {
  const list = Array.isArray(emails) ? emails : [];
  const malformed = list.filter((email) => !isWellFormed(email)).length;
  const tooMany = list.length > TESTER_LIST_MAX;
  return {
    reason: malformed > 0 ? "malformed" : tooMany ? "too-many" : "",
    malformed,
    count: list.length,
    add: list.filter((email) => isWellFormed(email)).slice(0, TESTER_LIST_MAX)
  };
}
