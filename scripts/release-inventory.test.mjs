import test from 'node:test';
import assert from 'node:assert/strict';
import {allRows, inventory, scopedToken, readOnlyAPI} from './release-inventory.mjs';

test('credentialed requests use GET and refuse redirects', async () => {
  let called = 0;
  const api = readOnlyAPI('offline-fixture', async (url, options) => {
    called++;
    assert.equal(options.method, 'GET');
    assert.equal(options.redirect, 'error');
    assert.equal(options.body, undefined);
    assert.equal(options.headers.Authorization, 'Bearer offline-fixture');
    throw new TypeError('redirect refused');
  });
  await assert.rejects(api('https://api.appstoreconnect.apple.com/v1/apps/6816633156'), /redirect refused/);
  assert.equal(called, 1);
});

test('inventory requires the workflow environment without a credential bootstrap', () => {
  assert.throws(() => scopedToken({}), /Scoped workflow ASC environment is required/);
  assert.throws(() => scopedToken({ASC_KEY_ID: 'fixture', ASC_ISSUER_ID: 'fixture', ASC_KEY_PATH: '/never/read'}), /Scoped workflow ASC environment is required/);
});

test('all pages are required and foreign pagination is refused before a request', async () => {
  const requests = [];
  const api = async url => {
    requests.push(url);
    return requests.length === 1 ? {data: [{id: 'first'}], links: {next: '/v1/builds?page=2'}} : {data: [{id: 'second'}]};
  };
  assert.deepEqual(await allRows(api, '/v1/builds'), [{id: 'first'}, {id: 'second'}]);
  let called = 0;
  await assert.rejects(allRows(async () => {called++; return {data: [], links: {next: 'https://example.com/v1/builds'}};}, '/v1/builds'), /Invalid or incomplete/);
  assert.equal(called, 1);
  await assert.rejects(allRows(async () => ({data: [], links: {next: '/v1/builds'}}), '/v1/builds'), /Invalid or incomplete/);
  await assert.rejects(allRows(async () => ({data: [], links: {next: 2}}), '/v1/builds'), /Malformed ASC pagination/);
  await assert.rejects(allRows(async () => ({data: null}), '/v1/builds'), /Malformed ASC inventory/);
});

function fixtureApi({badBuild = false, badIdentity = false} = {}) {
  return async value => {
    const url = new URL(value);
    if (url.pathname === '/v1/apps/6816633156') return {data: {id: '6816633156', attributes: {bundleId: badIdentity ? 'another.app' : 'com.simplewithus.hoghunter.ios'}}};
    if (url.pathname === '/v1/builds') {
      return {data: url.searchParams.get('filter[preReleaseVersion.platform]') === 'IOS' ? [
        {id: 'old', attributes: {version: badBuild ? 'not-a-build' : '202610290531', expired: true}},
        {id: 'new', attributes: {version: '1074', expired: false, processingState: 'VALID'}}
      ] : []};
    }
    if (url.pathname === '/v1/preReleaseVersions') return {data: [{id: 'train', attributes: {version: '0.1.0', platform: url.searchParams.get('filter[platform]')}}]};
    if (url.pathname.endsWith('/appStoreVersions')) return {data: [{id: 'store', attributes: {versionString: '0.1.0', appVersionState: 'PREPARE_FOR_SUBMISSION'}}]};
    throw new Error('Unexpected fixture request');
  };
}

test('inventory preserves expired timestamp floors and separates platform and marketing evidence', async () => {
  const report = await inventory(fixtureApi());
  assert.equal(report.complete, true);
  assert.equal(report.platforms.IOS.highestBuildComponent, '202610290531');
  assert.equal(report.platforms.MAC_OS.highestBuildComponent, '0');
  assert.equal(report.platforms.IOS.builds[0].expired, true);
  assert.equal(report.platforms.IOS.prereleaseVersions[0].version, '0.1.0');
  assert.equal(report.platforms.IOS.appStoreVersions[0].state, 'PREPARE_FOR_SUBMISSION');
});

test('wrong app identity and malformed builds cannot produce a complete inventory', async () => {
  await assert.rejects(inventory(fixtureApi({badIdentity: true})), /identity mismatch/);
  await assert.rejects(inventory(fixtureApi({badBuild: true})), /Malformed ASC build/);
});
