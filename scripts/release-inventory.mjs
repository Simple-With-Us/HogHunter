#!/usr/bin/env node
// Read-only inventory for the official workflow's already scope-checked ASC key.
// No CLI credential bootstrap, files, fallback identity, writes or uploads.
import {createSign} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {normalizePrivateKey} from './ios-fleet/asc-key.mjs';

const ORIGIN = 'https://api.appstoreconnect.apple.com';
const APP_ID = '6816633156';
const BUNDLE_ID = 'com.simplewithus.hoghunter.ios';

export function scopedToken(env) {
  const keyId = env.APPLE_API_KEY_ID;
  const issuer = env.APPLE_API_ISSUER_ID;
  const supplied = env.APPLE_API_KEY_P8_BASE64;
  if (!keyId || !issuer || !supplied) throw new Error('Scoped workflow ASC environment is required');
  const pem = normalizePrivateKey(Buffer.from(supplied, 'base64').toString('utf8'));
  if (!pem) throw new Error('Scoped workflow ASC private key is invalid');
  const now = Math.floor(Date.now() / 1000);
  const b64 = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const message = `${b64({alg: 'ES256', kid: keyId, typ: 'JWT'})}.${b64({iss: issuer, iat: now, exp: now + 600, aud: 'appstoreconnect-v1'})}`;
  const signer = createSign('SHA256');
  signer.update(message);
  signer.end();
  return `${message}.${signer.sign({key: pem, dsaEncoding: 'ieee-p1363'}).toString('base64url')}`;
}

export async function allRows(api, first) {
  const result = [];
  const seen = new Set();
  let next = first;
  while (next) {
    const url = new URL(next, ORIGIN);
    if (url.origin !== ORIGIN || url.username || url.password || !url.pathname.startsWith('/v1/') || seen.has(url.href) || seen.size >= 100) {
      throw new Error('Invalid or incomplete ASC pagination');
    }
    seen.add(url.href);
    const page = await api(url.href);
    if (!Array.isArray(page?.data)) throw new Error('Malformed ASC inventory');
    result.push(...page.data);
    if (page.links != null && (typeof page.links !== 'object' || Array.isArray(page.links))) throw new Error('Malformed ASC pagination');
    const link = page.links?.next;
    if (link != null && typeof link !== 'string') throw new Error('Malformed ASC pagination');
    next = link || '';
  }
  return result;
}

export async function inventory(api) {
  const app = await api(`${ORIGIN}/v1/apps/${APP_ID}`);
  if (app?.data?.id !== APP_ID || app.data.attributes?.bundleId !== BUNDLE_ID) throw new Error('ASC app identity mismatch');
  const platforms = {};
  for (const platform of ['IOS', 'MAC_OS']) {
    const builds = await allRows(api, `/v1/builds?filter[app]=${APP_ID}&filter[preReleaseVersion.platform]=${platform}&limit=200`);
    const trains = await allRows(api, `/v1/preReleaseVersions?filter[app]=${APP_ID}&filter[platform]=${platform}&limit=200`);
    const versions = await allRows(api, `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=${platform}&limit=200`);
    let max = 0n;
    const rows = builds.map(build => {
      const a = build?.attributes;
      if (!a || typeof a.version !== 'string' || !/^[0-9]+(\.[0-9]+){0,2}$/.test(a.version)) throw new Error('Malformed ASC build version');
      const first = BigInt(a.version.split('.')[0]);
      if (first > max) max = first;
      return {id: build.id, version: a.version, uploadedDate: a.uploadedDate, processingState: a.processingState, expired: a.expired};
    });
    for (const train of trains) {
      if (typeof train.attributes?.version !== 'string' || train.attributes?.platform !== platform) throw new Error('Malformed ASC prerelease version');
    }
    for (const version of versions) {
      if (typeof version.attributes?.versionString !== 'string' || !(version.attributes?.appVersionState || version.attributes?.appStoreState)) throw new Error('Malformed ASC App Store version');
    }
    platforms[platform] = {
      highestBuildComponent: String(max),
      builds: rows,
      prereleaseVersions: trains.map(row => ({id: row.id, version: row.attributes?.version, platform: row.attributes?.platform})),
      appStoreVersions: versions.map(row => ({id: row.id, version: row.attributes?.versionString, state: row.attributes?.appVersionState || row.attributes?.appStoreState}))
    };
  }
  return {appId: APP_ID, bundleId: BUNDLE_ID, sourceHead: process.env.GITHUB_SHA || null, checkedAt: new Date().toISOString(), complete: true, platforms};
}

export function readOnlyAPI(token, fetchImpl = fetch) {
  return async url => {
    const response = await fetchImpl(url, {method: 'GET', redirect: 'error', headers: {Authorization: `Bearer ${token}`}, signal: AbortSignal.timeout(30000)});
    if (!response.ok) throw new Error(`ASC inventory GET failed (HTTP ${response.status})`);
    return response.json();
  };
}

async function main() {
  console.log(JSON.stringify(await inventory(readOnlyAPI(scopedToken(process.env))), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {console.error(error.message); process.exitCode = 1;});
}
