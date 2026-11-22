// Package autoclean is the automatic root-disk cleanup mode for hh-agent.
//
// Jay directed this on 2026-11-07 ("help HogHunter do so automatically in
// the future") after the Coolify host's root disk hit 92% used for the
// second time in a week.  It supersedes the SPEC.md §2 non-goal of "no
// automatic pruning" for disk space only: process and container killing
// stay manual, forever.
//
// The mode is threshold-triggered, not calendar-driven: a checker wakes on
// an interval, and a cleanup run happens only when the root filesystem is
// at or over UsedPercentTrigger used, or under MinFreeBytes free.  Every
// category is a safe, regenerable, or superseded-copy category:
//
//   - docker build cache, pruned the way `docker builder prune -af`
//     prunes it: all cache not in use by a running build, not just the
//     dangling records (Docker reports the reclaimed bytes itself)
//   - dangling Docker images only — never all-unused, never volumes
//   - unused deploy images beyond the rollback window: per image
//     repository, the newest generations are kept (current + previous
//     by default); an image any container references is never touched
//   - superseded local backups: exactly the newest complete dump per app
//     is kept; B2 holds the off-host replica (fleet backup rule)
//   - agent tool caches under the seat's home (npm, deno, pnpm, node):
//     pure caches, regenerated on demand
//   - the systemd journal, vacuumed down to a target with a hard floor
//   - stale temp files: old, closed, regular files only
//
// Two report-only watchers ride along with every run and never delete
// anything: a large-new-file watch inside Docker volumes (a multi-GB
// file appearing in a live app volume is surfaced for a human decision,
// never removed), and a backups-retention total, so the structural
// growth of the local backup copies is visible in every run's output.
//
// Above the emergency line (90% used or under 16 GiB free by default)
// the cooldown no longer applies: a disk in free fall is pruned on
// every check until it drops back under the line.  The 2026-11-21
// incident is the reason — checks at 87–93% used were skipped for the
// 6-hour cooldown while the disk lost ~14 GB in 90 minutes.
//
// Anything outside that list is never touched: no live app data, no Docker
// volumes, no running containers, no lane or working trees, and never the
// sole local backup copy of anything.
package autoclean

