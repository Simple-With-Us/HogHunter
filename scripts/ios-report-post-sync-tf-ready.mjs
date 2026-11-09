// After standing-tester sync, re-run ensure-tf-ready and record the outcome on
// the job summary. The in-ship check runs before sync, so only this pass can
// see testers and groups the sync step just created.
import { appendFileSync, realpathSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL("..", import.meta.url));

function appsHoghunter() {
  return require("./ios-fleet/apps.json").apps.hoghunter;
}

/** Short label for workflow job summary (second readiness check). */
export function tfReadySummaryLabel(rc) {
  switch (rc) {
    case 0:
      return "public group testers can install this build";
    case 5:
      return "processed but no beta-group tester can install yet";
    case 6:
      return "processed but beta group installability is unverified";
    case 3:
      return "upload ok; ASC not IN_BETA_TESTING yet";
    case 4:
      return "build not surfaced; export compliance not declared";
    case 2:
      return "ensure-tf-ready API/usage error; export compliance not declared";
    default:
      return `ensure-tf-ready unexpected rc=${rc}`;
  }
}

/** Distinct summary lines per asc-api ensure-tf-ready exit code (public group). */
export function tfReadyOutcomeLine(rc, { bundleId, buildNum }) {
  switch (rc) {
    case 0:
      return `After tester sync: TestFlight public group testers can install build ${buildNum} for ${bundleId} (ensure-tf-ready rc=0).`;
    case 3:
      return `After tester sync: upload recorded but ASC has not reached IN_BETA_TESTING yet for build ${buildNum} (ensure-tf-ready rc=3).`;
    case 4:
      return `After tester sync: ASC never surfaced build ${buildNum} for ${bundleId}; export compliance not declared (ensure-tf-ready rc=4).`;
    case 5:
      return `After tester sync: build ${buildNum} is ready but the beta group has no tester who can install it for ${bundleId} (ensure-tf-ready rc=5).`;
    case 6:
      return `After tester sync: build ${buildNum} is ready but beta group installability is unverified for ${bundleId} (ensure-tf-ready rc=6).`;
    default:
      return `After tester sync: ensure-tf-ready failed (rc=${rc}) for ${bundleId} build ${buildNum}; export compliance not declared.`;
  }
}

export function tfReadyGithubAnnotation(rc, { bundleId, buildNum }) {
  if (process.env.GITHUB_ACTIONS !== "true") return null;
  switch (rc) {
    case 4:
      return `::warning::ensure-tf-ready could not find uploaded build ${buildNum} for ${bundleId}; export compliance not declared`;
    case 5:
      return `::warning::ensure-tf-ready: build ${buildNum} is ready, but the beta group has no tester who can install it`;
    case 6:
      return `::warning::ensure-tf-ready could not read the beta groups for ${bundleId}; installability is unverified`;
    case 2:
    default:
      if (rc === 3 || rc === 0) return null;
      return `::warning::ensure-tf-ready failed (rc=${rc}) for ${bundleId} build ${buildNum}; export compliance not declared`;
  }
}

function main() {
  const buildNum = process.env.PLAN_BUILD || process.argv[2];
  if (!buildNum || !/^[1-9]\d{11}$/.test(buildNum)) {
    console.error("PLAN_BUILD must be a 12-digit merge-timestamp build");
    process.exit(2);
  }
  const app = appsHoghunter();
  const { bundleId, fixedMarketingVersion: marketing, appleId, testerPolicy } = app;
  const policy = String(testerPolicy || "public-group").trim() || "public-group";
  const logDir = process.env.RUNNER_TEMP || "/tmp";
  const out = `${logDir}/ensure-tf-ready-post-sync.json`;
  const err = `${logDir}/ensure-tf-ready-post-sync.err`;
  const args = [
    `${root}/scripts/ios-fleet/asc-api.mjs`,
    "ensure-tf-ready",
    bundleId,
    buildNum,
    marketing,
    String(appleId),
    "--policy",
    policy,
  ];
  const result = spawnSync(process.execPath, args, { encoding: "utf8", env: process.env });
  if (result.stdout) writeFileSync(out, result.stdout);
  if (result.stderr) {
    writeFileSync(err, result.stderr);
    process.stderr.write(result.stderr);
  }
  const rc = result.status ?? 1;
  const ctx = { bundleId, buildNum };
  const line = tfReadyOutcomeLine(rc, ctx);
  const summary = tfReadySummaryLabel(rc);
  console.log(line);
  const annotation = tfReadyGithubAnnotation(rc, ctx);
  if (annotation) console.log(annotation);
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `tf_ready_rc=${rc}\n` +
        `tf_ready_summary=${summary}\n` +
        `tf_ready_bundle=${bundleId}\n` +
        `tf_ready_build=${buildNum}\n`,
    );
  }
  // Loud warnings only; the upload already succeeded.
  process.exit(0);
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
) {
  main();
}
