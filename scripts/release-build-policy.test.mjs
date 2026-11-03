import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {feedFloor, makePlan, selectPlan, validatePlan, isReleasePath, ReleasePending} from './release-build-policy.mjs';
import {nextIncrementalBuild as next} from './ios-fleet/shared-build.mjs';
const empty = {iosBuilds: [], macBuilds: [], complete: true};
const sourceHead = 'a'.repeat(40);
const evidence = {complete: true, bundleId: 'com.simplewithus.hoghunter.ios', platforms: {IOS: {highestBuildComponent: '202610301656'}, MAC_OS: {highestBuildComponent: '0'}}};
const create = () => makePlan({sourceHead, evidence, sparkleFloor: '214'});

test('counter starts at1000 and continues four-digit or previously uploaded timestamp floors', () => {
  assert.deepEqual(next(empty), {build: '1000'});
  assert.deepEqual(next({...empty, iosBuilds: ['1074']}), {build: '1075'});
  assert.deepEqual(next({...empty, macBuilds: ['1001'], extraFloors: ['1008']}), {build: '1009'});
  assert.deepEqual(next({...empty, iosBuilds: ['202610301656']}), {build: '202610301657'});
  assert.deepEqual(next({...empty, iosBuilds: ['202610301656.1'], macBuilds: ['202610301658']}), {build: '202610301659'});
  assert.throws(() => next({...empty, complete: false}), /complete build inventory/);
  assert.throws(() => next({...empty, iosBuilds: ['malformed']}), /malformed build inventory/);
  assert.throws(() => next({...empty, extraFloors: ['999999999999']}), /verified platform range/);
});

test('one source identity and counter are reused after either platform publishes', () => {
  const plan = create();
  assert.equal(plan.marketingVersion, '0.1.0');
  assert.equal(plan.build, '202610301657');
  assert.equal(plan.sourceHead, sourceHead);
  const reused = makePlan({sourceHead, evidence: {...evidence, platforms: {IOS: {highestBuildComponent: plan.build}, MAC_OS: {highestBuildComponent: '0'}}}, sparkleFloor: plan.build, existingPlan: plan});
  assert.deepEqual(reused, plan);
  const later = makePlan({sourceHead: 'b'.repeat(40), evidence, sparkleFloor: plan.build, existingPlan: plan});
  assert.equal(later.build, '202610301658');
});

test('partial, unknown or inconsistent plans cannot allocate or select a release', () => {
  const plan = create();
  for (const bad of [{...plan, complete: false}, {...plan, extra: true}, {...plan, sourceHead: 'unknown'}, {...plan, marketingVersion: '1.0.214'}, {...plan, build: '202610301658'}, {...plan, platformFloors: {ios: '1'}}]) {
    assert.throws(() => validatePlan(bad));
    assert.throws(() => selectPlan({plan: bad, requestedHead: sourceHead, sparkleFloor: plan.build}));
  }
  assert.throws(() => makePlan({sourceHead, evidence: {...evidence, complete: false}, sparkleFloor: '214'}));
  assert.throws(() => makePlan({sourceHead, evidence, sparkleFloor: '214', existingPlan: plan}), /disagree/);
  assert.throws(() => makePlan({sourceHead, evidence: {...evidence, platforms: {IOS: {highestBuildComponent: '202610301658'}, MAC_OS: {highestBuildComponent: '0'}}}, sparkleFloor: plan.build, existingPlan: plan}), /newer uploaded build/);
});

test('docs-only newer main reuses the published source while relevant or unrelated revisions defer', () => {
  const plan = create();
  const input = {plan, requestedHead: 'b'.repeat(40), sparkleFloor: plan.build, isAncestor: true};
  assert.equal(selectPlan({...input, changedPaths: ['docs/rollouts/update.md', 'README.md']}).sourceHead, sourceHead);
  for (const changedPaths of [['ios/Sources/App.swift'], ['Sources/Store/HogStore.swift'], ['scripts/ios-fleet/apps.json'], ['.github/workflows/ios-testflight.yml']]) {
    assert.throws(() => selectPlan({...input, changedPaths}), ReleasePending);
  }
  assert.throws(() => selectPlan({...input, isAncestor: false, changedPaths: []}), ReleasePending);
  assert.throws(() => selectPlan({...input, sparkleFloor: '1000'}), /disagrees/);
});

