import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
  resolveTesterPolicy,
  selectPublicGroup,
  testerPolicyRefusal
} from "./tester-policy.mjs";

const group = (attrs) => ({ id: attrs.id || "g", attributes: attrs });

// The same shape the ship script uses: an address with one @, a host and a dot.
const isEmail = (value) => /^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/.test(String(value || ""));

test("an app that says nothing gets the public group", () => {
  assert.equal(resolveTesterPolicy(undefined), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy(""), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy(null), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy("public"), DEFAULT_TESTER_POLICY);
  assert.equal(resolveTesterPolicy("nonsense"), DEFAULT_TESTER_POLICY);
  assert.equal(DEFAULT_TESTER_POLICY, TESTER_POLICY_PUBLIC);
});

test("the public policy is named exactly", () => {
  assert.equal(resolveTesterPolicy("public-group"), TESTER_POLICY_PUBLIC);
  assert.equal(resolveTesterPolicy("  Public-Group  "), TESTER_POLICY_PUBLIC);
  assert.equal(resolveTesterPolicy(TESTER_POLICY_PUBLIC), TESTER_POLICY_PUBLIC);
});

test("the internal group policy is refused, never honoured", () => {
  // HH-217 (Nov 4 2026):  the internal group is gone.  A request for it does
  // not resolve to the public policy either:  a silent swap would hide the
  // very request the owner ruled out.
  assert.equal(resolveTesterPolicy(TESTER_POLICY_INTERNAL), null);
  assert.equal(resolveTesterPolicy("internal-group"), null);
  assert.equal(resolveTesterPolicy("  Internal-Group  "), null);
});

test("a refused policy carries a readable reason", () => {
  const why = testerPolicyRefusal(TESTER_POLICY_INTERNAL);
  assert.notEqual(why, "");
  assert.match(why, /internal-group/);
  assert.match(why, /public-group/);
});

test("a supported request is not refused", () => {
  assert.equal(testerPolicyRefusal(undefined), "");
  assert.equal(testerPolicyRefusal(""), "");
  assert.equal(testerPolicyRefusal(TESTER_POLICY_PUBLIC), "");
  assert.equal(testerPolicyRefusal("nonsense"), "");
});

test("the lane's own apps.json names the public group", () => {
  const apps = JSON.parse(readFileSync(new URL("./apps.json", import.meta.url), "utf8"));
  const policy = apps.apps?.hoghunter?.testerPolicy;
  assert.equal(resolveTesterPolicy(policy), TESTER_POLICY_PUBLIC);
  assert.equal(testerPolicyRefusal(policy), "");
});

test("a legacy internal-group in apps.json is refused, not honoured", () => {
  // The lane must not crash on a legacy registry, and it must not read it as
  // the public group either:  it stops with a message.
  assert.equal(resolveTesterPolicy(TESTER_POLICY_INTERNAL), null);
  assert.notEqual(testerPolicyRefusal(TESTER_POLICY_INTERNAL), "");
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

test("the standing-tester sync targets the public group", () => {
  // The one group the sync touches is the external group whose public link
  // is on.  An internal group is never it, whatever it is called.
  const internal = group({ id: "internal", name: "Internal Testers", isInternalGroup: true, hasAccessToAllBuilds: true });
  const linked = group({ id: "linked", name: "Beta", isInternalGroup: false, publicLinkEnabled: true });
  assert.equal(selectPublicGroup([internal, linked]).id, "linked");
  assert.equal(selectPublicGroup([internal]), null);
  // The other link-on groups are the ones the sync turns off; an internal
  // group is never among them.
  assert.deepEqual(otherLinkOnGroups([internal, linked], linked), []);
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

test("a good list is added whole", () => {
  const plan = planTesterList(["a@b.test", "c@d.test"], isEmail);
  assert.equal(plan.reason, "");
  assert.equal(plan.malformed, 0);
  assert.equal(plan.count, 2);
  assert.deepEqual(plan.add, ["a@b.test", "c@d.test"]);
});

test("a malformed list only warns", () => {
  // The people are already in the public group, so a wrong list is a note
  // about the list and never a reason to stop the build reaching the group.
  const plan = planTesterList(["a@b.test", "not-an-email"], isEmail);
  assert.equal(plan.reason, "malformed");
  assert.equal(plan.malformed, 1);
  assert.deepEqual(plan.add, ["a@b.test"]);
});

test("an oversized list only warns", () => {
  const many = Array.from({ length: TESTER_LIST_MAX + 1 }, (_, i) => `p${i}@b.test`);
  const plan = planTesterList(many, isEmail);
  assert.equal(plan.reason, "too-many");
  assert.equal(plan.count, TESTER_LIST_MAX + 1);
  assert.equal(plan.add.length, TESTER_LIST_MAX);
});

test("an empty list is fine", () => {
  const plan = planTesterList([], isEmail);
  assert.equal(plan.reason, "");
  assert.equal(plan.count, 0);
  assert.deepEqual(plan.add, []);
});
