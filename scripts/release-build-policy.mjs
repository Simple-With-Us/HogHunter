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

export function feedFloor(xml) {
  const matches = [...xml.matchAll(/<sparkle:version>\s*([^<]*)\s*<\/sparkle:version>/g)];
  if (matches.length === 0) throw new Error('Published Sparkle build inventory is missing');
  const floors = matches.map(match => match[1].trim());
  if (floors.some(value => !/^[1-9][0-9]*$/.test(value))) throw new Error('Published Sparkle build inventory is malformed');
  return floors.reduce((a, b) => BigInt(a) > BigInt(b) ? a : b);
}

export function validatePlan(plan) {
  const keys = ['schemaVersion', 'sourceHead', 'marketingVersion', 'build', 'complete', 'platformFloors'];
  if (!plan || typeof plan !== 'object' || Array.isArray(plan) || Object.keys(plan).sort().join() !== keys.sort().join()
      || plan.schemaVersion !== 1 || plan.complete !== true || !SHA.test(plan.sourceHead)
      || plan.marketingVersion !== '0.1.0' || typeof plan.build !== 'string' || !BUILD.test(plan.build)) {
    throw new Error('Unknown or incomplete published release plan');
  }
  const f = plan.platformFloors;
  if (!f || Object.keys(f).sort().join() !== 'ios,mac,sparkle' || Object.values(f).some(n => typeof n !== 'string' || !/^[0-9]+$/.test(n))) {
    throw new Error('Incomplete published release floors');
  }
  const expected = nextIncrementalBuild({iosBuilds: [f.ios], macBuilds: [f.mac], extraFloors: [f.sparkle], complete: true}).build;
  if (plan.build !== expected) throw new Error('Published release build disagrees with its verified floors');
  return plan;
}

export function makePlan({sourceHead, evidence, sparkleFloor, existingPlan = null}) {
  if (!SHA.test(sourceHead) || evidence?.complete !== true || evidence.bundleId !== 'com.simplewithus.hoghunter.ios') throw new Error('Complete release identity and inventory required');
  const ios = evidence.platforms?.IOS?.highestBuildComponent;
  const mac = evidence.platforms?.MAC_OS?.highestBuildComponent;
  if ([ios, mac, sparkleFloor].some(n => typeof n !== 'string' || !/^[0-9]+$/.test(n))) throw new Error('Complete release floors required');
  if (existingPlan) {
    validatePlan(existingPlan);
    if (existingPlan.build !== sparkleFloor) throw new Error('Latest feed and release plan disagree');
    if (existingPlan.sourceHead === sourceHead) {
      if ([ios, mac].some(n => BigInt(n) > BigInt(existingPlan.build))) throw new Error('Published release plan is below a newer uploaded build');
      return existingPlan;
    }
  }
  const build = nextIncrementalBuild({iosBuilds: [ios], macBuilds: [mac], extraFloors: [sparkleFloor], complete: true}).build;
  return validatePlan({schemaVersion: 1, sourceHead, marketingVersion: '0.1.0', build, complete: true, platformFloors: {ios, mac, sparkle: sparkleFloor}});
}

export function isReleasePath(path) {
  if (/^scripts\/ios-fleet\/(test-[^/]+|README\.md)$/.test(path)) return false;
  return /^(ios\/|Sources\/|Assets\.xcassets(?:\/|$)|macos\/|project\.yml$|HogHunter\.entitlements$|scripts\/(?:mac-release-build\.sh|make_appcast\.sh|release-build-policy\.mjs|release-inventory\.mjs|infisical-fetch\.mjs|ios-[^/]+\.sh)$|scripts\/ios-fleet\/|\.github\/workflows\/(?:mac-release|ios-testflight)\.yml$|\.github\/actions\/infisical-secrets\/)/.test(path);
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
  if (!['--plan', '--preview-plan', '--read-plan'].includes(mode) || !SHA.test(sourceHead)) throw new Error('Release operation and exact source SHA are required');
  const pub = await published();
  if (mode === '--read-plan') {
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
    console.log(JSON.stringify(selectPlan({plan: pub.existingPlan, requestedHead: sourceHead, sparkleFloor: pub.sparkleFloor, isAncestor, changedPaths})));
    return;
  }
  const evidence = await inventory(readOnlyAPI(scopedToken(process.env)));
  console.log(JSON.stringify(makePlan({sourceHead, evidence, ...pub, ...(mode === '--preview-plan' ? {existingPlan: null} : {})})));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {console.error(error.message); process.exitCode = error instanceof ReleasePending ? 3 : 1;});
}
