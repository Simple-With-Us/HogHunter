#!/usr/bin/env node
/**
 * Wrap ios-ship-testflight.sh so Actions can gate post-sync recheck on a real upload.
 * Skipped ships (rate/same-HEAD gate) must not look like uploaded == true.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";

const uploadedRe =
  /upload path succeeded via xcodebuild export \(destination=upload\)|build .+ submitted for |upload submitted; watch TestFlight processing/;
const skippedRe =
  /ship-gate: exiting 0 before any version is resolved \(nothing consumed\)/;

const TAIL_MAX = 65536;
const OVERLAP = 8192;

function observeChunk(text, state) {
  const window = state.tail.slice(-OVERLAP) + text;
  if (!state.uploadedFound && uploadedRe.test(window)) {
    state.uploadedFound = true;
  }
  if (!state.skippedFound && skippedRe.test(window)) {
    state.skippedFound = true;
  }
  state.tail = (state.tail + text).slice(-TAIL_MAX);
}

function writeOutputs(outputs, uploadedToken, observed, extra = {}) {
  if (!outputs) return;
  const lines = [`uploaded=${uploadedToken}`, `ship_observed=${observed}`];
  for (const [key, value] of Object.entries(extra)) {
    lines.push(`${key}=${value}`);
  }
  fs.appendFileSync(outputs, `${lines.join("\n")}\n`);
}

const cmd = process.argv.slice(2);
if (cmd.length === 0) {
  console.error("usage: ios-observe-ship.mjs [command] [args...]");
  process.exit(2);
}

const outputs = process.env.GITHUB_OUTPUT?.trim();
const state = { tail: "", uploadedFound: false, skippedFound: false };
let spawnErr = "";

const child = spawn(cmd[0], cmd.slice(1), {
  stdio: ["inherit", "pipe", "pipe"],
  shell: false,
});

child.stdout.on("data", (chunk) => {
  const text = chunk.toString();
  observeChunk(text, state);
  process.stdout.write(chunk);
});
child.stderr.on("data", (chunk) => {
  const text = chunk.toString();
  observeChunk(text, state);
  process.stderr.write(chunk);
});

const exitPromise = new Promise((resolve) => {
  child.on("error", (err) => {
    spawnErr = String(err?.message ?? err);
    resolve({ code: 1, signal: null });
  });
  child.on("close", (code, signal) => {
    resolve({ code: code ?? (signal ? 1 : 0), signal });
  });
});

const { code } = await exitPromise;

if (spawnErr) {
  writeOutputs(outputs, "false", "spawn_error", { ship_spawn_error: spawnErr.replace(/\n/g, " ") });
  process.exit(1);
}

const uploaded = state.uploadedFound;
const skipped = state.skippedFound;

let observed = "none";
let uploadedToken = "false";
if (uploaded) {
  observed = "uploaded";
  uploadedToken = "true";
} else if (skipped) {
  observed = "skipped";
  uploadedToken = "false";
} else if (code === 0) {
  observed = "unknown_success";
  uploadedToken = "unknown";
} else {
  observed = "failed";
  uploadedToken = "false";
}

writeOutputs(outputs, uploadedToken, observed);
process.exit(code);