import (
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Category ids.  These strings are written to the cleanup history and the
// audit log, so they are part of the on-disk schema — do not rename them.
const (
	CategoryBuildCache   = "docker-build-cache"
	CategoryImages       = "docker-dangling-images"
	CategoryUnusedImages = "docker-unused-images"
	CategoryBackups      = "backups-superseded"
	CategoryAgentCaches  = "agent-caches"
	CategoryJournal      = "journal"
	CategoryStaleTmp     = "stale-tmp"
)

// AllCategories is every category id, in the order runs execute them.
// Build cache goes first because it is historically the largest and the
// cheapest win on the Coolify host (~20 GB on 2026-11-07).
func AllCategories() []string {
	return []string{
		CategoryBuildCache,
		CategoryImages,
		CategoryUnusedImages,
		CategoryBackups,
		CategoryAgentCaches,
		CategoryJournal,
		CategoryStaleTmp,
	}
}

// Config controls one autoclean setup.  The zero value is disabled and
// safe: nothing runs until Enabled is set, matching the repo convention
// that destructive capabilities are opt-in.
type Config struct {
	// Enabled turns the automatic mode on.  Off by default.
	Enabled bool
	// RootPath is the filesystem watched and measured ("/" on a server).
	RootPath string
	// UsedPercentTrigger: run when root usage is at or over this percent.
	UsedPercentTrigger float64
	// MinFreeBytes: run when root free space drops under this many bytes,
	// even if the percent trigger is not met.
	MinFreeBytes uint64
	// CheckInterval is how often the daemon loop measures the disk.
	CheckInterval time.Duration
	// Cooldown is the minimum gap between two applied (non-dry-run) runs,
	// so a disk that stays over the trigger is not pruned every check.
	Cooldown time.Duration
	// EmergencyUsedPercent and EmergencyMinFreeBytes are the emergency
	// line: at or over the percent, or under the free floor, a triggered
	// run ignores the cooldown.  The emergency tier never widens WHAT a
	// run may delete — the same safe categories — only WHEN it may run.
	EmergencyUsedPercent  float64
	EmergencyMinFreeBytes uint64
	// Categories toggles each category; a missing key means enabled.
	Categories map[string]bool
	// ImageKeepPerRepo is the rollback window for the unused-images
	// category: per image repository, this many newest generations are
	// always kept (2 = current + previous deploy).
	ImageKeepPerRepo int
	// ImageOrphanGrace: a repository no container references must stay
	// unreferenced for at least this long (tracked across runs in a
	// state file) before its beyond-newest generations become
	// candidates.  The grace is what makes a mid-deploy window — old
	// container removed, new one not yet created — harmless: orphanhood
	// has to persist, not just be observed once.
	ImageOrphanGrace time.Duration
	// AgentHome is the seat user's home; the default agent-cache dirs
	// derive from it.  AgentCacheDirs overrides the derived list.
	AgentHome      string
	AgentCacheDirs []string
	// AgentCacheMinAge: cache files touched more recently than this are
	// never deleted, so a purge cannot pull files out from under an
	// install that is running right now.
	AgentCacheMinAge time.Duration
	// DockerVolumesDir is the Docker volumes root the large-new-file
	// watch scans (report-only; the watch never deletes).
	DockerVolumesDir string
	// VolumeWatchThresholdBytes: a volume file larger than this counts
	// as large for the watch.
	VolumeWatchThresholdBytes uint64
	// VolumeWatchWindow: a large volume file counts as new when its
	// mtime is inside this window before the run.
	VolumeWatchWindow time.Duration
	// VolumeWatchMaxDepth bounds the watch's walk under each volume's
	// _data directory, keeping the scan cheap on a busy host.
	VolumeWatchMaxDepth int
	// BackupDirs are the local backup roots scanned for superseded dumps.
	BackupDirs []string
	// BackupInFlightGrace: a dump with no completion marker counts as
	// complete only when it is older than this, so a dump being written
	// right now is never mistaken for a finished one.
	BackupInFlightGrace time.Duration
	// JournalTargetBytes is the size the journal is vacuumed down to.
	JournalTargetBytes uint64
	// JournalFloorBytes is the hard floor: vacuum never goes below it,
	// so recent logs always survive an automatic run.
	JournalFloorBytes uint64
	// JournalDir is measured for before/after sizes (usually
	// /var/log/journal).
	JournalDir string
	// TmpDirs are scanned for stale files.
	TmpDirs []string
	// TmpMinAge: temp files younger than this are never touched.
	TmpMinAge time.Duration
	// Actor is written to the audit log and history ("autoclean" for the
	// daemon loop, a device id or "local" for API/CLI-triggered runs).
	Actor string
}

// DefaultConfig returns the shipped defaults, tuned for the Coolify host:
// trigger at 80% used or under 30 GiB free, check every 15 minutes, at
// most one applied run per 6 hours — except above the emergency line
// (90% used or under 16 GiB free), where the cooldown does not apply.
func DefaultConfig() Config {
	return Config{
		Enabled:                   false,
		RootPath:                  "/",
		UsedPercentTrigger:        80,
		MinFreeBytes:              30 << 30,
		CheckInterval:             15 * time.Minute,
		Cooldown:                  6 * time.Hour,
		EmergencyUsedPercent:      90,
		EmergencyMinFreeBytes:     16 << 30,
		Categories:                map[string]bool{},
		ImageKeepPerRepo:          2,
		ImageOrphanGrace:          48 * time.Hour,
		AgentHome:                 "/home/jay",
		AgentCacheMinAge:          time.Hour,
		BackupDirs:                []string{"/backups"},
		BackupInFlightGrace:       2 * time.Hour,
		JournalTargetBytes:        200 << 20,
		JournalFloorBytes:         100 << 20,
		JournalDir:                "/var/log/journal",
		TmpDirs:                   []string{"/tmp", "/var/tmp"},
		TmpMinAge:                 7 * 24 * time.Hour,
		DockerVolumesDir:          "/var/lib/docker/volumes",
		VolumeWatchThresholdBytes: 5 << 30,
		VolumeWatchWindow:         24 * time.Hour,
		VolumeWatchMaxDepth:       3,
		Actor:                     "autoclean",
	}
}

// AgentCacheDirList returns the effective agent-cache directories: the
// explicit override when set, else the known regenerable caches under
// the seat's home — the exact set the 2026-11-21 manual reclaim cleared
// (npm's cache and npx store, and the deno, pnpm, and node caches).
func (c Config) AgentCacheDirList() []string {
	if len(c.AgentCacheDirs) > 0 {
		return c.AgentCacheDirs
	}
	home := c.AgentHome
	if home == "" {
		return nil
	}
	return []string{
		filepath.Join(home, ".npm", "_cacache"),
		filepath.Join(home, ".npm", "_npx"),
		filepath.Join(home, ".cache", "deno"),
		filepath.Join(home, ".cache", "pnpm"),
		filepath.Join(home, ".cache", "node"),
	}
}

// CategoryEnabled reports whether a category may run under this config.
func (c Config) CategoryEnabled(id string) bool {
	if c.Categories == nil {
		return true
	}
	enabled, known := c.Categories[id]
	return !known || enabled
}

// ConfigFromEnv builds a config from the defaults plus HH_AGENT_AUTOCLEAN_*
// environment overrides.  A malformed override is ignored rather than
// fatal: a typo must never stop the daemon, and the defaults are safe.
func ConfigFromEnv() Config {
	c := DefaultConfig()
	if v := os.Getenv("HH_AGENT_AUTOCLEAN"); v == "1" || strings.EqualFold(v, "true") {
		c.Enabled = true
	}
	if v := os.Getenv("HH_AGENT_AUTOCLEAN_ROOT"); v != "" {
		c.RootPath = v
	}
	if v, err := strconv.ParseFloat(os.Getenv("HH_AGENT_AUTOCLEAN_USED_PCT"), 64); err == nil && v > 0 && v < 100 {
		c.UsedPercentTrigger = v
	}
	if v, err := strconv.ParseUint(os.Getenv("HH_AGENT_AUTOCLEAN_MIN_FREE_GB"), 10, 64); err == nil && v > 0 {
		c.MinFreeBytes = v << 30
	}
	if v, err := strconv.Atoi(os.Getenv("HH_AGENT_AUTOCLEAN_CHECK_MINUTES")); err == nil && v > 0 {
		c.CheckInterval = time.Duration(v) * time.Minute
	}
	if v, err := strconv.Atoi(os.Getenv("HH_AGENT_AUTOCLEAN_COOLDOWN_HOURS")); err == nil && v >= 0 {
		c.Cooldown = time.Duration(v) * time.Hour
	}
	if v, err := strconv.ParseFloat(os.Getenv("HH_AGENT_AUTOCLEAN_EMERGENCY_PCT"), 64); err == nil && v > 0 && v < 100 {
		c.EmergencyUsedPercent = v
	}
	if v, err := strconv.ParseUint(os.Getenv("HH_AGENT_AUTOCLEAN_EMERGENCY_MIN_FREE_GB"), 10, 64); err == nil && v > 0 {
		c.EmergencyMinFreeBytes = v << 30
	}
	if v, err := strconv.Atoi(os.Getenv("HH_AGENT_AUTOCLEAN_IMAGE_KEEP")); err == nil && v >= 1 {
		c.ImageKeepPerRepo = v
	}
	if v := os.Getenv("HH_AGENT_AUTOCLEAN_AGENT_HOME"); v != "" {
		c.AgentHome = v
	}
	if v := os.Getenv("HH_AGENT_AUTOCLEAN_AGENT_CACHE_DIRS"); v != "" {
		var dirs []string
		for _, d := range strings.Split(v, ",") {
			if d = strings.TrimSpace(d); d != "" {
				dirs = append(dirs, d)
			}
		}
		if len(dirs) > 0 {
			c.AgentCacheDirs = dirs
		}
	}
	if v, err := strconv.ParseUint(os.Getenv("HH_AGENT_AUTOCLEAN_VOLUME_WATCH_GB"), 10, 64); err == nil && v > 0 {
		c.VolumeWatchThresholdBytes = v << 30
	}
	if v := os.Getenv("HH_AGENT_AUTOCLEAN_BACKUP_DIRS"); v != "" {
		var dirs []string
		for _, d := range strings.Split(v, ",") {
			if d = strings.TrimSpace(d); d != "" {
				dirs = append(dirs, d)
			}
		}
		if len(dirs) > 0 {
			c.BackupDirs = dirs
		}
	}
	if v, err := strconv.Atoi(os.Getenv("HH_AGENT_AUTOCLEAN_JOURNAL_MAX_MB")); err == nil && v > 0 {
		c.JournalTargetBytes = uint64(v) << 20
	}
	if v, err := strconv.Atoi(os.Getenv("HH_AGENT_AUTOCLEAN_TMP_DAYS")); err == nil && v > 0 {
		c.TmpMinAge = time.Duration(v) * 24 * time.Hour
	}
	if v := os.Getenv("HH_AGENT_AUTOCLEAN_DISABLE"); v != "" {
		for _, id := range strings.Split(v, ",") {
			c.Categories[strings.TrimSpace(id)] = false
		}
	}
	return c
}

// DiskUsage is one filesystem measurement.
type DiskUsage struct {
	Path        string  `json:"path"`
	TotalBytes  uint64  `json:"total_bytes"`
	UsedBytes   uint64  `json:"used_bytes"`
	FreeBytes   uint64  `json:"free_bytes"`
	UsedPercent float64 `json:"used_percent"`
}

// StatDisk measures a filesystem with statfs.
func StatDisk(path string) (DiskUsage, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return DiskUsage{}, err
	}
	return usageFromStatfs(path, st.Blocks, st.Bfree, st.Bavail, uint64(st.Bsize)), nil
}

