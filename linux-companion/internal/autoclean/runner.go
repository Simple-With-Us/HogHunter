package autoclean

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/audit"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/docker"
)

// Deps are the runner's outside world, behind functions so tests can
// substitute fakes and never touch a real disk, Docker daemon, or journal.
type Deps struct {
	// Stat measures a filesystem (default StatDisk).
	Stat func(path string) (DiskUsage, error)
	// Prune runs one Docker prune target (default: the Docker socket
	// client).  all is always false from autoclean: dangling-only.
	Prune func(target string, all bool) (docker.PruneResult, error)
	// Vacuum runs journalctl --vacuum-size=<bytes> (default: exec).
	Vacuum func(vacuumToBytes uint64) error
	// DirSize measures a directory tree in bytes (default: walk).
	DirSize func(path string) (uint64, error)
	// Remove deletes one file (default os.Remove).
	Remove func(path string) error
	// OpenFiles returns the set of paths held open by any process
	// (default: scan /proc/*/fd).
	OpenFiles func() map[string]bool
	// Now supplies the clock (default time.Now).
	Now func() time.Time
	// AuditLog appends to the audit log (default audit.Log).
	AuditLog func(actor, action, target, detail, result string) error
	// HistoryPath overrides the history file location (tests).
	HistoryPath string
	// LastRunPath overrides the persisted last-run timestamp file
	// (tests).  The cooldown clock must survive process restarts: the
	// systemd oneshot path builds a fresh Runner every timer tick, and
	// an in-memory-only clock would let it re-run every 15 minutes
	// whenever the disk stays over the trigger.
	LastRunPath string
}

func (d *Deps) fillDefaults(cfg Config) {
	if d.Stat == nil {
		d.Stat = StatDisk
	}
	if d.Prune == nil {
		if sock := docker.SocketPath(); sock != "" {
			client := docker.New(sock)
			d.Prune = client.Prune
		} else {
			d.Prune = func(string, bool) (docker.PruneResult, error) {
				return docker.PruneResult{}, fmt.Errorf("docker socket unavailable")
			}
		}
	}
	if d.Vacuum == nil {
		d.Vacuum = func(to uint64) error {
			return exec.Command("journalctl", fmt.Sprintf("--vacuum-size=%d", to)).Run()
		}
	}
	if d.DirSize == nil {
		d.DirSize = dirSize
	}
	if d.Remove == nil {
		d.Remove = os.Remove
	}
	if d.OpenFiles == nil {
		d.OpenFiles = openFiles
	}
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.AuditLog == nil {
		d.AuditLog = audit.Log
	}
	if d.HistoryPath == "" {
		d.HistoryPath = HistoryPath()
	}
	if d.LastRunPath == "" {
		d.LastRunPath = filepath.Join(filepath.Dir(d.HistoryPath), "autoclean-lastrun.txt")
	}
}

// loadLastRun reads the persisted cooldown clock.  A missing or
// unparseable file reads as the zero time (no run on record).
func loadLastRun(path string) time.Time {
	data, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(string(data)))
	if err != nil {
		return time.Time{}
	}
	return t
}

// saveLastRun persists the cooldown clock next to the history file.
func saveLastRun(path string, t time.Time) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(t.Format(time.RFC3339Nano)+"\n"), 0600)
}

// CategoryResult is one category's outcome in a run.
type CategoryResult struct {
	Category       string   `json:"category"`
	BytesReclaimed uint64   `json:"bytes_reclaimed"`
	ItemsRemoved   int      `json:"items_removed"`
	Items          []string `json:"items,omitempty"`
	Skipped        string   `json:"skipped,omitempty"`
	Error          string   `json:"error,omitempty"`
}

// RunSummary is the outcome of one RunOnce call.
type RunSummary struct {
	At             time.Time        `json:"at"`
	Triggered      bool             `json:"triggered"`
	DryRun         bool             `json:"dry_run"`
	Trigger        string           `json:"trigger,omitempty"`
	DiskBefore     DiskUsage        `json:"disk_before"`
	DiskAfter      DiskUsage        `json:"disk_after,omitempty"`
	Categories     []CategoryResult `json:"categories,omitempty"`
	BytesReclaimed uint64           `json:"bytes_reclaimed"`
	ItemsRemoved   int              `json:"items_removed"`
	InCooldown     bool             `json:"in_cooldown,omitempty"`
}

// Runner executes autoclean runs under one config.  Safe for concurrent
// use; overlapping runs are refused by the in-run mutex, because two
// prunes racing help nobody.
type Runner struct {
	cfg  Config
	deps Deps

	mu      sync.Mutex
	running bool
	lastRun time.Time
}

