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
//   - docker build cache (Docker reports the reclaimed bytes itself)
//   - dangling Docker images only — never all-unused, never volumes
//   - superseded local backups: exactly the newest complete dump per app
//     is kept; B2 holds the off-host replica (fleet backup rule)
//   - the systemd journal, vacuumed down to a target with a hard floor
//   - stale temp files: old, closed, regular files only
//
// Anything outside that list is never touched: no live app data, no Docker
// volumes, no running containers, no lane or working trees, and never the
// sole local backup copy of anything.
package autoclean

import (
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
	CategoryBuildCache = "docker-build-cache"
	CategoryImages     = "docker-dangling-images"
	CategoryBackups    = "backups-superseded"
	CategoryJournal    = "journal"
	CategoryStaleTmp   = "stale-tmp"
)

// AllCategories is every category id, in the order runs execute them.
// Build cache goes first because it is historically the largest and the
// cheapest win on the Coolify host (~20 GB on 2026-11-07).
func AllCategories() []string {
	return []string{
		CategoryBuildCache,
		CategoryImages,
		CategoryBackups,
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
	// Categories toggles each category; a missing key means enabled.
	Categories map[string]bool
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
// most one applied run per 6 hours.
func DefaultConfig() Config {
	return Config{
		Enabled:             false,
		RootPath:            "/",
		UsedPercentTrigger:  80,
		MinFreeBytes:        30 << 30,
		CheckInterval:       15 * time.Minute,
		Cooldown:            6 * time.Hour,
		Categories:          map[string]bool{},
		BackupDirs:          []string{"/backups"},
		BackupInFlightGrace: 2 * time.Hour,
		JournalTargetBytes:  500 << 20,
		JournalFloorBytes:   200 << 20,
		JournalDir:          "/var/log/journal",
		TmpDirs:             []string{"/tmp", "/var/tmp"},
		TmpMinAge:           7 * 24 * time.Hour,
		Actor:               "autoclean",
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
	total := st.Blocks * uint64(st.Bsize)
	free := st.Bavail * uint64(st.Bsize)
	used := total - st.Bfree*uint64(st.Bsize)
	u := DiskUsage{Path: path, TotalBytes: total, UsedBytes: used, FreeBytes: free}
	if total > 0 {
		u.UsedPercent = float64(used) / float64(total) * 100
	}
	return u, nil
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
