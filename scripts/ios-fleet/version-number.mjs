/**
 * version-number.mjs - the committed version record, and the one number a
 * ship takes from it.
 *
 * Owner directive 2026-10-26 (HH-191).  Both ship paths read the number from
 * here, so the Mac app and the iPhone app of one update carry the SAME
 * number by construction:
 *
 *   scripts/install.sh            (the Mac path)
 *   scripts/ios-fleet/ship-testflight.sh   (the iOS path)
 *
 * The record lives in project.yml, which is the source of truth for the
 * Xcode project (the generated .xcodeproj is git-ignored):
 *
 *   MARKETING_VERSION: "0.1.0"        the version the last update shipped
 *   CURRENT_PROJECT_VERSION: "0.1.0"  the build number, which IS the version
 *
 * Under the one-number scheme those two values are the same string, so the
 * pair describes one number ("0.1.1 (0.1.1)") and never a second one.  The
 * rules that decide the next number are pure and live in ./version-plan.mjs;
 * this module is the I/O around them:  read the record, write it back.
 *
 * There is no timestamp fallback anywhere:  a checkout with no readable git
 * history fails loudly instead of inventing a number.
 *
 * Usage:
 *   node version-number.mjs record [--root DIR]
 *       Prints "<version> <build>":  the committed record.
 *   node version-number.mjs next [--root DIR] [--known N] [--write]
 *       Prints "<version> <build>":  the number the next update ships.
 *       --known N is the highest patch already used on the train that this
 *       path can see (0 for the Mac path, App Store Connect's answer for the
 *       iOS path).  --write records the number in project.yml.
 *   node version-number.mjs write <version> [--build B] [--root DIR]
 *       Writes the record (both fields, every target) and prints it.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { nextVersion, parseVersionParts, planShip } from "./version-plan.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = resolve(HERE, "..", "..");

/** The path of the committed record inside a project root. */
export function projectFile(root = DEFAULT_ROOT) {
  return join(root, "project.yml");
}

/**
 * Every MARKETING_VERSION / CURRENT_PROJECT_VERSION pair in a project file.
 *
 * A project file with two different versions is a broken record, and the
 * one-number scheme has no way to read that:  the caller fails loudly.
 */
export function readRecord(text) {
  const marketing = [...String(text).matchAll(/^[ \t]*MARKETING_VERSION:[ \t]*"([^"]*)"/gm)].map((m) => m[1]);
  const builds = [...String(text).matchAll(/^[ \t]*CURRENT_PROJECT_VERSION:[ \t]*"([^"]*)"/gm)].map((m) => m[1]);
  if (marketing.length === 0) {
    throw new Error("no MARKETING_VERSION in project.yml: the committed version record is missing");
  }
  if (builds.length === 0) {
    throw new Error("no CURRENT_PROJECT_VERSION in project.yml: the committed version record is missing");
  }
  const version = marketing[0];
  const build = builds[0];
  const different = [...new Set([...marketing, ...builds])];
  if (different.length > 1) {
    throw new Error(
      `the committed version record holds more than one number: ${different.map((v) => JSON.stringify(v)).join(", ")}. ` +
      "One number only:  the build number equals the version."
    );
  }
  if (!parseVersionParts(version)) {
    throw new Error(`the committed version record is not a version string: ${JSON.stringify(version)}`);
  }
  return { version, build };
}

/**
 * The project file with both fields set to the shipped number.
 *
 * Every target that carries a version is rewritten (the Mac app, the iPhone
 * app and the widget), so the widget keeps the same number as the app.
 */
export function renderRecord(text, version, build) {
  let out = String(text).replace(
    /^([ \t]*MARKETING_VERSION:[ \t]*)"[^"]*"/gm,
    (_match, prefix) => `${prefix}"${version}"`
  );
  out = out.replace(
    /^([ \t]*CURRENT_PROJECT_VERSION:[ \t]*)"[^"]*"/gm,
    (_match, prefix) => `${prefix}"${build}"`
  );
  return out;
}

/**
 * The git history has to be readable.
 *
 * The commit count is retired as the number source, so this is not a
 * fallback:  it is the loud failure the owner asked for.  A checkout with no
 * readable history cannot be trusted to carry the committed record, and a
 * timestamp fallback would put a second, different number back into the
 * build.
 */
export function assertGitHistory(root = DEFAULT_ROOT) {
  try {
    const out = execFileSync("git", ["-C", root, "rev-list", "--count", "HEAD"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).trim();
    if (!/^\d+$/.test(out)) {
      throw new Error("not a number");
    }
    return Number.parseInt(out, 10);
  } catch (error) {
    throw new Error(
      `cannot read the git history at ${root}: ${error.message}. ` +
      "A checkout with no readable history cannot be numbered:  there is no timestamp fallback and no guess."
    );
  }
}

/** The committed record of a project root. */
export function loadRecord(root = DEFAULT_ROOT) {
  return readRecord(readFileSync(projectFile(root), "utf8"));
}

/** Write the record back into project.yml. */
export function saveRecord(root, version, build = version) {
  const file = projectFile(root);
  const text = readFileSync(file, "utf8");
  writeFileSync(file, renderRecord(text, version, build));
  return { version, build };
}

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        args[key] = true;
      } else {
        args[key] = next;
        i += 1;
      }
    } else {
      args._.push(arg);
    }
  }
  return args;
}

function usage() {
  console.error(
    [
      "Usage:",
      "  node version-number.mjs record [--root DIR]",
      "  node version-number.mjs next [--root DIR] [--known N] [--write]",
      "  node version-number.mjs write <version> [--build B] [--root DIR]"
    ].join("\n")
  );
}

function main(argv) {
  const args = parseArgs(argv);
  const command = args._[0] || "record";
  const root = args.root ? resolve(String(args.root)) : DEFAULT_ROOT;

  if (command === "record") {
    const { version, build } = loadRecord(root);
    process.stdout.write(`${version} ${build}\n`);
    return 0;
  }

  if (command === "next") {
    assertGitHistory(root);
    const record = loadRecord(root);
    const known = args.known === undefined ? 0 : Number.parseInt(String(args.known), 10);
    const plan = planShip({
      recorded: record.version,
      known: Number.isFinite(known) ? known : 0
    });
    if (args.write) {
      saveRecord(root, plan.version, plan.build);
    }
    process.stdout.write(`${plan.version} ${plan.build}\n`);
    return 0;
  }

  if (command === "write") {
    assertGitHistory(root);
    const version = args._[1];
    if (!version) {
      console.error("error: write needs a version, e.g. write 0.1.1");
      usage();
      return 2;
    }
    const build = args.build === undefined ? version : String(args.build);
    if (!parseVersionParts(version)) {
      console.error(`error: ${JSON.stringify(version)} is not a version string`);
      return 2;
    }
    saveRecord(root, version, build);
    process.stdout.write(`${version} ${build}\n`);
    return 0;
  }

  usage();
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  }
}

export { nextVersion };
