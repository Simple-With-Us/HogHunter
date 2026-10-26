/**
 * version-plan.mjs - the pure rules behind the fleet's version numbering.
 *
 * Owner directive 2026-10-26 (HH-191).  This replaces the 2026-10-24 scheme
 * (AFC-517 / CT-2444) and the 1.0.<commit_count> scheme unified in #2801 on
 * 2026-10-18, which made App Store Connect show "1.0.2358 (2358)".
 *
 * ONE NUMBER, and it is a version string:
 *
 *   MARKETING_VERSION (CFBundleShortVersionString)
 *     = CURRENT_PROJECT_VERSION (CFBundleVersion)
 *     = <train>.<N>
 *
 * The two fields carry the SAME string, so App Store Connect shows
 * "0.1.1 (0.1.1)" and the pair describes one number.  There is no second
 * number anywhere:  not the repository commit count (retired), not a
 * timestamp (retired), not a bare integer beside the version.
 *
 * <train> is the major.minor the app's numbers live on:  "0.1" for Hog
 * Hunter and the other apps that are not on the App Store, "1.1" for
 * Congress.Trade, whose past numbers already used the 1.0 train.
 *
 * N is one past what the train already holds, so a number is never reused.
 * The train holds:
 *
 *   - the committed record (project.yml MARKETING_VERSION):  the version the
 *     last update shipped.  Every ship path reads it, so the Mac app and the
 *     iPhone app of one update carry the same number.
 *   - the App Store Connect state (iOS only):  the highest patch already used
 *     on that train, counting BOTH App Store versions
 *     (appStoreVersions.versionString) AND TestFlight trains
 *     (preReleaseVersions.version) for the app's platform -- IGNORING any
 *     TestFlight train that is a "drift train":  a <train>.N train that holds
 *     a build whose CFBundleVersion is exactly the string "N".  Those are the
 *     1.0.N (N) uploads the retired scheme produced (1.0.2358 holding build
 *     2358).  App Store versions are never ignored.
 *
 * The Mac path has no App Store Connect access, so it sees only the committed
 * record.  When App Store Connect already holds the next patch, the Mac path
 * is one number behind:  see
 * docs/rollouts/2026-10-26-version-scheme-one-number.md.
 *
 * This module is PURE:  no I/O, no network, no environment.  The bash ship
 * script implements the same rules; this module is the readable reference and
 * the unit-testable copy of them.  The I/O around it (reading and writing the
 * committed record) lives in ./version-number.mjs.
 */

/** Escape a string for literal use inside a RegExp. */
function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * The patch number of a version on a train.
 *
 * parsePatch("1.0.236", "1.0") -> 236
 * parsePatch("1.0", "1.0")     -> null   (no patch component)
 * parsePatch("1.01.5", "1.0")  -> null   (not "<prefix>.<digits>")
 * parsePatch("2.0.5", "1.0")   -> null   (a different train)
 *
 * The prefix is escaped, so a prefix of "1.0" can never match "120.5".
 */
export function parsePatch(version, prefix) {
  if (version === null || version === undefined) return null;
  if (prefix === null || prefix === undefined) return null;
  const value = String(version).trim();
  const train = String(prefix).trim();
  if (!value || !train) return null;
  const re = new RegExp(`^${escapeRegExp(train)}\\.(\\d+)$`);
  const match = re.exec(value);
  if (!match) return null;
  const patch = parseInt(match[1], 10);
  return Number.isFinite(patch) ? patch : null;
}

/**
 * The patch of a version on ITS OWN train ("2.0.5" -> 5).  Used where the
 * train is the version itself rather than a prefix to match against.
 */
export function ownPatch(version) {
  if (version === null || version === undefined) return null;
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(version).trim());
  if (!match) return null;
  const patch = parseInt(match[3], 10);
  return Number.isFinite(patch) ? patch : null;
}

/**
 * The three parts of a version string.
 *
 * parseVersionParts("0.1.1") -> { major: 0, minor: 1, patch: 1 }
 * parseVersionParts("1.0")    -> null   (no patch component)
 * parseVersionParts("x.y.z")  -> null
 *
 * This is the shape the one-number scheme ships:  a version string, never a
 * bare integer and never a timestamp.
 */
export function parseVersionParts(version) {
  if (version === null || version === undefined) return null;
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(version).trim());
  if (!match) return null;
  const parts = {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: parseInt(match[3], 10)
  };
  if (!Number.isFinite(parts.major) || !Number.isFinite(parts.minor) || !Number.isFinite(parts.patch)) {
    return null;
  }
  return parts;
}

/**
 * The train a version belongs to:  "0.1.1" -> "0.1", "1.1.2" -> "1.1".
 * Null when the version is not a version string.
 */
