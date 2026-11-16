#!/usr/bin/env node
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import {nextIncrementalBuild} from './ios-fleet/shared-build.mjs';
import {inventory, readOnlyAPI, scopedToken} from './release-inventory.mjs';

const FEED = 'https://github.com/Simple-With-Us/HogHunter/releases/latest/download/appcast.xml';
const MANIFEST = 'https://github.com/Simple-With-Us/HogHunter/releases/latest/download/release-plan.json';
const SHA = /^[0-9a-f]{40}$/;
const BUILD = /^[1-9][0-9]{3,11}$/;
export class ReleasePending extends Error {}

// One identity per build execution. Paired job continuations carry its plan;
// independent rebuilds call this again, even for an identical source SHA.
export function buildStamp(startedAt) {
  const date = new Date(startedAt);
  if (!Number.isFinite(date.getTime())) throw new Error('Invalid build start time');
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Chicago', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
  }).formatToParts(date).map(p => [p.type, p.value]));
  const stamp = ['year', 'month', 'day', 'hour', 'minute'].map(k => parts[k]).join('');
  if (!/^[1-9][0-9]{11}$/.test(stamp)) throw new Error('Invalid Central-time build timestamp');
  return stamp;
}

export function feedFloor(xml) {
  const matches = [...xml.matchAll(/<sparkle:version>\s*([^<]*)\s*<\/sparkle:version>/g)];
  if (matches.length === 0) throw new Error('Published Sparkle build inventory is missing');
  const floors = matches.map(match => match[1].trim());
  if (floors.some(value => !/^[1-9][0-9]*$/.test(value))) throw new Error('Published Sparkle build inventory is malformed');
  return floors.reduce((a, b) => BigInt(a) > BigInt(b) ? a : b);
}

export function validatePlan(plan) {
  const keys = ['schemaVersion', 'sourceHead', 'marketingVersion', 'build', 'complete', 'platformFloors', ...(plan?.schemaVersion === 2 ? ['buildStartedAt'] : [])];
  if (!plan || typeof plan !== 'object' || Array.isArray(plan) || Object.keys(plan).sort().join() !== keys.sort().join()
      || ![1, 2].includes(plan.schemaVersion) || plan.complete !== true || !SHA.test(plan.sourceHead)
      || plan.marketingVersion !== '0.1.0' || typeof plan.build !== 'string' || !BUILD.test(plan.build)) {
    throw new Error('Unknown or incomplete published release plan');
  }
  const f = plan.platformFloors;
  if (!f || Object.keys(f).sort().join() !== 'ios,mac,sparkle' || Object.values(f).some(n => typeof n !== 'string' || !/^[0-9]+$/.test(n))) {
    throw new Error('Incomplete published release floors');
  }
  if (plan.schemaVersion === 1) {
    // Validate already published legacy manifests, but never allocate new counters.
    const expected = nextIncrementalBuild({iosBuilds: [f.ios], macBuilds: [f.mac], extraFloors: [f.sparkle], complete: true}).build;
    if (plan.build !== expected) throw new Error('Published release build disagrees with its verified floors');
  } else {
    if (typeof plan.buildStartedAt !== 'string' || plan.build !== buildStamp(plan.buildStartedAt)) {
      throw new Error('Build identity does not match its Central-time start timestamp');
    }
    if (Object.values(f).some(n => BigInt(n) >= BigInt(plan.build))) {
      throw new Error('Build timestamp is not above complete release floors; wait for a later minute, never bump a counter');
    }
  }
  return plan;
}

export function makePlan({sourceHead, evidence, sparkleFloor, existingPlan = null, buildStartedAt = new Date().toISOString()}) {
  if (!SHA.test(sourceHead) || evidence?.complete !== true || evidence.bundleId !== 'com.simplewithus.hoghunter.ios') throw new Error('Complete release identity and inventory required');
  const ios = evidence.platforms?.IOS?.highestBuildComponent;
  const mac = evidence.platforms?.MAC_OS?.highestBuildComponent;
  if ([ios, mac, sparkleFloor].some(n => typeof n !== 'string' || !/^[0-9]+$/.test(n))) throw new Error('Complete release floors required');
  if (existingPlan) {
    validatePlan(existingPlan);
    if (existingPlan.build !== sparkleFloor) throw new Error('Latest feed and release plan disagree');
  }
  const build = buildStamp(buildStartedAt);
  return validatePlan({schemaVersion: 2, sourceHead, marketingVersion: '0.1.0', build, buildStartedAt, complete: true, platformFloors: {ios, mac, sparkle: sparkleFloor}});
}

