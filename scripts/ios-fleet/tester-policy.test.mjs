import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_TESTER_POLICY,
  PUBLIC_GROUP_NAME,
  TESTER_LIST_MAX,
  TESTER_POLICY_INTERNAL,
  TESTER_POLICY_PUBLIC,
  countInstallableTesters,
  countUniqueTesters,
  hasPublicLink,
  isExternalGroup,
  otherLinkOnGroups,
  planTesterList,
  policyNeedsBuildAssignment,
  policyRequiresTesterList,
  policyUsesInternalGroup,
  resolveTesterPolicy,
  selectPublicGroup
} from "./tester-policy.mjs";

const group = (attrs) => ({ id: attrs.id || "g", attributes: attrs });

// The same shape the ship script uses: an address with one @, a host and a dot.
const isEmail = (value) => /^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/.test(String(value || ""));

test("an app that says nothing keeps the internal group policy", () => {
  assert.equal(resolveTesterPolicy(undefined), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy(""), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy(null), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy("public"), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy("nonsense"), DEFAULT_TESTER_POLICY);
  assert.equal(DEFAULT_TESTER_POLICY, TESTER_POLICY_INTERNAL);
});

test("the public policy is named exactly", () => {
  assert.equal(resolveTesterPolicy("public-group"), TESTER_POLICY_PUBLIC);
  assert.equal(resolveTesterPolicy("  Public-Group  "), TESTER_POLICY_PUBLIC);
  assert.equal(resolveTesterPolicy(TESTER_POLICY_PUBLIC), TESTER_POLICY_PUBLIC);
});

test("the internal group exists only under the internal policy", () => {
  assert.equal(policyUsesInternalGroup(undefined), true);
  assert.equal(policyUsesInternalGroup(TESTER_POLICY_INTERNAL), true);
  assert.equal(policyUsesInternalGroup(TESTER_POLICY_PUBLIC), false);
});

test("only the public policy needs the build assigned to a group", () => {
  assert.equal(policyNeedsBuildAssignment(TESTER_POLICY_PUBLIC), true);
  assert.equal(policyNeedsBuildAssignment(TESTER_POLICY_INTERNAL), false);
  assert.equal(policyNeedsBuildAssignment(undefined), false);
});

test("only the internal policy needs a tester list", () => {
  assert.equal(policyRequiresTesterList(TESTER_POLICY_INTERNAL), true);
  assert.equal(policyRequiresTesterList(TESTER_POLICY_PUBLIC), false);
  assert.equal(policyRequiresTesterList(undefined), true);
});

test("group kind is read from the flag, not the name", () => {
  assert.equal(isExternalGroup(group({ name: "Public Beta", isInternalGroup: false })), true);
  assert.equal(isExternalGroup(group({ name: "Public Beta", isInternalGroup: true })), false);
  assert.equal(isExternalGroup(group({ name: "Public Beta" })), false);
  assert.equal(isExternalGroup(undefined), false);
  assert.equal(hasPublicLink(group({ publicLinkEnabled: true })), true);
  assert.equal(hasPublicLink(group({ publicLinkEnabled: false })), false);
  assert.equal(hasPublicLink(group({})), false);
});

test("the group whose public link is on wins over the named group", () => {
  const named = group({ id: "named", name: PUBLIC_GROUP_NAME, isInternalGroup: false, publicLinkEnabled: false });
  const linked = group({ id: "linked", name: "Beta", isInternalGroup: false, publicLinkEnabled: true });
  // The link-on group distributes builds, so it is the one to keep; turning
  // the link on for the named group as well would leave two links on.
  assert.equal(selectPublicGroup([named, linked]).id, "linked");
  assert.equal(selectPublicGroup([linked, named]).id, "linked");
});

test("the named group wins when no external group has its link on", () => {
  const named = group({ id: "named", name: PUBLIC_GROUP_NAME, isInternalGroup: false });
  const bare = group({ id: "bare", name: "Beta", isInternalGroup: false });
  assert.equal(selectPublicGroup([bare, named]).id, "named");
});

test("an external group with the public link on wins over a bare external group", () => {
  const bare = group({ id: "bare", name: "Beta", isInternalGroup: false });
  const linked = group({ id: "linked", name: "Beta 2", isInternalGroup: false, publicLinkEnabled: true });
  assert.equal(selectPublicGroup([bare, linked]).id, "linked");
});

