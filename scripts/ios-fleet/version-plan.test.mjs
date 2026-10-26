/**
 * version-plan.test.mjs - unit tests for the fleet's version-numbering rules.
 *
 * Pure:  no network, no credentials, no App Store Connect.  The data in the
 * "real Congress.Trade" case is the live App Store Connect state measured
 * 2026-10-24 (AFC-517 / CT-2444):
 *
 *   App Store versions : 1.0.235
 *   TestFlight trains  : 1.0.235 [202610110355]
 *                        1.0.236 [202610180036]
 *                        1.0.2353 [2353]   <- drift train (build "2353")
 *                        1.0.2358 [2358]   <- drift train (build "2358")
 *
 * so the next free patch on that train was 1.0.237 -- the drift trains must
 * not push it to 1.0.2359.
 *
 * Owner directive 2026-10-26 (HH-191):  ONE NUMBER, and it is a version
 * string.  The version and the build number carry the same string ("0.1.1
 * (0.1.1)"), the number is one past what the train holds, and the repository
 * commit count and every timestamp are retired.
 */
import assert from "node:assert/strict";
import test from "node:test";

import {
  buildFloor,
  isDriftTrain,
  latestMarketingPatch,
  nextMarketingPatch,
  nextVersion,
  ownPatch,
  parsePatch,
  parseVersionParts,
  planIosUpdate,
  planMacUpdate,
  planShip,
  versionTrain
} from "./version-plan.mjs";

const CONGRESS_APP_STORE_VERSIONS = ["1.0.235"];
const CONGRESS_TRAINS = [
  { version: "1.0.235", builds: ["202610110355"] },
  { version: "1.0.236", builds: ["202610180036"] },
  { version: "1.0.2353", builds: ["2353"] },
  { version: "1.0.2358", builds: ["2358"] }
];

test("parsePatch reads the patch of a version on a train", () => {
  assert.equal(parsePatch("1.0.236", "1.0"), 236);
  assert.equal(parsePatch("1.0.2358", "1.0"), 2358);
  assert.equal(parsePatch("2.0.5", "2.0"), 5);
});

test("parsePatch rejects a version that is not <prefix>.<digits>", () => {
  assert.equal(parsePatch("1.0", "1.0"), null);
  assert.equal(parsePatch("1.01.5", "1.0"), null);
  assert.equal(parsePatch("2.0.5", "1.0"), null);
  assert.equal(parsePatch("1.0.236.1", "1.0"), null);
  assert.equal(parsePatch("", "1.0"), null);
  assert.equal(parsePatch("1.0.abc", "1.0"), null);
});

test("parsePatch escapes the prefix", () => {
  // "1.0" must not match "120" or "1x0".
  assert.equal(parsePatch("120.5", "1.0"), null);
  assert.equal(parsePatch("1x0.5", "1.0"), null);
  assert.equal(parsePatch("1.0.5", "1.0"), 5);
});

test("ownPatch reads the patch of a version on its own train", () => {
  assert.equal(ownPatch("1.0.236"), 236);
  assert.equal(ownPatch("2.0.5"), 5);
  assert.equal(ownPatch("1.0"), null);
  assert.equal(ownPatch("nonsense"), null);
});

test("isDriftTrain spots a train that holds the build named after its patch", () => {
  assert.equal(isDriftTrain("1.0.2358", ["2358"], "1.0"), true);
  assert.equal(isDriftTrain("1.0.2353", ["2353", "202610180036"], "1.0"), true);
  // A UTC-stamped build is not the patch number:  not a drift train.
  assert.equal(isDriftTrain("1.0.236", ["202610180036"], "1.0"), false);
  // A train with no patch has no drift to speak of.
  assert.equal(isDriftTrain("1.0", ["1"], "1.0"), false);
  assert.equal(isDriftTrain("2.0.5", ["5"], "1.0"), false);
});

test("latestMarketingPatch ignores drift trains (real Congress.Trade data)", () => {
  const patch = latestMarketingPatch({
    prefix: "1.0",
    appStoreVersions: CONGRESS_APP_STORE_VERSIONS,
    trains: CONGRESS_TRAINS
  });
  // 1.0.2358 and 1.0.2353 are drift trains, so 236 wins.
  assert.equal(patch, 236);
});

test("latestMarketingPatch counts App Store versions that no train carries", () => {
  const patch = latestMarketingPatch({
    prefix: "1.0",
    appStoreVersions: ["1.0.240"],
    trains: [{ version: "1.0.2358", builds: ["2358"] }]
  });
  assert.equal(patch, 240);
});

test("latestMarketingPatch returns 0 for an empty train", () => {
  assert.equal(latestMarketingPatch({ prefix: "1.0", appStoreVersions: [], trains: [] }), 0);
});

test("buildFloor keeps the old UTC stamp inside the target train", () => {
  const floor = buildFloor({
    trainBuilds: ["202610180036"],
    appBuilds: [],
    platform: "IOS"
  });
  assert.equal(floor, 202610180036);
});

test("buildFloor ignores huge app builds on iOS but not on macOS", () => {
  const appBuilds = ["2353", "2358", "202610180036"];
  assert.equal(buildFloor({ trainBuilds: [], appBuilds, platform: "IOS" }), 2358);
  assert.equal(buildFloor({ trainBuilds: [], appBuilds, platform: "MAC_OS" }), 202610180036);
});