// usageFromStatfs converts raw statfs block counts into a DiskUsage, on
// exactly the basis `df` uses for its Use% column.  Used is blocks minus
// bfree (every block that is not free, reserved blocks included), avail
// is bavail (the blocks an unprivileged process may still allocate), and
// the percentage is ceil(100 * used / (used + avail)).
//
// The denominator is used + avail, NOT the total block count: the blocks
// a filesystem reserves for root (bfree - bavail, typically 5% on ext4)
// are in neither term, so dividing by the total understates usage
// whenever a reserve exists.  That was the live defect on the Coolify
// host: this code read about 77.3% (used / total) where `df` read 81%
// (used / (used + avail)), so the 80% autoclean trigger never fired on
// the percent rule.  `df` also rounds its percentage up, and the ceil
// here keeps the trigger in step with the number an operator sees.
func usageFromStatfs(path string, blocks, bfree, bavail, bsize uint64) DiskUsage {
	total := blocks * bsize
	free := bavail * bsize
	// Used is blocks - bfree, clamped at zero: a free count at or over
	// the total (the empty-filesystem case, or a count statfs should
	// never report) means nothing is used, and must not underflow.
	var usedBlocks uint64
	if bfree < blocks {
		usedBlocks = blocks - bfree
	}
	used := usedBlocks * bsize
	u := DiskUsage{Path: path, TotalBytes: total, UsedBytes: used, FreeBytes: free}
	u.UsedPercent = dfUsedPercent(usedBlocks, bavail)
	return u
}

