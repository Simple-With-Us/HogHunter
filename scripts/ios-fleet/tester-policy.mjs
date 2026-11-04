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

// The one external group the public policy reuses.  The named group first, so
// an app that has one keeps it; then any external group with its public link
// on; then any external group at all.  Null when the app has no external
// group, which is the caller's cue to create one.
export function selectPublicGroup(groups) {
  const list = Array.isArray(groups) ? groups : [];
  const external = list.filter(isExternalGroup);
  return (
    external.find((g) => g && g.attributes && g.attributes.name === PUBLIC_GROUP_NAME) ||
    external.find(hasPublicLink) ||
    external[0] ||
    null
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
