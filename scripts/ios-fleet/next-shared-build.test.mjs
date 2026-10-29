// next-shared-build.test.mjs - offline tests for the shared release-build query.
//
// The query itself needs credentials and App Store Connect, so what runs here
// is the pagination validator it follows (exported from asc-api.mjs), plus a
// pin on the query shape: when the paired bundle id resolves to a different
// app, BOTH platforms of BOTH apps join the plan.
import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { nextBuildsPage } from "./asc-api.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const clientSource = readFileSync(join(here, "asc-api.mjs"), "utf8");

test("a missing links block ends the pager", () => {
  assert.deepEqual(nextBuildsPage({ data: [] }), { ok: true, next: "" });
  assert.deepEqual(nextBuildsPage({ data: [], links: {} }), { ok: true, next: "" });
  assert.deepEqual(nextBuildsPage({ data: [], links: { next: null } }), { ok: true, next: "" });
});

test("a string next link is followed", () => {
  assert.deepEqual(
    nextBuildsPage({ data: [], links: { next: "https://example.invalid/v1/builds?page=2" } }),
    { ok: true, next: "https://example.invalid/v1/builds?page=2" }
  );
  assert.deepEqual(nextBuildsPage({ data: [], links: { next: "" } }), { ok: true, next: "" });
});

test("a non-object page is malformed", () => {
  for (const parsed of [null, undefined, 42, "links", [], ["data"]]) {
    assert.deepEqual(nextBuildsPage(parsed), { ok: false, next: "" }, JSON.stringify(parsed));
  }
});

test("a present-but-not-object links block is malformed", () => {
  for (const links of [null, 42, "next", []]) {
    assert.deepEqual(
      nextBuildsPage({ data: [], links }),
      { ok: false, next: "" },
      JSON.stringify(links)
    );
  }
});

test("a non-string next link is malformed", () => {
  for (const next of [42, true, {}, [], 0]) {
    assert.deepEqual(
      nextBuildsPage({ data: [], links: { next } }),
      { ok: false, next: "" },
      JSON.stringify(next)
    );
  }
});

test("malformed pagination exits 2 with its own message", () => {
  assert.match(
    clientSource,
    /console\.error\(`\$\{tag\}: malformed pagination`\);\s*\n\s*process\.exit\(2\);/
  );
});

test("the paired app contributes both platforms to both lists", () => {
  // iosBuilds = IOS(app) + IOS(pairedApp), macBuilds = MAC_OS(app) +
  // MAC_OS(pairedApp).  A paired app whose iOS builds were skipped would let
  // the plan reuse a build number.
  for (const line of [
    'allBuilds(appId, "IOS", tag)',
    'allBuilds(appId, "MAC_OS", tag)',
    'allBuilds(macAppId, "IOS", tag)',
    'allBuilds(macAppId, "MAC_OS", tag)',
    "iosBuilds = iosA.concat(iosB)",
    "macBuilds = macA.concat(macB)"
  ]) {
    assert.ok(clientSource.includes(line), `plan-release-build lost: ${line}`);
  }
});

test("the independent inventories are read concurrently", () => {
  // Serial awaits would quadruple the query latency when a paired app
  // resolves; Promise.all keeps the same inventories and the same cap.
  assert.ok(
    clientSource.includes("await Promise.all(["),
    "plan-release-build lost its concurrent inventories"
  );
  const block = clientSource.slice(
    clientSource.indexOf('if (method === "plan-release-build"'),
    clientSource.indexOf('if (method === "max-platform-build")')
  );
  assert.ok(block.includes("await Promise.all(["), "Promise.all outside plan-release-build?");
  assert.ok(!/let iosBuilds = await allBuilds/.test(block), "serial iosBuilds await came back");
});

test("an inventory past the page cap fails closed instead of truncating", () => {
  assert.match(
    clientSource,
    /console\.error\(`\$\{tag\}: more than 100 pages of builds; refusing to guess`\);\s*\n\s*process\.exit\(2\);/
  );
});

test("plan-release-build and next-shared-build share one code path", () => {
  assert.ok(
    clientSource.includes('if (method === "plan-release-build" || method === "next-shared-build")'),
    "the planner commands no longer share one block"
  );
});

test("the planner requires a merge stamp", () => {
  assert.ok(
    clientSource.includes('rest.indexOf("--merge-stamp")'),
    "the planner lost its --merge-stamp flag"
  );
  assert.match(
    clientSource,
    /<bundleId> \[pairedBundleId\] \[floor\.\.\.\] --merge-stamp <S>/
  );
  assert.ok(
    clientSource.includes("complete: true, mergeStamp"),
    "the merge stamp never reaches the planner"
  );
});

test("floors reach the planner as digit strings", () => {
  // A Sparkle feed max can exceed the safe-integer range, so the client must
  // not narrow it through Number(); the planner compares with BigInt.
  assert.ok(clientSource.includes("extraFloors.push(f)"), "floors are converted before the planner");
  assert.ok(!/extraFloors\.push\(Number\(f\)\)/.test(clientSource), "Number(floor) came back");
});

test("the planner counts every build on both platforms", () => {
  assert.ok(!clientSource.includes("ignoredIos"), "an ignored-build count came back");
  assert.ok(!clientSource.includes("four-digit"), "four-digit wording came back");
  assert.ok(!clientSource.includes("timestamp build(s); next is"), "the ignore line came back");
});

test("max-platform-build reads one app on one platform", () => {
  assert.ok(
    clientSource.includes('if (method === "max-platform-build")'),
    "max-platform-build is not a command"
  );
  const block = clientSource.slice(
    clientSource.indexOf('if (method === "max-platform-build")'),
    clientSource.indexOf('if (method === "build-floor")')
  );
  assert.ok(block.includes("maxFirstComponent(builds)"), "max-platform-build lost its max");
  assert.ok(block.includes('allBuilds(appId, platform, "max-platform-build")'), "max-platform-build lost its inventory");
  assert.ok(!block.includes("macAppId"), "max-platform-build must not read the paired app");
});