// NewRunner builds a runner; unset deps get their real implementations.
// The cooldown clock is seeded from the persisted last-run timestamp, so
// the cooldown holds across process restarts (systemd oneshot ticks, CLI
// invocations, daemon restarts alike).
func NewRunner(cfg Config, deps Deps) *Runner {
	deps.fillDefaults(cfg)
	r := &Runner{cfg: cfg, deps: deps}
	r.lastRun = loadLastRun(deps.LastRunPath)
	return r
}

// Config returns the runner's config.
func (r *Runner) Config() Config { return r.cfg }

// Check measures the root disk and reports whether a run would trigger.
// It never deletes anything.
func (r *Runner) Check() (DiskUsage, bool, error) {
	u, err := r.deps.Stat(r.cfg.RootPath)
	if err != nil {
		return u, false, err
	}
	return u, r.cfg.ShouldRun(u), nil
}

// RunOnce executes a single cleanup pass when dryRun is false, or the
// identical plan in report-only mode when dryRun is true.
//
//	force bypasses the trigger and the cooldown (an operator's explicit
//	"run now"); the daemon loop always passes force=false.
func (r *Runner) RunOnce(dryRun bool, force bool) (RunSummary, error) {
	return r.RunOnceAs(r.cfg.Actor, dryRun, force)
}

// RunOnceAs is RunOnce with an explicit actor for the audit log and the
// history record (a device id or "local" for API/CLI-triggered runs).
// Cooldown and in-flight state are shared with RunOnce: they live on the
// runner, not on the call.
func (r *Runner) RunOnceAs(actor string, dryRun bool, force bool) (RunSummary, error) {
	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return RunSummary{}, fmt.Errorf("an autoclean run is already in progress")
	}
	r.running = true
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		r.running = false
		r.mu.Unlock()
	}()

	now := r.deps.Now()
	sum := RunSummary{At: now, DryRun: dryRun}
	before, err := r.deps.Stat(r.cfg.RootPath)
	if err != nil {
		return sum, err
	}
	sum.DiskBefore = before
	sum.Triggered = r.cfg.ShouldRun(before)
	sum.Trigger = fmt.Sprintf("root %.1f%% used, %d bytes free (trigger: >=%.0f%% or <%d bytes free)",
		before.UsedPercent, before.FreeBytes, r.cfg.UsedPercentTrigger, r.cfg.MinFreeBytes)

	if !dryRun && !force {
		if !sum.Triggered {
			_ = r.deps.AuditLog(actor, "autoclean-check", r.cfg.RootPath, sum.Trigger, "not triggered")
			return sum, nil
		}
		if !r.lastRun.IsZero() && now.Sub(r.lastRun) < r.cfg.Cooldown {
			sum.InCooldown = true
			_ = r.deps.AuditLog(actor, "autoclean-check", r.cfg.RootPath, sum.Trigger, "skipped: cooldown")
			return sum, nil
		}
	}

	for _, id := range AllCategories() {
		res := r.runCategory(id, dryRun, now)
		sum.Categories = append(sum.Categories, res)
		sum.BytesReclaimed += res.BytesReclaimed
		sum.ItemsRemoved += res.ItemsRemoved
		result := "ok"
		if res.Error != "" {
			result = "error: " + res.Error
		} else if res.Skipped != "" {
			result = "skipped: " + res.Skipped
		}
		detail := fmt.Sprintf("reclaimed=%d items=%d dry_run=%v", res.BytesReclaimed, res.ItemsRemoved, dryRun)
		_ = r.deps.AuditLog(actor, "autoclean", id, detail, result)
	}

	if after, err := r.deps.Stat(r.cfg.RootPath); err == nil {
		sum.DiskAfter = after
	}

	if !dryRun {
		r.mu.Lock()
		r.lastRun = now
		r.mu.Unlock()
		// Persist the cooldown clock so the next process (the next
		// systemd oneshot tick, a CLI call, a restarted daemon) honors
		// it too.  Best-effort: a failed write is audited, never fatal.
		if err := saveLastRun(r.deps.LastRunPath, now); err != nil {
			_ = r.deps.AuditLog(actor, "autoclean", "cooldown", "persist last-run failed", "error: "+err.Error())
		}
		// History mirrors reclaimed space only: a run that removed
		// nothing leaves no row (the Mac store's rule).
		if sum.ItemsRemoved > 0 || sum.BytesReclaimed > 0 {
			// The persisted record caps each category's item list at
			// 50, like ItemTitles below: a run can delete tens of
			// thousands of stale temp files, and an unbounded list
			// would bloat the append-only history with megabyte lines.
			// The in-memory summary keeps the full list; only the
			// record is capped.
			recCats := make([]CategoryResult, len(sum.Categories))
			for i, c := range sum.Categories {
				recCats[i] = c
				if len(recCats[i].Items) > 50 {
					recCats[i].Items = recCats[i].Items[:50]
				}
			}
			rec := CleanupHistoryRecord{
				CleanedAt:      now,
				BytesReclaimed: sum.BytesReclaimed,
				ItemsRemoved:   sum.ItemsRemoved,
				Tier:           "automatic",
				Source:         actor,
				Trigger:        sum.Trigger,
				Categories:     recCats,
			}
			for _, c := range sum.Categories {
				if c.ItemsRemoved > 0 || c.BytesReclaimed > 0 {
					rec.CategoryIDs = append(rec.CategoryIDs, c.Category)
					rec.ItemTitles = append(rec.ItemTitles, c.Items...)
				}
			}
			if len(rec.ItemTitles) > 50 {
				rec.ItemTitles = rec.ItemTitles[:50]
			}
			_ = AppendHistory(r.deps.HistoryPath, rec)
		}
	}
	return sum, nil
}

