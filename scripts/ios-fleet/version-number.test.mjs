/**
 * version-number.test.mjs - tests for the committed version record and for
 * the two ship paths agreeing on one number.
 *
 * Owner directive 2026-10-26 (HH-191).  The Mac path (scripts/install.sh)
 * and the iOS path (scripts/ios-fleet/ship-testflight.sh) both read the
 * committed record in project.yml, so they have to come out with the same
 * number for one update.  These tests prove that, and that the pair the app
 * ships is one number:  the version string, and the same string as the build
 * number.
 *
 * Pure and offline:  a temporary project root, a temporary git repository,
 * no network and no credentials.
 */
import assert from "node:assert/strict";
import test from "node:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { planIosUpdate, planMacUpdate } from "./version-plan.mjs";
import { readRecord, renderRecord } from "./version-number.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const MODULE = join(HERE, "version-number.mjs");
const REPO_ROOT = resolve(HERE, "..", "..");

const PROJECT_YML = `name: HogHunter
targets:
  HogHunter:
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "0.1.0"
  HogHunterIOS:
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "0.1.0"
  HogHunterWidgets:
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "0.1.0"
`;

/** A temporary project root with a project.yml and a git repository. */
function makeRoot({ project = PROJECT_YML, git = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "hh-version-"));
  writeFileSync(join(root, "project.yml"), project);
  if (git) {
    const env = {
      ...process.env,
      GIT_AUTHOR_NAME: "test",
      GIT_AUTHOR_EMAIL: "test@example.invalid",
      GIT_COMMITTER_NAME: "test",
      GIT_COMMITTER_EMAIL: "test@example.invalid"
    };
    execFileSync("git", ["init", "-q"], { cwd: root, env });
    execFileSync("git", ["add", "project.yml"], { cwd: root, env });
    execFileSync("git", ["commit", "-q", "-m", "record"], { cwd: root, env });
  }
  return root;
}

/** Run the module the way the ship paths do. */
function run(root, ...args) {
  return execFileSync(process.execPath, [MODULE, "--root", root, ...args], { encoding: "utf8" }).trim();
}

test("the committed record of this repository is one number", () => {
  const text = readFileSync(join(REPO_ROOT, "project.yml"), "utf8");
  const record = readRecord(text);
  assert.match(record.version, /^\d+\.\d+\.\d+$/, "the record is a version string");
  assert.equal(record.build, record.version, "the build number equals the version");
  // Hog Hunter's numbers live on the 0.1 train.
  assert.equal(record.version.split(".").slice(0, 2).join("."), "0.1");
});

test("the record write-back rewrites every target, including the widget", () => {
  const out = renderRecord(PROJECT_YML, "0.1.1", "0.1.1");
  const versions = [...out.matchAll(/MARKETING_VERSION: "([^"]*)"/g)].map((m) => m[1]);
  const builds = [...out.matchAll(/CURRENT_PROJECT_VERSION: "([^"]*)"/g)].map((m) => m[1]);
  assert.equal(versions.length, 3, "the Mac app, the iPhone app and the widget");
  assert.deepEqual(versions, ["0.1.1", "0.1.1", "0.1.1"]);
  assert.deepEqual(builds, ["0.1.1", "0.1.1", "0.1.1"]);
});

test("a record that holds two numbers is refused", () => {
  const broken = PROJECT_YML.replace('CURRENT_PROJECT_VERSION: "0.1.0"', 'CURRENT_PROJECT_VERSION: "1"');
  assert.throws(() => readRecord(broken), /more than one number/);
});

test("a record that is not a version string is refused", () => {
  const broken = PROJECT_YML
    .replace(/MARKETING_VERSION: "0\.1\.0"/g, 'MARKETING_VERSION: "152"')
    .replace(/CURRENT_PROJECT_VERSION: "0\.1\.0"/g, 'CURRENT_PROJECT_VERSION: "152"');
  assert.throws(() => readRecord(broken), /not a version string/);
});

test("the module hands out the next number, and the build number is the version", () => {
  const root = makeRoot();
  assert.equal(run(root, "record"), "0.1.0 0.1.0");
  const next = run(root, "next").split(" ");
  assert.equal(next[0], "0.1.1");
  assert.equal(next[1], next[0], "the build number equals the version");
  assert.match(next[0], /^\d+\.\d+\.\d+$/);
  assert.doesNotMatch(next[1], /^\d+$/, "no bare integer beside the version");
});

test("the Mac path and the iOS path choose the SAME number from the same record", () => {
  const root = makeRoot();
  const record = readRecord(readFileSync(join(root, "project.yml"), "utf8")).version;

  // The Mac path:  scripts/install.sh calls "next" with no --known, because
  // it has no App Store Connect access.
  const mac = run(root, "next").split(" ");

  // The iOS path:  the same module, with the highest patch the train holds
  // (0 when the train is empty) and the recorded train empty.
  const ios = planIosUpdate({ recorded: record, known: 0, recordedTrainEmpty: true });

  assert.equal(mac[0], ios.version, "both paths take the same number");
  assert.equal(mac[1], ios.version, "and the build number is that number");
  assert.equal(mac[0], "0.1.1");
});

test("the two paths agree when the train holds the recorded number", () => {
  const root = makeRoot();
  const record = readRecord(readFileSync(join(root, "project.yml"), "utf8")).version;
  const mac = planMacUpdate({ recorded: record });
  const ios = planIosUpdate({ recorded: record, known: 0, recordedTrainEmpty: false });
  assert.equal(mac.version, ios.version);
  assert.equal(mac.version, "0.1.1");
});

test("the Mac path is one number behind when App Store Connect is ahead", () => {
  const root = makeRoot();
  const record = readRecord(readFileSync(join(root, "project.yml"), "utf8")).version;
  // The train already holds 0.1.4, so the iOS path takes 0.1.5 ...
  const ios = planIosUpdate({ recorded: record, known: 4, recordedTrainEmpty: false });
  assert.equal(ios.version, "0.1.5");
  // ... while the Mac path, which cannot see App Store Connect, takes 0.1.1.
  const mac = planMacUpdate({ recorded: record });
  assert.equal(mac.version, "0.1.1");
  assert.notEqual(mac.version, ios.version, "the documented divergence");
});

test("writing the record moves the next number on", () => {
  const root = makeRoot();
  assert.equal(run(root, "write", "0.1.1"), "0.1.1 0.1.1");
  assert.equal(run(root, "record"), "0.1.1 0.1.1");
  assert.equal(run(root, "next").split(" ")[0], "0.1.2");
  const text = readFileSync(join(root, "project.yml"), "utf8");
  const versions = [...text.matchAll(/MARKETING_VERSION: "([^"]*)"/g)].map((m) => m[1]);
  assert.deepEqual(versions, ["0.1.1", "0.1.1", "0.1.1"], "the widget keeps the app's number");
});

test("a checkout with no readable git history fails loudly:  no timestamp fallback", () => {
  const root = makeRoot({ git: false });
  let failed = false;
  let message = "";
  try {
    run(root, "next");
  } catch (error) {
    failed = true;
    message = String(error.stderr || error.message);
  }
  assert.equal(failed, true, "the run must fail");
  assert.match(message, /git history|no timestamp/i);
  assert.doesNotMatch(message, /20\d{10}/, "no timestamp is ever offered as a number");
});

test("the module refuses to write a version that is not a version string", () => {
  const root = makeRoot();
  let failed = false;
  try {
    run(root, "write", "152");
  } catch {
    failed = true;
  }
  assert.equal(failed, true);
  assert.equal(run(root, "record"), "0.1.0 0.1.0", "the record is untouched");
});
