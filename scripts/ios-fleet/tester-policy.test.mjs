import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_TESTER_POLICY,
  PUBLIC_GROUP_NAME,
  TESTER_POLICY_INTERNAL,
  TESTER_POLICY_PUBLIC,
  countUniqueTesters,
  hasPublicLink,
  isExternalGroup,
  policyNeedsBuildAssignment,
  policyRequiresTesterList,
  policyUsesInternalGroup,
  resolveTesterPolicy,
  selectPublicGroup
} from "./tester-policy.mjs";

const group = (attrs) => ({ id: attrs.id || "g", attributes: attrs });

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

test("the named public group wins over another external group", () => {
  const named = group({ id: "named", name: PUBLIC_GROUP_NAME, isInternalGroup: false, publicLinkEnabled: false });
  const linked = group({ id: "linked", name: "Beta", isInternalGroup: false, publicLinkEnabled: true });
  assert.equal(selectPublicGroup([linked, named]).id, "named");
});

test("an external group with the public link on wins over a bare external group", () => {
  const bare = group({ id: "bare", name: "Beta", isInternalGroup: false });
  const linked = group({ id: "linked", name: "Beta 2", isInternalGroup: false, publicLinkEnabled: true });
  assert.equal(selectPublicGroup([bare, linked]).id, "linked");
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