test("buildFloor ignores dotted and non-numeric build values", () => {
  const floor = buildFloor({
    trainBuilds: ["1.0.5", "abc", ""],
    appBuilds: ["42", "1.0.9", "x"],
    platform: "IOS"
  });
  assert.equal(floor, 42);
});

test("parseVersionParts reads the three parts of a version string", () => {
  assert.deepEqual(parseVersionParts("0.1.1"), { major: 0, minor: 1, patch: 1 });
  assert.deepEqual(parseVersionParts("1.1.2"), { major: 1, minor: 1, patch: 2 });
  assert.equal(parseVersionParts("1.0"), null);
  assert.equal(parseVersionParts("x.y.z"), null);
  assert.equal(parseVersionParts("1.0.1.2"), null);
  assert.equal(parseVersionParts(""), null);
});

test("versionTrain names the train a version lives on", () => {
  assert.equal(versionTrain("0.1.1"), "0.1");
  assert.equal(versionTrain("1.1.2"), "1.1");
  assert.equal(versionTrain("1.0"), null);
});

test("nextVersion is one past the committed record", () => {
  assert.equal(nextVersion({ recorded: "0.1.0" }), "0.1.1");
  assert.equal(nextVersion({ recorded: "0.1.7" }), "0.1.8");
});

test("nextVersion never reuses a number the train already holds", () => {
  // The train holds 1.1.1 and the record is behind it:  the number moves on.
  assert.equal(nextVersion({ recorded: "1.1.0", known: 1 }), "1.1.2");
  assert.equal(nextVersion({ recorded: "1.1.1", known: 1 }), "1.1.2");
  assert.equal(nextVersion({ recorded: "1.1.5", known: 1 }), "1.1.6");
});

test("nextVersion refuses a record that is not a version string", () => {
  assert.throws(() => nextVersion({ recorded: "152" }), /not a version string/);
  assert.throws(() => nextVersion({ recorded: "" }), /not a version string/);
  assert.throws(() => nextVersion({ recorded: undefined }), /not a version string/);
});

test("planShip: the build number IS the version", () => {
  const plan = planShip({ recorded: "0.1.0", known: 0 });
  assert.equal(plan.version, "0.1.1");
  assert.equal(plan.build, "0.1.1");
});

test("planShip: the version is exactly <major>.<minor>.<patch>", () => {
  const plan = planShip({ recorded: "1.1.1", known: 1 });
  assert.match(plan.version, /^\d+\.\d+\.\d+$/);
  assert.equal(plan.version, "1.1.2");
  assert.match(plan.build, /^\d+\.\d+\.\d+$/);
  assert.equal(plan.build, plan.version);
});

test("planShip: no commit count and no timestamp ever reaches the pair", () => {
  // The old scheme produced "1.0.237 (2360)" and "1.0.2358 (2358)":  a bare
  // integer beside the version, and a 12-digit UTC stamp.  Neither can
  // happen now:  the build number is the version string.
  const plan = planShip({ recorded: "0.1.0", known: 0 });
  assert.doesNotMatch(plan.build, /^\d+$/);
  assert.doesNotMatch(plan.build, /^\d{12}$/);
  assert.doesNotMatch(plan.build, /2026/);
  assert.equal(plan.build, plan.version);
});

test("planShip honours an exact --version override", () => {
  const plan = planShip({ recorded: "0.1.0", known: 0, forcedVersion: "2.0.5" });
  assert.equal(plan.version, "2.0.5");
  assert.equal(plan.build, "2.0.5");
});

test("planShip honours an exact --build override", () => {
  const plan = planShip({ recorded: "0.1.0", known: 0, forcedBuild: "999" });
  assert.equal(plan.version, "0.1.1");
  assert.equal(plan.build, "999");
});

test("planShip refuses a version that is not a version string", () => {
  assert.throws(() => planShip({ recorded: "0.1.0", forcedVersion: "1.2" }), /not a version string/);
});

test("planMacUpdate takes the number one past the committed record", () => {
  const plan = planMacUpdate({ recorded: "0.1.0" });
  assert.equal(plan.version, "0.1.1");
  assert.equal(plan.build, "0.1.1");
});

test("planIosUpdate takes the next free number when the train holds the record", () => {
  // The record is what the last update shipped and App Store Connect holds
  // it too, so the next number is one past it.
  const plan = planIosUpdate({ recorded: "0.1.0", known: 0, recordedTrainEmpty: false });
  assert.equal(plan.version, "0.1.1");
  assert.equal(plan.build, "0.1.1");
});

test("planIosUpdate ships the recorded number when it is ahead of the train", () => {
  // The Mac path already chose this number and recorded it:  this path ships
  // the same one, so one update carries one number on both platforms.
  const plan = planIosUpdate({ recorded: "0.1.1", known: 0, recordedTrainEmpty: true });
  assert.equal(plan.version, "0.1.1");
  assert.equal(plan.build, "0.1.1");
});

test("planIosUpdate never ships a recorded number whose train already holds a build", () => {
  const plan = planIosUpdate({ recorded: "0.1.1", known: 0, recordedTrainEmpty: false });
  assert.equal(plan.version, "0.1.2");
  assert.equal(plan.build, "0.1.2");
});

test("planIosUpdate takes the number past what App Store Connect holds", () => {
  // The record is behind the train:  the number moves past what the train
  // holds, never back onto a number that is already used.
  const plan = planIosUpdate({ recorded: "0.1.0", known: 4, recordedTrainEmpty: false });
  assert.equal(plan.version, "0.1.5");
  assert.equal(plan.build, "0.1.5");
});