export function isReleasePath(path) {
  if (/^scripts\/ios-fleet\/(test-[^/]+|README\.md)$/.test(path)) return false;
  return /^(ios\/|Sources\/|Assets\.xcassets(?:\/|$)|macos\/|project\.yml$|HogHunter\.entitlements$|scripts\/(?:mac-release-build\.sh|make_appcast\.sh|build-run-stamp\.sh|install\.sh|release-build-policy\.mjs|release-inventory\.mjs|infisical-fetch\.mjs|ios-[^/]+\.sh)$|scripts\/ios-fleet\/|\.github\/workflows\/(?:mac-release|ios-testflight)\.yml$|\.github\/actions\/infisical-secrets\/)/.test(path);
}

export function selectPlan({plan, requestedHead, sparkleFloor, isAncestor, changedPaths = []}) {
  validatePlan(plan);
  if (!SHA.test(requestedHead) || plan.build !== sparkleFloor) throw new Error('Requested source or published feed disagrees with the release plan');
  if (plan.sourceHead !== requestedHead && (!isAncestor || changedPaths.some(isReleasePath))) {
    throw new ReleasePending('Matching Mac release is not published yet');
  }
  return plan;
}

async function publicText(url, {optional = false} = {}) {
  const response = await fetch(url, {signal: AbortSignal.timeout(30000)});
  if (optional && response.status === 404) return null;
  if (!response.ok) throw new Error(`Published release read failed (HTTP ${response.status})`);
  const text = await response.text();
  if (text.length > 5000000) throw new Error('Published release evidence exceeds the size limit');
  return text;
}

async function published() {
  const [xml, text] = await Promise.all([publicText(FEED), publicText(MANIFEST, {optional: true})]);
  const sparkleFloor = feedFloor(xml);
  const existingPlan = text === null ? null : validatePlan(JSON.parse(text));
  if (existingPlan && existingPlan.build !== sparkleFloor) throw new Error('Latest feed and release plan disagree');
  return {sparkleFloor, existingPlan};
}

async function main() {
  const [mode, sourceHead, repoRoot] = process.argv.slice(2);
  if (mode === '--validate-execution') {
    const encoded = process.env.HOGHUNTER_EXECUTION_PLAN_B64;
    if (!encoded || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw new Error('HOGHUNTER_EXECUTION_PLAN_B64 is missing or malformed');
    const plan = validatePlan(JSON.parse(Buffer.from(encoded, 'base64').toString('utf8')));
    if (plan.schemaVersion !== 2 || plan.sourceHead !== sourceHead) throw new Error('Execution plan source mismatch');
    console.log(JSON.stringify(plan));
    return;
  }
  if (!['--plan', '--preview-plan', '--read-plan', '--ios-plan'].includes(mode) || !SHA.test(sourceHead)) throw new Error('Release operation and exact source SHA are required');
  const buildStartedAt = new Date().toISOString();
  const pub = await published();
  if (mode === '--read-plan' || mode === '--ios-plan') {
    if (!pub.existingPlan) throw new ReleasePending('Mac release plan is not published yet');
    let isAncestor = false;
    let changedPaths = [];
    if (pub.existingPlan.sourceHead !== sourceHead) {
      if (!repoRoot) throw new Error('Repository history is required to verify a newer source');
      try {
        execFileSync('git', ['-C', repoRoot, 'merge-base', '--is-ancestor', pub.existingPlan.sourceHead, sourceHead], {stdio: 'ignore'});
        isAncestor = true;
        changedPaths = execFileSync('git', ['-C', repoRoot, 'diff', '--name-only', `${pub.existingPlan.sourceHead}..${sourceHead}`], {encoding: 'utf8'}).trim().split('\n').filter(Boolean);
      } catch { throw new ReleasePending('Published release does not cover the requested source'); }
    }
    const covered = selectPlan({plan: pub.existingPlan, requestedHead: sourceHead, sparkleFloor: pub.sparkleFloor, isAncestor, changedPaths});
    if (mode === '--read-plan') {
      console.log(JSON.stringify(covered));
    } else {
      const evidence = await inventory(readOnlyAPI(scopedToken(process.env)));
      console.log(JSON.stringify(makePlan({sourceHead: covered.sourceHead, evidence, ...pub, buildStartedAt})));
    }
    return;
  }
  const evidence = await inventory(readOnlyAPI(scopedToken(process.env)));
  console.log(JSON.stringify(makePlan({sourceHead, evidence, ...pub, buildStartedAt, ...(mode === '--preview-plan' ? {existingPlan: null} : {})})));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {console.error(error.message); process.exitCode = error instanceof ReleasePending ? 3 : 1;});
}
