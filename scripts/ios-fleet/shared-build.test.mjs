import test from 'node:test';
import assert from 'node:assert/strict';
import {maxExtraFloor, maxFirstComponent, nextSharedBuild as next} from './shared-build.mjs';
const STAMP = '202610290531';
const input = {iosBuilds: [], macBuilds: [], complete: true, mergeStamp: STAMP};
test('a fresh app ships the merge stamp', () => {
  assert.deepEqual(next(input), {build: STAMP});
});
test('existing builds below the stamp still ship the stamp', () => {
  assert.deepEqual(next({...input, iosBuilds: ['101', '2394']}), {build: STAMP});
  assert.deepEqual(next({...input, macBuilds: ['0.1.3']}), {build: STAMP});
  assert.deepEqual(next({...input, extraFloors: [1500]}), {build: STAMP});
});
test('an existing build at or above the stamp moves one up', () => {
  assert.deepEqual(next({...input, iosBuilds: [STAMP]}), {build: '202610290532'});
  assert.deepEqual(next({...input, iosBuilds: ['209912312359']}), {build: '209912312360'});
  assert.deepEqual(next({...input, macBuilds: ['209912312359']}), {build: '209912312360'});
});
test('a rebuild of the same commit still goes up', () => {
  const first = next(input).build;
  assert.equal(first, STAMP);
  assert.deepEqual(next({...input, iosBuilds: [first]}), {build: '202610290532'});
});
test('iOS timestamp builds count now', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645', '202610180127']}),
    {build: STAMP}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645', STAMP]}),
    {build: '202610290532'}
  );
});
test('a mac-only higher build wins across platforms', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['1100'], macBuilds: ['202610290540']}),
    {build: '202610290541'}
  );
});
test('the shared build sits above every source at once', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['1200'], macBuilds: ['1300'], extraFloors: [1400]}),
    {build: STAMP}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['202610290540'], macBuilds: ['1300'], extraFloors: [1400]}),
    {build: '202610290541'}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['1200'], macBuilds: ['202610290540'], extraFloors: [1400]}),
    {build: '202610290541'}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['1200'], macBuilds: ['1300'], extraFloors: ['202610290540']}),
    {build: '202610290541'}
  );
});
test('dotted builds compare by first component', () => {
  assert.deepEqual(next({...input, iosBuilds: ['0.1.3', '1.1.2']}), {build: STAMP});
  assert.deepEqual(
    next({...input, iosBuilds: ['202610290540.1']}),
    {build: '202610290541'}
  );
});
test('extra floors accept safe integers and digit strings', () => {
  assert.equal(maxExtraFloor([]), 0n);
  assert.equal(maxExtraFloor([1500, '1400', 0]), 1500n);
  assert.equal(maxExtraFloor(['202610290540']), 202610290540n);
  assert.throws(() => maxExtraFloor([-1]), /malformed build inventory/);
  assert.throws(() => maxExtraFloor([1.5]), /malformed build inventory/);
  assert.throws(() => maxExtraFloor([NaN]), /malformed build inventory/);
  assert.throws(() => maxExtraFloor([null]), /malformed build inventory/);
  assert.throws(() => maxExtraFloor(['']), /malformed build inventory/);
  assert.throws(() => maxExtraFloor(['1.5']), /malformed build inventory/);
  assert.throws(() => maxExtraFloor([' 1500']), /malformed build inventory/);
  assert.throws(() => maxExtraFloor('1500'), /malformed build inventory/);
});
test('maxFirstComponent takes the highest first component', () => {
  assert.equal(maxFirstComponent([]), 0n);
  assert.equal(maxFirstComponent(['101', '2394.2', '2394']), 2394n);
  assert.equal(maxFirstComponent(['202610190645']), 202610190645n);
});
test('a bad merge stamp throws before computing', () => {
  for (const bad of [null, undefined, 202610290531, '', '02610290531', '20261029053', '2026102905311', '20261029053a', ' 202610290531', '000000000000']) {
    assert.throws(() => next({...input, mergeStamp: bad}), /malformed merge stamp/);
  }
});
test('malformed inventory throws before computing', () => {
  for (const bad of [null, 'NaN', '1.2.3.4', 42, '', ' 1000', 'v1']) {
    assert.throws(() => next({...input, iosBuilds: [bad]}), /malformed build inventory/);
    assert.throws(() => next({...input, macBuilds: [bad]}), /malformed build inventory/);
  }
  for (const bad of [-1, 1.5, NaN, null]) {
    assert.throws(() => next({...input, extraFloors: [bad]}), /malformed build inventory/);
  }
  // A malformed entry is reported even when a range error would also apply.
  assert.throws(() => next({...input, iosBuilds: ['209912312359', 'NaN']}), /malformed build inventory/);
  assert.throws(() => next({...input, mergeStamp: 'nope', iosBuilds: ['NaN']}), /malformed merge stamp/);
});
test('incomplete inventory refuses', () => {
  assert.throws(() => next({...input, complete: false}), /complete build inventory required/);
  assert.throws(() => next({...input, complete: undefined}), /complete build inventory required/);
  assert.throws(() => next({iosBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
  assert.throws(() => next({macBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
  assert.throws(() => next({iosBuilds: '1000', macBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
});
test('a plan above 12 digits throws instead of shipping it', () => {
  assert.throws(() => next({...input, iosBuilds: ['999999999999']}), /planned build exceeds 12 digits/);
  assert.throws(() => next({...input, macBuilds: ['123456789012345678']}), /planned build exceeds 12 digits/);
  assert.throws(() => next({...input, extraFloors: ['999999999999']}), /planned build exceeds 12 digits/);
  assert.throws(() => next({...input, extraFloors: ['1000000000000']}), /planned build exceeds 12 digits/);
  assert.deepEqual(next({...input, iosBuilds: ['999999999998']}), {build: '999999999999'});
  assert.throws(() => next({...input, iosBuilds: ['999999999999', 'NaN']}), /malformed build inventory/);
});