test("the other link-on groups are the ones that would compete", () => {
  const chosen = group({ id: "chosen", name: PUBLIC_GROUP_NAME, isInternalGroup: false, publicLinkEnabled: true });
  const rival = group({ id: "rival", name: "Beta 2", isInternalGroup: false, publicLinkEnabled: true });
  const quiet = group({ id: "quiet", name: "Beta 3", isInternalGroup: false });
  const internal = group({ id: "internal", name: "Internal Testers", isInternalGroup: true, publicLinkEnabled: true });
  assert.deepEqual(otherLinkOnGroups([chosen, rival, quiet, internal], chosen).map((g) => g.id), ["rival"]);
  assert.deepEqual(otherLinkOnGroups([chosen, rival], undefined).map((g) => g.id), ["chosen", "rival"]);
  assert.deepEqual(otherLinkOnGroups([quiet], chosen), []);
});

test("internal groups are never the public group", () => {
  const internal = group({ id: "internal", name: PUBLIC_GROUP_NAME, isInternalGroup: true });
  assert.equal(selectPublicGroup([internal]), null);
  assert.equal(selectPublicGroup([]), null);
  assert.equal(selectPublicGroup(undefined), null);
});

test("testers are counted as people", () => {
  assert.equal(countUniqueTesters(["a@b.test", "A@B.test"]), 1);
  assert.equal(countUniqueTesters(["a@b.test", "c@b.test"]), 2);
  assert.equal(countUniqueTesters(["", "  ", null, undefined]), 0);
  assert.equal(countUniqueTesters(undefined), 0);
});

test("a tester with no email is still a person", () => {
  // A tester who joined through the public link can carry no email, and
  // dropping them would report a group that holds people as empty.
  assert.equal(countInstallableTesters([{ email: null, id: "a" }]), 1);
  assert.equal(countInstallableTesters([{ email: "", id: "a" }]), 1);
  assert.equal(
    countInstallableTesters([
      { email: null, id: "a" },
      { email: null, id: "b" }
    ]),
    2
  );
});

test("the same email in two rows is still one person", () => {
  assert.equal(
    countInstallableTesters([
      { email: "a@b.test", id: "x" },
      { email: "A@B.test", id: "y" }
    ]),
    1
  );
});

test("email testers and link testers are counted together", () => {
  assert.equal(
    countInstallableTesters([
      { email: "a@b.test", id: "x" },
      { email: "a@b.test", id: "y" },
      { email: null, id: "z" }
    ]),
    2
  );
  assert.equal(countInstallableTesters([]), 0);
  assert.equal(countInstallableTesters(undefined), 0);
});

test("a malformed list refuses the internal policy outright", () => {
  const plan = planTesterList(TESTER_POLICY_INTERNAL, ["a@b.test", "not-an-email"], isEmail);
  assert.equal(plan.ok, false);
  assert.equal(plan.reason, "malformed");
  assert.equal(plan.malformed, 1);
  assert.deepEqual(plan.add, []);
});

test("an oversized list refuses the internal policy outright", () => {
  const many = Array.from({ length: TESTER_LIST_MAX + 1 }, (_, i) => `p${i}@b.test`);
  const plan = planTesterList(TESTER_POLICY_INTERNAL, many, isEmail);
  assert.equal(plan.ok, false);
  assert.equal(plan.reason, "too-many");
  assert.equal(plan.count, TESTER_LIST_MAX + 1);
  assert.deepEqual(plan.add, []);
});

test("a good list passes the internal policy and is added whole", () => {
  const plan = planTesterList(TESTER_POLICY_INTERNAL, ["a@b.test", "c@d.test"], isEmail);
  assert.equal(plan.ok, true);
  assert.equal(plan.reason, "");
  assert.deepEqual(plan.add, ["a@b.test", "c@d.test"]);
});

test("a malformed list only warns under the public policy", () => {
  // The people are already in the public group, so a wrong list is a note
  // about the list and never a reason to stop the build reaching the group.
  const plan = planTesterList(TESTER_POLICY_PUBLIC, ["a@b.test", "not-an-email"], isEmail);
  assert.equal(plan.ok, true);
  assert.equal(plan.reason, "malformed");
  assert.equal(plan.malformed, 1);
  assert.deepEqual(plan.add, ["a@b.test"]);
});

test("an oversized list only warns under the public policy", () => {
  const many = Array.from({ length: TESTER_LIST_MAX + 1 }, (_, i) => `p${i}@b.test`);
  const plan = planTesterList(TESTER_POLICY_PUBLIC, many, isEmail);
  assert.equal(plan.ok, true);
  assert.equal(plan.reason, "too-many");
  assert.equal(plan.count, TESTER_LIST_MAX + 1);
  assert.equal(plan.add.length, TESTER_LIST_MAX);
});

test("an empty list is fine under the public policy", () => {
  const plan = planTesterList(TESTER_POLICY_PUBLIC, [], isEmail);
  assert.equal(plan.ok, true);
  assert.equal(plan.reason, "");
  assert.equal(plan.count, 0);
  assert.deepEqual(plan.add, []);
});