func (r *Runner) runCategory(id string, dryRun bool, now time.Time) CategoryResult {
	res := CategoryResult{Category: id}
	if !r.cfg.CategoryEnabled(id) {
		res.Skipped = "disabled in config"
		return res
	}
	switch id {
	case CategoryBuildCache:
		return r.pruneDocker(id, "build-cache", dryRun)
	case CategoryImages:
		// Dangling only.  all=false is the whole point: an unused but
		// tagged image may be the rollback for the next deploy.
		return r.pruneDocker(id, "images", dryRun)
	case CategoryBackups:
		return r.cleanBackups(dryRun, now)
	case CategoryJournal:
		return r.vacuumJournal(dryRun)
	case CategoryStaleTmp:
		return r.cleanTmp(dryRun, now)
	}
	res.Skipped = "unknown category"
	return res
}

func (r *Runner) pruneDocker(id, target string, dryRun bool) CategoryResult {
	res := CategoryResult{Category: id}
	if dryRun {
		res.Skipped = "dry-run: docker prune reports reclaimed bytes only when applied"
		return res
	}
	out, err := r.deps.Prune(target, false)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	res.BytesReclaimed = out.ReclaimedBytes
	if out.ReclaimedBytes > 0 {
		res.ItemsRemoved = 1
		res.Items = []string{"docker prune " + target}
	}
	return res
}

func (r *Runner) cleanBackups(dryRun bool, now time.Time) CategoryResult {
	res := CategoryResult{Category: CategoryBackups}
	var dumps []BackupDump
	for _, root := range r.cfg.BackupDirs {
		if ok, reason := ValidateBackupRoot(root); !ok {
			res.Skipped = reason
			return res
		}
		found, err := scanBackupDir(root, now, r.cfg.BackupInFlightGrace)
		if err != nil {
			// A missing backup dir is a fact to note, not a failure:
			// hosts without local backups simply skip the category.
			res.Skipped = "scan: " + err.Error()
			return res
		}
		dumps = append(dumps, found...)
	}
	sizes := map[string]int64{}
	for _, d := range dumps {
		sizes[d.Path] = d.Size
		for _, s := range d.Sidecars {
			sizes[s.Path] = s.Size
		}
	}
	for _, path := range PlanBackupCleanup(dumps) {
		if dryRun {
			res.Items = append(res.Items, path)
			res.ItemsRemoved++
			res.BytesReclaimed += uint64(sizes[path])
			continue
		}
		if err := r.deps.Remove(path); err != nil {
			res.Error = err.Error()
			return res
		}
		res.Items = append(res.Items, path)
		res.ItemsRemoved++
		res.BytesReclaimed += uint64(sizes[path])
	}
	return res
}

func (r *Runner) vacuumJournal(dryRun bool) CategoryResult {
	res := CategoryResult{Category: CategoryJournal}
	before, err := r.deps.DirSize(r.cfg.JournalDir)
	if err != nil {
		res.Skipped = "journal dir: " + err.Error()
		return res
	}
	to, ok := PlanJournalVacuum(before, r.cfg.JournalTargetBytes, r.cfg.JournalFloorBytes)
	if !ok {
		res.Skipped = fmt.Sprintf("journal %d bytes is at or under target %d", before, r.cfg.JournalTargetBytes)
		return res
	}
	res.Items = []string{fmt.Sprintf("journalctl --vacuum-size=%d (was %d)", to, before)}
	if dryRun {
		res.ItemsRemoved = 1
		res.BytesReclaimed = before - to
		return res
	}
	if err := r.deps.Vacuum(to); err != nil {
		res.Error = err.Error()
		return res
	}
	after, err := r.deps.DirSize(r.cfg.JournalDir)
	if err == nil && after < before {
		res.BytesReclaimed = before - after
	} else {
		res.BytesReclaimed = before - to
	}
	res.ItemsRemoved = 1
	return res
}

