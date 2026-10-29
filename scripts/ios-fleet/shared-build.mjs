// Pure build planner.  No network, uploads or release state changes.
// One shared merge-timestamp build per release across iOS and macOS
// (owner, Oct 29 2026):  build = max(S, M + 1), a plain integer, where S is
// the merge stamp (the committer date of the squash-merge commit on main in
// America/Chicago as YYYYMMDDHHMM, a 12-digit string) and M is the highest
// first numeric component among every build of the app on iOS and of its
// paired macOS app (and vice versa), plus every extra floor.  Every build
// counts: expired builds, all version trains, and old timestamp-style builds
// on either platform.  No floor and no cap.  A rebuild of the same commit
// still goes up, because the first upload joined M.
const BUILD_RE = /^[0-9]+(\.[0-9]+){0,2}$/;
const STAMP_RE = /^[1-9][0-9]{11}$/;

// The first numeric component of one build version ("209912312359.1" ->
// 209912312359n).  Throws on anything that is not dot-separated integers,
// so a malformed record fails the plan instead of being guessed at.
export function maxFirstComponent(builds) {
  if (!Array.isArray(builds)) throw new Error('malformed build inventory');
  let best = 0n;
  for (const value of builds) {
    if (typeof value !== 'string' || !BUILD_RE.test(value)) {
      throw new Error('malformed build inventory');
    }
    const first = BigInt(value.split('.')[0]);
    if (first > best) best = first;
  }
  return best;
}

// The highest extra floor, or 0n when there is none.  A floor is a
// non-negative safe integer or a digit string (a Sparkle feed max can exceed
// the safe-integer range); anything else is malformed.
export function maxExtraFloor(extraFloors) {
  if (!Array.isArray(extraFloors)) throw new Error('malformed build inventory');
  let best = 0n;
  for (const floor of extraFloors) {
    let candidate = null;
    if (typeof floor === 'number') {
      if (!Number.isSafeInteger(floor) || floor < 0) throw new Error('malformed build inventory');
      candidate = BigInt(floor);
    } else if (typeof floor === 'string' && /^[0-9]+$/.test(floor)) {
      candidate = BigInt(floor);
    } else {
      throw new Error('malformed build inventory');
    }
    if (candidate > best) best = candidate;
  }
  return best;
}

export function nextSharedBuild({iosBuilds, macBuilds, extraFloors = [], complete, mergeStamp}) {
  if (complete !== true || !Array.isArray(iosBuilds) || !Array.isArray(macBuilds)) {
    throw new Error('complete build inventory required');
  }
  // Validate everything before computing; malformed evidence is never ignored.
  if (typeof mergeStamp !== 'string' || !STAMP_RE.test(mergeStamp)) {
    throw new Error('malformed merge stamp');
  }
  const stamp = BigInt(mergeStamp);
  const iosMax = maxFirstComponent(iosBuilds);
  const macMax = maxFirstComponent(macBuilds);
  const floorMax = maxExtraFloor(extraFloors);
  let highest = iosMax;
  if (macMax > highest) highest = macMax;
  if (floorMax > highest) highest = floorMax;
  const next = highest + 1n > stamp ? highest + 1n : stamp;
  return {build: String(next)};
}