export function versionTrain(version) {
  const parts = parseVersionParts(version);
  if (!parts) return null;
  return `${parts.major}.${parts.minor}`;
}

/**
 * The version the next update ships.
 *
 *   recorded  the committed record (project.yml):  the version the last
 *             update shipped, e.g. "0.1.0"
 *   known     the highest patch already used on the SAME train that this path
 *             can see:  0 for the Mac path (it has no App Store Connect
 *             access), the App Store Connect answer for the iOS path.
 *
 * The result is one past the highest patch the train holds, so a number is
 * never reused:  nextVersion({ recorded: "0.1.0" }) -> "0.1.1", and
 * nextVersion({ recorded: "1.1.1", known: 1 }) -> "1.1.2".
 *
 * Throws when the record is not a version string:  a record that cannot be
 * read is a loud failure, never a fallback number.
 */
export function nextVersion({ recorded, known = 0 } = {}) {
  const parts = parseVersionParts(recorded);
  if (!parts) {
    throw new Error(`the committed version record is not a version string: ${JSON.stringify(recorded)}`);
  }
  const seen = Number.isFinite(known) ? Math.trunc(known) : 0;
  const patch = Math.max(parts.patch, seen) + 1;
  return `${parts.major}.${parts.minor}.${patch}`;
}

/**
 * True when a TestFlight train is a "drift train":  a <prefix>.N train that
 * holds a build whose CFBundleVersion is exactly the string "N".
 *
 * Those trains came from the retired 1.0.<commit_count> scheme (1.0.2358
 * holding build 2358) and must not push the next marketing patch forward.
 * App Store versions are never drift -- only trains can be.
 */
export function isDriftTrain(trainVersion, buildVersions, prefix) {
  const patch = parsePatch(trainVersion, prefix);
  if (patch === null) return false;
  const target = String(patch);
  for (const build of buildVersions || []) {
    if (build === null || build === undefined) continue;
    if (String(build) === target) return true;
  }
  return false;
}

/**
 * The highest patch already used on a train.
 *
 * appStoreVersions: ["1.0.235"]  -- the App Store versions, never ignored.
 * trains: [{ version: "1.0.236", builds: ["202610180036"] }]  -- the
 * TestFlight trains; a drift train is ignored.
 *
 * Returns 0 when the train has nothing on it yet.
 */
export function latestMarketingPatch({ prefix, appStoreVersions = [], trains = [] } = {}) {
  let best = 0;
  const consider = (patch) => {
    if (patch !== null && patch !== undefined && Number.isFinite(patch) && patch > best) {
      best = patch;
    }
  };

  for (const version of appStoreVersions || []) {
    const value = typeof version === "string" ? version : version?.versionString;
    consider(parsePatch(value, prefix));
  }

  for (const train of trains || []) {
    if (!train) continue;
    const version = typeof train === "string" ? train : train.version;
    const builds = typeof train === "string" ? [] : train.builds || [];
    if (isDriftTrain(version, builds, prefix)) continue;
    consider(parsePatch(version, prefix));
  }

  return best;
}

/**
 * The next free patch on a train:  one past latestMarketingPatch, skipping
 * every patch a TestFlight train already holds.  Drift trains are ignored for
 * the maximum, but their numbers are still taken:  shipping into a drift train
 * (say 1.0.312 holding build "312") would add a build to it, the train would
 * stay a drift train, and every later ship would compute the same patch and
 * freeze there.  Skipping taken numbers keeps the sequence moving.
 */
export function nextMarketingPatch({ prefix, appStoreVersions = [], trains = [] } = {}) {
  const taken = new Set();
  for (const train of trains || []) {
    if (!train) continue;
    const version = typeof train === "string" ? train : train.version;
    const patch = parsePatch(version, prefix);
    if (patch !== null) taken.add(patch);
  }
  for (const version of appStoreVersions || []) {
    const value = typeof version === "string" ? version : version?.versionString;
    const patch = parsePatch(value, prefix);
    if (patch !== null) taken.add(patch);
  }
  let next = latestMarketingPatch({ prefix, appStoreVersions, trains }) + 1;
  while (taken.has(next)) next += 1;
  return next;
}