func (r *Runner) cleanTmp(dryRun bool, now time.Time) CategoryResult {
	res := CategoryResult{Category: CategoryStaleTmp}
	open := r.deps.OpenFiles()
	var entries []TmpEntry
	for _, dir := range r.cfg.TmpDirs {
		found, err := scanTmpDir(dir, open)
		if err != nil {
			continue // a missing tmp dir is not an error
		}
		entries = append(entries, found...)
	}
	sizes := map[string]int64{}
	for _, e := range entries {
		sizes[e.Path] = e.Size
	}
	for _, path := range SelectStaleTmp(entries, now, r.cfg.TmpMinAge) {
		if !dryRun {
			if err := r.deps.Remove(path); err != nil {
				res.Error = err.Error()
				return res
			}
		}
		res.Items = append(res.Items, path)
		res.ItemsRemoved++
		res.BytesReclaimed += uint64(sizes[path])
	}
	return res
}

// Loop is the daemon's automatic mode: check on the interval, run when
// triggered, until the context ends.  Each check and run is audit-logged
// by RunOnce; a failed check is logged and the loop carries on, because a
// disk watcher that dies on its first error protects nothing.
func (r *Runner) Loop(ctx context.Context) {
	t := time.NewTicker(r.cfg.CheckInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_, _ = r.RunOnce(false, false)
		}
	}
}

// scanBackupDir inventories one backup root.  The app for a dump is its
// directory relative to the root ("." for dumps sitting in the root
// itself), which matches the fleet layout of one directory per app.
func scanBackupDir(root string, now time.Time, grace time.Duration) ([]BackupDump, error) {
	var dumps []BackupDump
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if isIncompleteName(name) || !isDumpName(name) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		dump := BackupDump{
			Path:    path,
			Size:    info.Size(),
			ModTime: info.ModTime(),
		}
		rel, _ := filepath.Rel(root, filepath.Dir(path))
		dump.App = rel
		// Sidecars: same directory, dump name plus a sidecar suffix.
		sibs, _ := os.ReadDir(filepath.Dir(path))
		for _, sib := range sibs {
			if sib.IsDir() {
				continue
			}
			if _, ok := isSidecarOf(sib.Name(), name); ok {
				if si, err := sib.Info(); err == nil {
					dump.Sidecars = append(dump.Sidecars, Sidecar{
						Path: filepath.Join(filepath.Dir(path), sib.Name()),
						Size: si.Size(),
					})
					dump.Complete = true
				}
			}
		}
		if !dump.Complete && now.Sub(info.ModTime()) > grace {
			dump.Complete = true
		}
		dumps = append(dumps, dump)
		return nil
	})
	return dumps, err
}

// scanTmpDir inventories one temp directory, top two levels only: stale
// files buried deeper belong to an application's own layout, and the
// walk stays cheap on a busy host.
func scanTmpDir(root string, open map[string]bool) ([]TmpEntry, error) {
	var entries []TmpEntry
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries are skipped, never fatal
		}
		rel, _ := filepath.Rel(root, path)
		if d.IsDir() {
			if strings.Count(rel, string(filepath.Separator)) >= 2 && path != root {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		entries = append(entries, TmpEntry{
			Path:    path,
			Size:    info.Size(),
			ModTime: info.ModTime(),
			Symlink: d.Type()&os.ModeSymlink != 0,
			Regular: info.Mode().IsRegular(),
			Open:    open[path],
		})
		return nil
	})
	return entries, err
}

// dirSize totals a directory tree in bytes.
func dirSize(root string) (uint64, error) {
	var total uint64
	err := filepath.WalkDir(root, func(_ string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() {
			if info, err := d.Info(); err == nil {
				total += uint64(info.Size())
			}
		}
		return nil
	})
	return total, err
}

// openFiles returns every path held open by any process, from /proc/*/fd.
// Best-effort: an unreadable fd directory shrinks the set, and a file not
// in the set but actually open would also have to be at least TmpMinAge
// old and closed-looking to be selected — the age floor is the backstop.
func openFiles() map[string]bool {
	out := map[string]bool{}
	procs, _ := os.ReadDir("/proc")
	for _, p := range procs {
		if !p.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(p.Name()); err != nil {
			continue
		}
		fds, _ := os.ReadDir(filepath.Join("/proc", p.Name(), "fd"))
		for _, fd := range fds {
			if target, err := os.Readlink(filepath.Join("/proc", p.Name(), "fd", fd.Name())); err == nil {
				out[strings.TrimSuffix(target, " (deleted)")] = true
			}
		}
	}
	return out
}

// SortedCategoryIDs is a small helper for stable output in callers.
func SortedCategoryIDs(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
