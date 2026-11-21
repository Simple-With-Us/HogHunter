import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { publicBuildReadiness } from './asc-api.mjs';
import { tfReadyOutcomeLine, tfReadySummaryLabel, tfReadyGithubAnnotation } from '../ios-report-post-sync-tf-ready.mjs';

function fixture({ state = 'IN_BETA_TESTING', assigned = true, members = true, assignmentError = false, missingGroup = false, expired = false, processingState = 'VALID', paginated = false } = {}) {
  const calls = [];
  const group = { id: 'public', attributes: { name: 'Public Beta', isInternalGroup: false, publicLinkEnabled: true } };
  const build = { id: 'wanted', attributes: { version: '202611210620', expired, processingState } };
  const api = async (method, url) => {
    calls.push({ method, url });
    assert.equal(method, 'GET', 'readiness must never mutate Apple settings');
    if (url.includes('/apps/app/betaGroups')) return { ok: true, parsed: { data: missingGroup ? [] : [group] } };
    if (url.includes('/betaTesters')) return { ok: true, parsed: { data: members ? [{ id: 'tester', attributes: { email: 'synthetic@example.invalid' } }] : [] } };
    if (url.includes('/builds')) {
      if (assignmentError) return { ok: false, status: 403 };
      if (paginated && !url.includes('page=2')) return { ok: true, parsed: { data: [], links: { next: '/v1/betaGroups/public/builds?page=2' } } };
      return { ok: true, parsed: { data: assigned ? [build] : [{ id: 'older', attributes: build.attributes }] } };
    }
    throw new Error('unexpected route');
  };
  return { calls, run: () => publicBuildReadiness({ api, appId: 'app', buildId: 'wanted', externalBuildState: state }) };
}