// dfUsedPercent is the `df` Use% calculation: ceil(100 * used /
// (used + avail)), in blocks.  A denominator of zero (an empty or
// degenerate filesystem) reports 0, never NaN or +Inf.
func dfUsedPercent(usedBlocks, availBlocks uint64) float64 {
	denominator := usedBlocks + availBlocks
	if denominator == 0 {
		return 0
	}
	return math.Ceil(float64(usedBlocks) * 100 / float64(denominator))
}

// ShouldRun is the trigger decision, kept pure so tests can pin it: a run
// happens only when the mode is enabled AND (usage is at or over the
// percent trigger OR free space is under the floor).  Exactly at the
// threshold counts as triggered — 80% is the fleet guardrail line.
func (c Config) ShouldRun(u DiskUsage) bool {
	if !c.Enabled {
		return false
	}
	if u.TotalBytes == 0 {
		return false
	}
	return u.UsedPercent >= c.UsedPercentTrigger || u.FreeBytes < c.MinFreeBytes
}

// Emergency is the emergency-tier decision, kept pure like ShouldRun:
// the disk is in free fall when usage is at or over the emergency
// percent OR free space is under the emergency floor.  Exactly at the
// line counts, same as the trigger.  Emergency does not depend on
// Enabled — it classifies a measurement; the runner decides what the
// classification means (cooldown bypass for a run that already
// triggered).
func (c Config) Emergency(u DiskUsage) bool {
	if u.TotalBytes == 0 {
		return false
	}
	return u.UsedPercent >= c.EmergencyUsedPercent || u.FreeBytes < c.EmergencyMinFreeBytes
}

// HistoryPath is the append-only cleanup history file.  The name matches
// the Mac app's store (cleanup-history.jsonl, CleanupHistoryStore.swift)
// so both platforms' histories share one schema and one filename.
func HistoryPath() string {
	return filepath.Join(dataDir(), "cleanup-history.jsonl")
}

func dataDir() string {
	dir := os.Getenv("HH_AGENT_DATA_DIR")
	if dir == "" {
		dir = os.Getenv("HH_AGENT_STATE_DIR")
	}
	if dir == "" {
		dir = "/var/lib/hh-agent"
	}
	_ = os.MkdirAll(dir, 0700)
	return dir
}
