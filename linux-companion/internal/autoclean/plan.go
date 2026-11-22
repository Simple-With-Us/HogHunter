package autoclean

import (
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// This file holds the pure planning half of autoclean: given an inventory,
// decide exactly what may be deleted.  Planners never touch the disk, so
// the safety rules are unit-testable without a filesystem, and the runner
// can produce a dry-run plan with the same code an applied run executes.

// --- Backups: keep exactly one newest complete dump per app -------------

// Sidecar is a small file that belongs to a dump (checksum, marker).
type Sidecar struct {
	Path string
	Size int64
}

// BackupDump is one backup file in the inventory.
type BackupDump struct {
	// App groups dumps: dumps of different apps never compete, so one
	// app's rotation can never evict another app's only copy.
	App     string
	Path    string
	Size    int64
	ModTime time.Time
	// Complete means finished and verified enough to count as the kept
	// copy: it carries a completion sidecar, or it is older than the
	// in-flight grace period.  The walker decides; the planner trusts it.
	Complete bool
	Sidecars []Sidecar
}

// PlanBackupCleanup returns the dump paths (with their sidecars) that may
// be deleted: every complete dump that is not the newest complete dump of
// its app.  The safety invariants, all pinned by tests:
//
//   - the newest complete dump per app is always kept, with its sidecars
//   - a group with no complete dump loses nothing at all
//   - an incomplete (in-flight or unverified) dump is never deleted
//   - unknown or sole copies are never deleted: with one complete dump
//     in a group, the plan for that group is empty
func PlanBackupCleanup(dumps []BackupDump) (deletePaths []string) {
	byApp := map[string][]BackupDump{}
	for _, d := range dumps {
		byApp[d.App] = append(byApp[d.App], d)
	}
	for _, group := range byApp {
		var complete []BackupDump
		for _, d := range group {
			if d.Complete {
				complete = append(complete, d)
			}
		}
		if len(complete) <= 1 {
			continue
		}
		sort.Slice(complete, func(i, j int) bool {
			if complete[i].ModTime.Equal(complete[j].ModTime) {
				return complete[i].Path > complete[j].Path
			}
			return complete[i].ModTime.After(complete[j].ModTime)
		})
		for _, d := range complete[1:] {
			deletePaths = append(deletePaths, d.Path)
			for _, s := range d.Sidecars {
				deletePaths = append(deletePaths, s.Path)
			}
		}
	}
	sort.Strings(deletePaths)
	return deletePaths
}

// dumpExtensions are file suffixes that count as backup dumps.  Anything
// else in a backup directory (notes, configs, marker files) is not a dump
// and is never inventoried, so it can never be planned for deletion.
var dumpExtensions = []string{".db", ".sqlite", ".sql", ".dump", ".tar", ".gz", ".tgz", ".zip", ".zst"}

// sidecarSuffixes mark a file as belonging to the dump of the same stem.
var sidecarSuffixes = []string{".sha256", ".md5", ".complete", ".ok"}

func isDumpName(name string) bool {
	lower := strings.ToLower(name)
	for _, suf := range sidecarSuffixes {
		if strings.HasSuffix(lower, suf) {
			return false // a sidecar, not a dump
		}
	}
	for _, ext := range dumpExtensions {
		if strings.HasSuffix(lower, ext) {
			// ".sql.gz" style double suffixes still end in a dump suffix.
			return true
		}
	}
	return false
}

func isSidecarOf(name, dumpName string) (suffix string, ok bool) {
	if !strings.HasPrefix(name, dumpName) {
		return "", false
	}
	rest := strings.ToLower(name[len(dumpName):])
	for _, suf := range sidecarSuffixes {
		if rest == suf {
			return suf, true
		}
	}
	return "", false
}

// isIncompleteName reports names that mark a dump still being written.
func isIncompleteName(name string) bool {
	lower := strings.ToLower(name)
	for _, suf := range []string{".partial", ".tmp", ".inprogress", ".in-progress", ".part"} {
		if strings.HasSuffix(lower, suf) {
			return true
		}
	}
	return false
}

// ValidateBackupRoot refuses backup roots where a planning bug could do
// real damage: the filesystem root itself, Docker's data root (live app
// data), and anything that looks like a fleet lane or working tree.
func ValidateBackupRoot(path string) (ok bool, reason string) {
	clean := filepath.Clean(path)
	if !filepath.IsAbs(clean) {
		return false, "refusing backup root " + clean + ": path must be absolute"
	}
	lower := strings.ToLower(clean)
	switch clean {
	case "/", "/var", "/var/lib", "/var/lib/docker", "/root", "/home":
		return false, "refusing backup root " + clean + ": too broad"
	}
	for _, frag := range []string{"/lanes/", "/apps/lanes", "/.git", "/var/lib/docker/"} {
		if strings.Contains(lower, frag) {
			return false, "refusing backup root " + clean + ": looks like live data or a working tree"
		}
	}
	// System and live-data subtrees are never backup roots, however the
	// operator spells them.  An exact-path denylist alone would let
	// /var/lib/<app>/data or /usr/share/doc through, and the keep-1
	// planner would then delete live files there.
	for _, prefix := range []string{
		"/bin", "/boot", "/dev", "/etc", "/lib", "/lib32", "/lib64", "/libx32",
		"/opt", "/proc", "/run", "/sbin", "/srv", "/sys", "/usr",
		"/var/lib", "/var/www", "/root", "/home",
	} {
		if lower == prefix || strings.HasPrefix(lower, prefix+"/") {
			return false, "refusing backup root " + clean + ": system or live-data path"
		}
	}
	// A backup root must look like one: some path component names it a
	// backup location (/backups, /data/backups, /mnt/fleet-extra/backups).
	for _, comp := range strings.Split(strings.Trim(clean, "/"), "/") {
		if strings.Contains(strings.ToLower(comp), "backup") {
			return true, ""
		}
	}
	return false, "refusing backup root " + clean + ": does not look like a dedicated backup location"
}

// --- Stale temp files -----------------------------------------------------

// TmpEntry is one inventoried temp file.
type TmpEntry struct {
	Path    string
	Size    int64
	ModTime time.Time
	IsDir   bool
	Symlink bool
	// Regular is true only for a plain file.  Anything else — a Unix
	// socket, a FIFO, a device node — is never selected: a daemon's
	// stale-looking socket in /tmp is still its rendezvous point, and a
	// socket's /proc fd does not resolve to its path, so the Open check
	// below cannot protect it.
	Regular bool
	// Open is true when some process holds the file open (checked via
	// /proc/*/fd by the walker).  An open temp file is in use by
	// definition, however old it looks.
	Open bool
}

// SelectStaleTmp returns paths that may be deleted: regular files (never
// directories, never symlinks) at least minAge old and not open anywhere.
// A directory's contents are judged file by file; the directory itself is
// left for the filesystem to keep or the owner to remove.
func SelectStaleTmp(entries []TmpEntry, now time.Time, minAge time.Duration) []string {
	var out []string
	for _, e := range entries {
		if e.IsDir || e.Symlink || e.Open || !e.Regular {
			continue
		}
		if now.Sub(e.ModTime) < minAge {
			continue
		}
		out = append(out, e.Path)
	}
	sort.Strings(out)
	return out
}

// --- Unused deploy images: keep the rollback window per repository ------

// DeployImage is one tagged image in the retention planner's inventory.
// Repo is the repository part of its single tag ("" for untagged or
// digest-only images, which this planner never touches — dangling
// images belong to the dangling-images category).
type DeployImage struct {
	ID      string
	Repo    string
	Tag     string
	Created time.Time
	Size    int64
}

// ImageRepoTag splits a tag reference into repository and tag.  The tag
// separator is the last colon AFTER the last slash, so a registry port
// (localhost:5000/app:v1) is not mistaken for a tag.
func ImageRepoTag(ref string) (repo, tag string, ok bool) {
	if ref == "" || strings.Contains(ref, "@") {
		return "", "", false // digest reference: no tag to group by
	}
	slash := strings.LastIndex(ref, "/")
	colon := strings.LastIndex(ref, ":")
	if colon <= slash {
		return "", "", false
	}
	return ref[:colon], ref[colon+1:], true
}

// PlanUnusedImages decides which deploy images may be deleted, and the
// next orphan-since state to persist.  Pure: the runner supplies the
// inventory, the set of image IDs any container references, and the
// orphan state carried from earlier runs.
//
// Safety invariants, all pinned by tests:
//
//   - an image referenced by ANY container (running or stopped) is
//     never a candidate — the runner also deletes without force, so the
//     daemon itself refuses if an inventory race slips one through
//   - per repository, the newest keep generations always survive
//     (the rollback window: current + previous at the default keep=2)
//   - a repository no container references (an orphan group — a removed
//     app, a helper image like coolify-helper) only loses generations
//     beyond its newest ONE, and only after the group has been observed
//     unreferenced continuously for orphanGrace: orphanhood is a state
//     that must persist across runs, never a single observation, so the
//     window inside a deploy (old container removed, new one not yet
//     created) can never trigger it
//   - untagged images and images tagged into more than one repository
//     are never candidates: their ownership is ambiguous by definition
func PlanUnusedImages(images []DeployImage, usedIDs map[string]bool, keep int, orphanSince map[string]time.Time, now time.Time, orphanGrace time.Duration) (delete []DeployImage, nextOrphan map[string]time.Time) {
	if keep < 1 {
		keep = 1
	}
	byRepo := map[string][]DeployImage{}
	for _, im := range images {
		if im.Repo == "" {
			continue
		}
		byRepo[im.Repo] = append(byRepo[im.Repo], im)
	}
	nextOrphan = map[string]time.Time{}
	repos := make([]string, 0, len(byRepo))
	for repo := range byRepo {
		repos = append(repos, repo)
	}
	sort.Strings(repos)
	for _, repo := range repos {
		group := byRepo[repo]
		sort.Slice(group, func(i, j int) bool {
			if group[i].Created.Equal(group[j].Created) {
				return group[i].ID < group[j].ID
			}
			return group[i].Created.After(group[j].Created)
		})
		live := false
		for _, im := range group {
			if usedIDs[im.ID] {
				live = true
				break
			}
		}
		orphanExpired := false
		if !live {
			since, seen := orphanSince[repo]
			if !seen {
				since = now
			}
			nextOrphan[repo] = since
			orphanExpired = now.Sub(since) >= orphanGrace
		}
		for i, im := range group {
			if usedIDs[im.ID] {
				continue
			}
			switch {
			case live && i >= keep:
				// Live group, beyond the rollback window: the window
				// is the contract, and generations past it go on
				// sight.
				delete = append(delete, im)
			case !live && orphanExpired && i >= 1:
				// Orphan group past its grace: everything but the
				// newest generation goes.  An orphan group inside its
				// grace loses NOTHING at any index — orphanhood must
				// persist across runs, so the transient container-less
				// window inside a deploy can never cost a generation.
				delete = append(delete, im)
			}
		}
	}
	return delete, nextOrphan
}

// --- Agent caches ---------------------------------------------------------

// ValidateAgentCacheDir refuses cache roots where a planning bug could
// do real damage: anything that is not plainly a tool cache directory
// under a user home.  The purge deletes file contents, so the bar is
// the same as for backup roots — the path must look like exactly what
// it claims to be.
func ValidateAgentCacheDir(path string) (ok bool, reason string) {
	clean := filepath.Clean(path)
	if !filepath.IsAbs(clean) {
		return false, "refusing agent cache dir " + clean + ": path must be absolute"
	}
	lower := strings.ToLower(clean)
	for _, prefix := range []string{
		"/bin", "/boot", "/dev", "/etc", "/lib", "/lib32", "/lib64", "/libx32",
		"/proc", "/run", "/sbin", "/sys", "/usr", "/var",
	} {
		if lower == prefix || strings.HasPrefix(lower, prefix+"/") {
			return false, "refusing agent cache dir " + clean + ": system path"
		}
	}
	for _, frag := range []string{"/lanes/", "/.git", "/var/lib/docker"} {
		if strings.Contains(lower, frag) {
			return false, "refusing agent cache dir " + clean + ": looks like live data or a working tree"
		}
	}
	// A home root itself, or any shallow path, is never a cache dir.
	parts := strings.Split(strings.Trim(clean, "/"), "/")
	if len(parts) < 3 {
		return false, "refusing agent cache dir " + clean + ": too shallow to be a cache directory"
	}
	// The path must be anchored on a per-tool cache shape: npm's named
	// stores (<.../.npm/_cacache or _npx), or ONE tool's directory
	// directly under a .cache (<.../.cache/<tool>) — in each case the
	// named directory itself or anything beneath it.  A bare .cache
	// root is refused: it is every tool's cache tree at once, not one
	// tool's regenerable store, and purging it would reach far beyond
	// the categories this validator exists to bound.
	for i := 0; i+1 < len(parts); i++ {
		if parts[i] == ".npm" && (parts[i+1] == "_cacache" || parts[i+1] == "_npx") {
			return true, ""
		}
		if parts[i] == ".cache" && parts[i+1] != "" {
			return true, ""
		}
	}
	return false, "refusing agent cache dir " + clean + ": does not look like a tool cache directory"
}

// SelectStaleCache picks cache files that may be deleted, under the
// same rules as SelectStaleTmp (regular files only, never symlinks,
// never open files, at least minAge old).  It is a separate entry point
// because the two categories' age semantics differ — temp staleness is
// a week; a cache file only has to be older than any install that could
// be reading it right now — and a future rule change for one must not
// silently change the other.
func SelectStaleCache(entries []TmpEntry, now time.Time, minAge time.Duration) []string {
	return SelectStaleTmp(entries, now, minAge)
}

// --- Large-new-file watch inside Docker volumes (report-only) ------------

// VolumeFileEntry is one file found by the volume watch's walk.
type VolumeFileEntry struct {
	Volume  string
	Path    string
	Size    int64
	ModTime time.Time
	Regular bool
	Symlink bool
}

// VolumeFinding is one large, new file inside a Docker volume.  A
// finding is a report, never a deletion plan: the file may be a live
// database's repair snapshot whose disposition belongs to its owner.
type VolumeFinding struct {
	Volume string `json:"volume"`
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	// AgeSeconds is how old the file was when the run observed it.
	AgeSeconds int64 `json:"age_seconds"`
}

// FindLargeNewFiles filters the watch inventory to findings: regular
// files (never symlinks) larger than thresholdBytes whose mtime is
// inside the window before now.  A future mtime (clock skew on the
// writer) counts as new.  Findings sort largest first and are capped,
// so one runaway volume cannot flood the report.
func FindLargeNewFiles(entries []VolumeFileEntry, thresholdBytes uint64, window time.Duration, now time.Time, maxFindings int) []VolumeFinding {
	var out []VolumeFinding
	for _, e := range entries {
		if !e.Regular || e.Symlink {
			continue
		}
		if e.Size < 0 || uint64(e.Size) <= thresholdBytes {
			continue
		}
		age := now.Sub(e.ModTime)
		if age > window {
			continue
		}
		if age < 0 {
			// A future mtime (clock skew on the writer) counts as
			// new, but its recorded age is 0, never negative — the
			// value persists into history JSON and CLI output.
			age = 0
		}
		out = append(out, VolumeFinding{
			Volume:     e.Volume,
			Path:       e.Path,
			Size:       e.Size,
			AgeSeconds: int64(age.Seconds()),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Size != out[j].Size {
			return out[i].Size > out[j].Size
		}
		return out[i].Path < out[j].Path
	})
	if maxFindings > 0 && len(out) > maxFindings {
		out = out[:maxFindings]
	}
	return out
}

// --- Journal vacuum -------------------------------------------------------

// PlanJournalVacuum decides the vacuum target.  It returns ok=false when
// the journal is already at or under target (nothing to do).  The target
// is clamped up to the floor: a run may shrink the journal to the
// configured target, but never below the retention floor, even if the
// configured target is set lower by mistake.
func PlanJournalVacuum(currentBytes, targetBytes, floorBytes uint64) (vacuumTo uint64, ok bool) {
	if currentBytes <= targetBytes {
		return 0, false
	}
	vacuumTo = targetBytes
	if vacuumTo < floorBytes {
		vacuumTo = floorBytes
	}
	if vacuumTo >= currentBytes {
		return 0, false
	}
	return vacuumTo, true
}
