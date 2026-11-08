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
	switch clean {
	case "/", "/var", "/var/lib", "/var/lib/docker", "/root", "/home":
		return false, "refusing backup root " + clean + ": too broad"
	}
	lower := strings.ToLower(clean)
	for _, frag := range []string{"/lanes/", "/apps/lanes", "/.git", "/var/lib/docker/"} {
		if strings.Contains(lower, frag) {
			return false, "refusing backup root " + clean + ": looks like live data or a working tree"
		}
	}
	return true, ""
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