/** A plain integer build number, or null when the value is not one. */
function integerBuild(value) {
  if (value === null || value === undefined) return null;
  const text = String(value).trim();
  if (!/^\d+$/.test(text)) return null;
  const parsed = parseInt(text, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

/** The macOS platform key used by the App Store Connect API. */
export const MAC_PLATFORM = "MAC_OS";

/**
 * The build number the next ship has to exceed.
 *
 * trainBuilds: every build already in the target marketing train.  All of
 *   them count, any size:  Apple requires build numbers to increase inside
 *   one version train, so an old 12-digit UTC stamp (202610180036) still
 *   holds the floor up.
 * appBuilds: the app's builds on that platform.  Only the plain integers
 *   below 1000000000 count on iOS, so the retired UTC stamps do not push the
 *   commit count out of the way forever.  On macOS EVERY build counts,
 *   because macOS build numbers must increase across all trains.
 *
 * Non-numeric or dotted build values (e.g. "1.0.5") are ignored.
 *
 * Under the one-number scheme the build number IS the version string, so
 * this floor is no longer what picks the number:  the number comes from
 * nextVersion().  The floor still answers "is the target train empty?", which
 * is the guard that keeps a build number strictly increasing inside its
 * marketing train.
 */
export function buildFloor({ trainBuilds = [], appBuilds = [], platform = "" } = {}) {
  const isMac = String(platform || "").toUpperCase() === MAC_PLATFORM;
  let floor = 0;

  for (const build of trainBuilds || []) {
    const parsed = integerBuild(build);
    if (parsed !== null && parsed > floor) floor = parsed;
  }

  for (const build of appBuilds || []) {
    const parsed = integerBuild(build);
    if (parsed === null) continue;
    if (isMac) {
      if (parsed > floor) floor = parsed;
    } else if (parsed < 1000000000 && parsed > floor) {
      floor = parsed;
    }
  }

  return floor;
}

/**
 * The number the Mac path ships (scripts/install.sh).
 *
 * The Mac path has no App Store Connect access, so the committed record is
 * the whole of what it knows about the train:  the number is one past the
 * record.  Returns { version, build }.
 */
export function planMacUpdate({ recorded, forcedVersion = "", forcedBuild = "" } = {}) {
  return planShip({ recorded, known: 0, recordedUsable: false, forcedVersion, forcedBuild });
}

/**
 * The number the iOS path ships (scripts/ios-fleet/ship-testflight.sh).
 *
 *   known              the highest patch already used on the train (App Store
 *                      Connect's answer)
 *   recordedTrainEmpty true when the recorded version's own train holds no
 *                      build, so it can be shipped as it stands
 *
 * When the recorded version is ahead of everything the train holds and its
 * own train is empty, it is shipped as it stands:  that is how this path
 * picks up the number the Mac path already chose, so one update carries one
 * number on both platforms.  Otherwise the number is one past what the train
 * holds.  Returns { version, build }.
 */
export function planIosUpdate({
  recorded,
  known = 0,
  recordedTrainEmpty = true,
  forcedVersion = "",
  forcedBuild = ""
} = {}) {
  const parts = parseVersionParts(recorded);
  const seen = Number.isFinite(known) ? Math.trunc(known) : 0;
  const usable = Boolean(parts) && parts.patch > seen && recordedTrainEmpty;
  return planShip({ recorded, known, recordedUsable: usable, forcedVersion, forcedBuild });
}

/**
 * The version and the build for one ship.  They are the SAME string.
 *
 *   recorded       the committed record (project.yml):  the version the last
 *                  update shipped, e.g. "0.1.0"
 *   known          the highest patch already used on the train that this path
 *                  can see (0 for the Mac path, App Store Connect's answer
 *                  for the iOS path)
 *   recordedUsable true when the recorded version can be shipped as it
 *                  stands:  it is ahead of everything the train holds and its
 *                  own train holds no build.  That is how the iOS path picks
 *                  up the number the Mac path already chose, so one update
 *                  carries one number on both platforms.
 *   forcedVersion  an exact --version override
 *   forcedBuild    an exact --build override
 *
 * Returns { version, build } as strings.  With no overrides the build number
 * equals the version string, so App Store Connect shows "0.1.1 (0.1.1)".
 */
export function planShip({
  recorded,
  known = 0,
  recordedUsable = false,
  forcedVersion = "",
  forcedBuild = ""
} = {}) {
  let version;
  if (forcedVersion) {
    version = String(forcedVersion).trim();
  } else if (recordedUsable) {
    const parts = parseVersionParts(recorded);
    if (!parts) {
      throw new Error(`the committed version record is not a version string: ${JSON.stringify(recorded)}`);
    }
    version = `${parts.major}.${parts.minor}.${parts.patch}`;
  } else {
    version = nextVersion({ recorded, known });
  }

  const parts = parseVersionParts(version);
  if (!parts) {
    throw new Error(`the version to ship is not a version string: ${JSON.stringify(version)}`);
  }

  let build;
  if (forcedBuild !== "" && forcedBuild !== null && forcedBuild !== undefined) {
    // An explicit --build is honoured exactly.  It is the one way to get two
    // different numbers again, so the ship script logs it loudly.
    build = String(forcedBuild).trim();
  } else {
    // The one-number rule:  the build number IS the version.
    build = version;
  }

  return { version, build };
}