test('the Mac publisher is triggered for iOS-only changes and ships a unique fixed-version tag plus manifest', () => {
  const mac = readFileSync(new URL('../.github/workflows/mac-release.yml', import.meta.url), 'utf8');
  const push = mac.split('  push:\n')[1].split('  pull_request:\n')[0];
  for (const path of ["'ios/**'", "'scripts/ios-fleet/**'", "'.github/workflows/ios-testflight.yml'", "'scripts/release-build-policy.mjs'"]) assert.ok(push.includes(path), path);
  assert.ok(mac.includes('tag=v$short-build.$build'));
  assert.ok(mac.includes('dist/appcast.xml dist/release-plan.json'));
  const ios = readFileSync(new URL('../.github/workflows/ios-testflight.yml', import.meta.url), 'utf8');
  assert.ok(ios.includes("needs.plan-build.outputs.ready == 'true'"));
  assert.ok(ios.includes('ref: ${{ needs.plan-build.outputs.source_head }}'));
  assert.ok(ios.includes('mode=--preview-plan'));
  assert.equal(isReleasePath('ios/Sources/App.swift'), true);
  assert.equal(isReleasePath('scripts/ios-fleet/ship-testflight.sh'), true);
  assert.equal(isReleasePath('scripts/ios-fleet/test-next-shared-build.sh'), false);
  assert.equal(isReleasePath('docs/rollouts/update.md'), false);
});

test('published Sparkle floors fail closed without a numeric CFBundleVersion', () => {
  assert.equal(feedFloor('<rss><sparkle:version>214</sparkle:version></rss>'), '214');
  assert.equal(feedFloor('<sparkle:version>1004</sparkle:version><sparkle:version>1000</sparkle:version>'), '1004');
  assert.throws(() => feedFloor('<rss/>'), /missing/);
  assert.throws(() => feedFloor('<sparkle:version>1.0.214</sparkle:version>'), /malformed/);
});

test('the Mac scoped action exports planner aliases and reuses its staged notarization key', () => {
  const mac = readFileSync(new URL('../.github/workflows/mac-release.yml', import.meta.url), 'utf8');
  const credentials = mac.split('      - name: Load ASC credentials (Fleet-OPS prod /asc)')[1].split('      - name:')[0];
  assert.ok(credentials.includes('asc-mode: "true"'));
  assert.ok(credentials.includes('service-token: ${{ secrets.INFISICAL_ASC_READ_TOKEN }}'));
  assert.ok(mac.includes('NOTARY_KEY_PATH: ${{ env.ASC_KEY_PATH }}'));
  const gate = mac.split('      - name: Decide whether this run can publish')[1].split('      - name:')[0];
  for (const name of ['APPLE_API_KEY_ID', 'APPLE_API_ISSUER_ID', 'APPLE_API_KEY_P8_BASE64', 'ASC_KEY_PATH']) assert.ok(gate.includes(name));
  assert.doesNotMatch(gate, /\bASC_KEY_P8\b/);
});

test('an existing published release fails without upload, replacement or latest mutation', () => {
  const mac = readFileSync(new URL('../.github/workflows/mac-release.yml', import.meta.url), 'utf8');
  const body = mac.split('      - name: Publish the GitHub release')[1].split('        run: |\n')[1].split('\n      - name:')[0]
    .split('\n').map(line => line.replace(/^          /, '')).join('\n');
  const dir = mkdtempSync(join(tmpdir(), 'hh-release-publish-fixture-'));
  try {
    const calls = join(dir, 'calls');
    writeFileSync(join(dir, 'gh'), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n[ "$1" = release ] && [ "$2" = view ] && exit 0\nexit 97\n', {mode: 0o700});
    const result = spawnSync('bash', ['-eu', '-c', body], {encoding: 'utf8', env: {PATH: `${dir}:${process.env.PATH}`, CALLS: calls, TAG: 'v0.1.0-build.202610301657'}});
    assert.equal(result.status, 1);
    assert.equal(readFileSync(calls, 'utf8').trim(), 'release view v0.1.0-build.202610301657');
    assert.ok(result.stdout.includes('immutable'));
    assert.ok(!mac.includes('--clobber'));
    assert.ok(!mac.includes('gh release edit'));
  } finally {rmSync(dir, {recursive: true, force: true});}
});

test('explicit paired uploads must match the published counter and marketing version while exports remain isolated', () => {
  const script = readFileSync(new URL('./ios-fleet/ship-testflight.sh', import.meta.url), 'utf8');
  const declaration = script.match(/assert_paired_release_identity\(\) \{[\s\S]*?\n\}/)[0];
  const run = extra => spawnSync('bash', ['-eu', '-c', `${declaration}\nasc_next_shared_build() { printf '%s' "$EXPECTED"; }\nassert_paired_release_identity`], {
    encoding: 'utf8', env: {PATH: process.env.PATH, BUILD_NUMBER_POLICY: 'paired-release', EXPORT_ONLY: '0', BUILD_NUM: '202610301657', EXPECTED: '202610301657', MARKETING: '0.1.0', FIXED_MARKETING: '0.1.0', ...extra}
  });
  assert.equal(run({}).status, 0);
  assert.equal(run({BUILD_NUM: '202610301658'}).status, 1);
  assert.equal(run({MARKETING: '1.0.214'}).status, 1);
  assert.equal(run({EXPORT_ONLY: '1', BUILD_NUM: '202610301658', EXPECTED: ''}).status, 0);
  assert.ok(script.indexOf('\nassert_paired_release_identity || die') < script.indexOf('xcrun altool --upload-package'));
});