test('external approval, exact valid assignment and tester control can qualify', async () => {
  const f = fixture(); const r = await f.run();
  assert.equal(r.rc, 0); assert.equal(r.testers, 1); assert.equal(r.groupId, 'public');
  assert.ok(f.calls.some(c => c.url.includes('/public/builds')));
});
for (const state of ['WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW']) {
  test(`processed with testers but external ${state} cannot qualify`, async () => {
    const f = fixture({ state }); const r = await f.run();
    assert.equal(r.rc, 7); assert.notEqual(r.rc, (await fixture().run()).rc);
  });
}
test('missing external state stays unknown', async () => assert.equal((await fixture({ state: '' }).run()).rc, 6));
test('approved different build in group cannot qualify this build', async () => assert.equal((await fixture({ assigned: false }).run()).rc, 8));
test('assignment read refusal stays unknown rather than claiming installability', async () => assert.equal((await fixture({ assignmentError: true }).run()).rc, 6));
test('public group with no testers stays distinct', async () => assert.equal((await fixture({ members: false }).run()).rc, 5));
test('expired build cannot qualify', async () => assert.equal((await fixture({ expired: true }).run()).rc, 6));
test('unprocessed assigned build cannot qualify', async () => assert.equal((await fixture({ processingState: 'PROCESSING' }).run()).rc, 6));
test('assignment proof follows pagination to exact build', async () => assert.equal((await fixture({ paginated: true }).run()).rc, 0));
test('pending output never claims external installability or export compliance failure', () => {
  const line = tfReadyOutcomeLine(7, { bundleId: 'synthetic', buildNum: '202611210620' });
  assert.match(line, /external Beta App Review/); assert.doesNotMatch(line, /can install|export compliance/);
  assert.match(tfReadySummaryLabel(7), /pending/);
  const old = process.env.GITHUB_ACTIONS; process.env.GITHUB_ACTIONS = 'true';
  assert.match(tfReadyGithubAnnotation(7, { bundleId: 'synthetic', buildNum: '202611210620' }), /Review is pending/);
  if (old === undefined) delete process.env.GITHUB_ACTIONS; else process.env.GITHUB_ACTIONS = old;
});
test('actual shell wrapper treats external-pending as advisory after upload', () => {
  const source = readFileSync(new URL('./ship-testflight.sh', import.meta.url), 'utf8');
  const start = source.indexOf('ensure_tf_ready() {'); const end = source.indexOf('\nacquire_archive_lock', start);
  assert.ok(start > 0 && end > start);
  const dir = mkdtempSync(join(tmpdir(), 'hh-ready-'));
  try {
    const script = `set -euo pipefail\nASC_NODE=node\nLOG_DIR=${JSON.stringify(dir)}\nBUNDLE_ID=synthetic\nBUILD_NUM=202611210620\nMARKETING=0.1.0\nTESTER_POLICY=public-group\nREPO_ROOT=${JSON.stringify(dir)}\nPREV_SHIP_SHA=\nDISPLAY_NAME=synthetic\nIOS_PATH_PREFIX=ios\nGITHUB_ACTIONS=true\nlog(){ printf '%s\\n' "$*"; }\nasc_client(){ return 7; }\n${source.slice(start, end)}\nensure_tf_ready\necho BOOKKEEPING_CONTINUES\n`;
    const r = spawnSync('bash', ['-c', script], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr); assert.match(r.stdout, /BOOKKEEPING_CONTINUES/);
    assert.match(r.stdout, /Beta App Review pending/); assert.doesNotMatch(r.stdout, /public group testers can install this build/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

for (const state of ['READY_FOR_BETA_SUBMISSION', 'BETA_REJECTED', 'EXPIRED', 'PROCESSING_EXCEPTION', 'MISSING_EXPORT_COMPLIANCE', 'READY_FOR_BETA_TESTING', 'PROCESSING']) {
  test(`external ${state} requires attention, not review-pending`, async () => {
    const r = await fixture({ state }).run(); assert.equal(r.rc, 8); assert.equal(r.externalBuildState, state);
    assert.doesNotMatch(r.reason, /pending/);
  });
}
test('new external state is unknown, not assumed pending', async () => assert.equal((await fixture({ state: 'FUTURE_STATE' }).run()).rc, 6));
test('post-sync output distinguishes attention from review-pending', () => {
  const ctx = { bundleId: 'synthetic', buildNum: '202611210620' };
  assert.match(tfReadyOutcomeLine(8, ctx), /needs attention/);
  assert.doesNotMatch(tfReadyOutcomeLine(8, ctx), /pending|unnecessary|no repeat upload/);
});
for (const interpreterFails of [false, true]) test(`actual readiness wrapper records upload success with evidence interpreter failure=${interpreterFails}`, () => {
  const source = readFileSync(new URL('./ship-testflight.sh', import.meta.url), 'utf8');
  const start = source.indexOf('ensure_tf_ready() {'); const end = source.indexOf('\nacquire_archive_lock', start);
  const bookStart = source.indexOf('record_successful_ship() {'); const bookEnd = source.indexOf('\nwhile [[ $# -gt 0 ]]', bookStart);
  const dir = mkdtempSync(join(tmpdir(), 'hh-bookkeeping-'));
  try {
    const script = `set -euo pipefail
ASC_NODE=${interpreterFails ? "/bin/false" : "node"}
LOG_DIR=${JSON.stringify(dir)}
STATE_DIR=${JSON.stringify(dir)}
FLEET_DIR=${JSON.stringify(dir)}
BUNDLE_ID=synthetic
BUILD_NUM=202611210620
MARKETING=0.1.0
TESTER_POLICY=public-group
REPO_ROOT=${JSON.stringify(dir)}
PREV_SHIP_SHA=
DISPLAY_NAME=synthetic
IOS_PATH_PREFIX=ios
APP_KEY=hoghunter
GITHUB_ACTIONS=true
log(){ printf '%s\\n' "$*"; }
asc_client(){ printf '%s' '{"externalBuildState":"IN_BETA_TESTING","readiness":{"reason":"this build is not assigned to public group"}}'; return 8; }
ship_state_path(){ printf '%s' ${JSON.stringify(join(dir, 'last-ship'))}; }
repo_head_sha(){ echo abcdef0123456789; }
json_get(){ return 0; }
${source.slice(bookStart, bookEnd)}
${source.slice(start, end)}
ensure_tf_ready
record_successful_ship
cat ${JSON.stringify(join(dir, 'last-ship'))}
`;
    const r = spawnSync('bash', ['-c', script], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    if (interpreterFails) assert.match(r.stdout, /evidence formatting unavailable/);
    else assert.match(r.stdout, /this build is not assigned to public group/);
    assert.doesNotMatch(r.stdout, /Apple approval pending|Review pending/);
    assert.match(r.stdout, /::warning::TestFlight external distribution needs attention/);
    assert.match(r.stdout, /ship-gate: recorded success/);
    assert.match(r.stdout, /abcdef0123456789/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('missing public group is attention, not empty tester count', async () => {
  const r = await fixture({ missingGroup: true }).run();
  assert.equal(r.rc, 8); assert.equal(r.reason, 'public group missing');
  assert.equal((await fixture({ members: false }).run()).rc, 5);
});
test('unknown readiness shell diagnostics do not misattribute every cause to group reads', () => {
  const source = readFileSync(new URL('./ship-testflight.sh', import.meta.url), 'utf8');
  const start = source.indexOf('  if [[ $rc -eq 6 ]]; then', source.indexOf('ensure_tf_ready() {'));
  const block = source.slice(start, source.indexOf('  log "warning: ensure-tf-ready failed', start));
  assert.match(block, /external approval, public groups or exact build assignment/);
  assert.doesNotMatch(block, /could not read the beta groups/);
});
