package autoclean

import (
	"context"
	"encoding/json"
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
	// client).  autoclean passes all=true ONLY for the build cache,
	// whose records are pure, regenerable cache; images are always
	// pruned dangling-only (all=false) — an unused but tagged image may
	// be the rollback for the next deploy, and tagged-image retention
	// is the unused-images category's planner-gated job, not a prune's.
	Prune func(target string, all bool) (docker.PruneResult, error)
	// Images lists the daemon's images (default: the Docker client).
	Images func() ([]docker.ImageInfo, error)
	// Containers lists all containers, running and stopped (default:
	// the Docker client).
	Containers func() ([]docker.Container, error)
	// DeleteImage removes one image by ID, without force (default: the
	// Docker client).
	DeleteImage func(id string) error
	// ImageStoreBytes measures the uniquely-held bytes of all images
	// (default: the Docker client's system-df total), for
	// measure-before/after reclaim accounting.
	ImageStoreBytes func() (uint64, error)
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
	// OrphanStatePath overrides the persisted image-orphan state file
	// (tests).  Orphanhood must persist across runs to mean anything,
	// for the same reason the cooldown clock must.
	OrphanStatePath string
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
	if d.Images == nil || d.Containers == nil || d.DeleteImage == nil || d.ImageStoreBytes == nil {
		if sock := docker.SocketPath(); sock != "" {
			client := docker.New(sock)
			if d.Images == nil {
				d.Images = client.Images
			}
			if d.Containers == nil {
				d.Containers = client.List
			}
			if d.DeleteImage == nil {
				d.DeleteImage = client.DeleteImage
			}
			if d.ImageStoreBytes == nil {
				d.ImageStoreBytes = client.ImageUniqueBytes
			}
		} else {
			unavailable := fmt.Errorf("docker socket unavailable")
			if d.Images == nil {
				d.Images = func() ([]docker.ImageInfo, error) { return nil, unavailable }
			}
			if d.Containers == nil {
				d.Containers = func() ([]docker.Container, error) { return nil, unavailable }
			}
			if d.DeleteImage == nil {
				d.DeleteImage = func(string) error { return unavailable }
			}
			if d.ImageStoreBytes == nil {
				d.ImageStoreBytes = func() (uint64, error) { return 0, unavailable }
			}
		}
	}
	if d.Vacuum == nil {
		d.Vacuum = func(to uint64) error {
			// Bounded: a wedged journalctl must not hold the
			// single-run guard and wedge every later run.
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()
			return exec.CommandContext(ctx, "journalctl", fmt.Sprintf("--vacuum-size=%d", to)).Run()
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
	if d.OrphanStatePath == "" {
		d.OrphanStatePath = filepath.Join(filepath.Dir(d.HistoryPath), "autoclean-orphans.json")
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

// loadOrphanState reads the persisted image-orphan clock: repository ->
// first time a run observed no container referencing any of its images.
// A missing or unparseable file reads as empty (no orphanhood on
// record), which is the safe direction: every group starts its grace
// clock from the next observation.
func loadOrphanState(path string) map[string]time.Time {
	out := map[string]time.Time{}
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	raw := map[string]string{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return out
	}
	for repo, ts := range raw {
		if t, err := time.Parse(time.RFC3339Nano, ts); err == nil {
			out[repo] = t
		}
	}
	return out
}

// saveOrphanState persists the orphan clock next to the history file.
func saveOrphanState(path string, state map[string]time.Time) error {
	raw := map[string]string{}
	for repo, t := range state {
		raw[repo] = t.Format(time.RFC3339Nano)
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0600)
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

// RetentionLine is one backup root's retention total for a run's
// report: how much space the local backup copies hold, split into the
// dump files themselves and everything else in the root.  Report-only —
// retention policy belongs to the backup system, but its growth is
// structural disk pressure and every run states it plainly.
type RetentionLine struct {
	Dir        string `json:"dir"`
	TotalBytes uint64 `json:"total_bytes"`
	DumpBytes  uint64 `json:"dump_bytes"`
	Dumps      int    `json:"dumps"`
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
	// Emergency marks a run that bypassed the cooldown under the
	// emergency tier.
	Emergency bool `json:"emergency,omitempty"`
	// Alerts are the large-new-file watch's findings inside Docker
	// volumes.  Report-only: nothing here was, or will be, deleted by
	// autoclean.
	Alerts []VolumeFinding `json:"alerts,omitempty"`
	// BackupsRetention is the per-root local-backup retention total.
	BackupsRetention []RetentionLine `json:"backups_retention,omitempty"`
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
			if r.cfg.Emergency(before) {
				// Emergency tier: above the emergency line the cooldown
				// does not apply.  On 2026-11-21 the disk lost ~14 GB in
				// 90 minutes while checks at 87–93% used were skipped
				// for the cooldown; a disk in free fall gets pruned on
				// every check until it drops back under the line.
				sum.Emergency = true
				sum.Trigger += " [emergency: cooldown bypassed]"
				_ = r.deps.AuditLog(actor, "autoclean-check", r.cfg.RootPath, sum.Trigger, "emergency: cooldown bypassed")
			} else {
				sum.InCooldown = true
				_ = r.deps.AuditLog(actor, "autoclean-check", r.cfg.RootPath, sum.Trigger, "skipped: cooldown")
				// The watchers still run on a cooldown skip: they delete
				// nothing, and a large new file inside a volume is
				// exactly what a human needs to hear about while the
				// disk sits over the trigger waiting out the cooldown.
				r.reportWatchers(&sum, actor, now)
				return sum, nil
			}
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

	r.reportWatchers(&sum, actor, now)

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
		// History mirrors reclaimed space: a run that removed nothing
		// leaves no row (the Mac store's rule) — with one extension: a
		// run whose watch raised an alert DOES leave a row, even at
		// zero reclaimed.  The alert is the run's outcome, and history
		// is the surface the operator reads; an alert that left no
		// record would be invisible there.
		if sum.ItemsRemoved > 0 || sum.BytesReclaimed > 0 || len(sum.Alerts) > 0 {
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
				Alerts:         sum.Alerts,
			}
			for _, line := range sum.BackupsRetention {
				rec.BackupsRetentionBytes += line.TotalBytes
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
	case CategoryUnusedImages:
		return r.cleanUnusedImages(dryRun, now)
	case CategoryBackups:
		return r.cleanBackups(dryRun, now)
	case CategoryAgentCaches:
		return r.cleanAgentCaches(dryRun, now)
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
	// The build cache is pruned with all=true — the `docker builder
	// prune -af` behavior.  With all=false the endpoint clears only
	// dangling records, and Coolify's regular build cache (the bulk of
	// every deploy's output) survives untouched: on 2026-11-21 this
	// category reported 0 bytes in every run while 8.9 GB of cache sat
	// on the disk.  Build cache is regenerable by definition, and cache
	// a build is using at this instant is BuildKit's call, never
	// interrupted.  Images stay all=false (see runCategory).
	all := target == "build-cache"
	out, err := r.deps.Prune(target, all)
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

// cleanUnusedImages applies the retention planner: per repository,
// generations beyond the rollback window go, plus long-orphaned
// repositories' older generations.  Deletion is by image ID without
// force, so the daemon itself refuses anything a container references.
func (r *Runner) cleanUnusedImages(dryRun bool, now time.Time) CategoryResult {
	res := CategoryResult{Category: CategoryUnusedImages}
	images, err := r.deps.Images()
	if err != nil {
		res.Error = "images: " + err.Error()
		return res
	}
	containers, err := r.deps.Containers()
	if err != nil {
		res.Error = "containers: " + err.Error()
		return res
	}
	usedIDs := map[string]bool{}
	for _, c := range containers {
		if c.ImageID != "" {
			usedIDs[c.ImageID] = true
		}
	}
	var inventory []DeployImage
	for _, im := range images {
		di, ok := deployImage(im)
		if !ok {
			continue // untagged, digest-only, or multi-repo: not ours
		}
		inventory = append(inventory, di)
	}
	orphanSince := loadOrphanState(r.deps.OrphanStatePath)
	candidates, nextOrphan := PlanUnusedImages(inventory, usedIDs, r.cfg.ImageKeepPerRepo, orphanSince, now, r.cfg.ImageOrphanGrace)
	for _, c := range candidates {
		res.Items = append(res.Items, c.Repo+":"+c.Tag)
	}
	if dryRun {
		res.ItemsRemoved = len(candidates)
		return res
	}
	// Persist the orphan clock even when nothing is deleted: the
	// observations ARE the state the grace rule runs on.
	if err := saveOrphanState(r.deps.OrphanStatePath, nextOrphan); err != nil {
		_ = r.deps.AuditLog(r.cfg.Actor, "autoclean", CategoryUnusedImages, "persist orphan state failed", "error: "+err.Error())
	}
	if len(candidates) == 0 {
		return res
	}
	storeBefore, storeErr := r.deps.ImageStoreBytes()
	var failures []string
	var deletedSize int64
	for _, c := range candidates {
		if err := r.deps.DeleteImage(c.ID); err != nil {
			failures = append(failures, c.Repo+":"+c.Tag+": "+err.Error())
			continue
		}
		res.ItemsRemoved++
		deletedSize += c.Size
	}
	switch {
	case storeErr == nil:
		if storeAfter, err := r.deps.ImageStoreBytes(); err == nil && storeAfter < storeBefore {
			// Measured, like the journal: the delta of uniquely-held
			// image bytes, never the deleted images' virtual sizes
			// (which double-count shared layers).
			res.BytesReclaimed = storeBefore - storeAfter
		} else {
			// Unmeasurable afterwards: fall back to the deleted
			// images' sizes (the journal category's precedent).
			res.BytesReclaimed = uint64(deletedSize)
		}
	default:
		res.BytesReclaimed = uint64(deletedSize)
	}
	if len(failures) > 0 {
		res.Error = fmt.Sprintf("%d deletion(s) failed: %s", len(failures), strings.Join(failures, "; "))
	}
	// Items names what was planned; on partial failure the error above
	// names what did not go.  Keep Items to the deleted set so the
	// history never claims a removal that failed.
	if len(failures) > 0 {
		failed := map[string]bool{}
		for _, f := range failures {
			failed[strings.SplitN(f, ": ", 2)[0]] = true
		}
		kept := res.Items[:0]
		for _, item := range res.Items {
			if !failed[item] {
				kept = append(kept, item)
			}
		}
		res.Items = kept
	}
	return res
}

// deployImage maps a Docker image to the planner's shape.  ok=false for
// images the planner must never see: untagged or digest-only images
// (the dangling category's territory), and images tagged into more
// than one repository, whose owning app is ambiguous.
func deployImage(im docker.ImageInfo) (DeployImage, bool) {
	repos := map[string]string{} // repo -> tag
	for _, ref := range im.RepoTags {
		if ref == "" || ref == "<none>:<none>" {
			continue
		}
		repo, tag, ok := ImageRepoTag(ref)
		if !ok {
			return DeployImage{}, false
		}
		repos[repo] = tag
	}
	if len(repos) != 1 {
		return DeployImage{}, false
	}
	for repo, tag := range repos {
		return DeployImage{
			ID:      im.ID,
			Repo:    repo,
			Tag:     tag,
			Created: time.Unix(im.Created, 0),
			Size:    im.Size,
		}, true
	}
	return DeployImage{}, false
}

// cleanAgentCaches purges the seat's regenerable tool caches.  Files go
// (never the cache root itself, so the tools keep their directory), and
// directories left empty by the purge are removed deepest-first.
func (r *Runner) cleanAgentCaches(dryRun bool, now time.Time) CategoryResult {
	res := CategoryResult{Category: CategoryAgentCaches}
	open := r.deps.OpenFiles()
	var failures []string
	present := 0
	for _, dir := range r.cfg.AgentCacheDirList() {
		if ok, reason := ValidateAgentCacheDir(dir); !ok {
			failures = append(failures, reason)
			continue
		}
		info, err := os.Lstat(dir)
		if err != nil {
			continue // a tool that is not installed has no cache here
		}
		if info.Mode()&os.ModeSymlink != 0 {
			failures = append(failures, "refusing agent cache dir "+dir+": is a symlink")
			continue
		}
		if !info.IsDir() {
			continue
		}
		present++
		entries, dirs, err := scanCacheDir(dir, open)
		if err != nil {
			failures = append(failures, "scan "+dir+": "+err.Error())
			continue
		}
		sizes := map[string]int64{}
		for _, e := range entries {
			sizes[e.Path] = e.Size
		}
		for _, path := range SelectStaleCache(entries, now, r.cfg.AgentCacheMinAge) {
			if !dryRun {
				if err := r.deps.Remove(path); err != nil {
					failures = append(failures, path+": "+err.Error())
					continue
				}
			}
			res.Items = append(res.Items, path)
			res.ItemsRemoved++
			res.BytesReclaimed += uint64(sizes[path])
		}
		if !dryRun {
			// Deepest first; Remove on a non-empty directory fails and
			// is ignored — only directories the purge actually emptied
			// go away, and never the cache root itself.
			sort.Sort(sort.Reverse(sort.StringSlice(dirs)))
			for _, d := range dirs {
				_ = r.deps.Remove(d)
			}
		}
	}
	switch {
	case present == 0 && len(failures) == 0:
		res.Skipped = "no agent cache dirs present"
	case len(failures) > 0:
		res.Error = strings.Join(failures, "; ")
	}
	return res
}

// scanCacheDir inventories one cache tree (full depth — a cache's own
// layout is the tool's, and every file in it is cache by definition)
// plus its subdirectories, for empty-dir pruning after the purge.
func scanCacheDir(root string, open map[string]bool) ([]TmpEntry, []string, error) {
	var entries []TmpEntry
	var dirs []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries are skipped, never fatal
		}
		if d.IsDir() {
			if path != root {
				dirs = append(dirs, path)
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
	return entries, dirs, err
}

// reportWatchers runs the two report-only watchers into the summary:
// the large-new-file watch inside Docker volumes, and the backups
// retention lines.  Neither deletes anything, ever.  Findings are
// audit-logged individually, so they survive in the audit trail even
// for runs that write no history record (dry runs, cooldown skips).
func (r *Runner) reportWatchers(sum *RunSummary, actor string, now time.Time) {
	if entries, err := scanVolumeWatch(r.cfg.DockerVolumesDir, r.cfg.VolumeWatchMaxDepth); err == nil {
		sum.Alerts = FindLargeNewFiles(entries, r.cfg.VolumeWatchThresholdBytes, r.cfg.VolumeWatchWindow, now, 20)
		for _, f := range sum.Alerts {
			_ = r.deps.AuditLog(actor, "autoclean-watch", f.Path,
				fmt.Sprintf("large new file in docker volume %s: %d bytes, %ds old — report only, disposition is a human decision", f.Volume, f.Size, f.AgeSeconds),
				"alert")
		}
	}
	sum.BackupsRetention = r.retentionLines(now)
}

// retentionLines measures each backup root for the run's report: total
// bytes in the root, and the dump files' share of it.  Unreadable or
// refused roots are omitted — the backups category reports its own
// errors; this is a measurement, not a second error channel.
func (r *Runner) retentionLines(now time.Time) []RetentionLine {
	var lines []RetentionLine
	for _, root := range r.cfg.BackupDirs {
		if ok, _ := ValidateBackupRoot(root); !ok {
			continue
		}
		total, err := r.deps.DirSize(root)
		if err != nil {
			continue
		}
		line := RetentionLine{Dir: root, TotalBytes: total}
		if dumps, err := scanBackupDir(root, now, r.cfg.BackupInFlightGrace); err == nil {
			for _, d := range dumps {
				line.Dumps++
				line.DumpBytes += uint64(d.Size)
				for _, s := range d.Sidecars {
					line.DumpBytes += uint64(s.Size)
				}
			}
		}
		lines = append(lines, line)
	}
	return lines
}

// scanVolumeWatch inventories files inside Docker volumes: for each
// volume, its _data directory, walked to at most maxDepth levels below
// _data.  The depth bound is the cost control — the walk stats files,
// it never reads them, and live volume data is never modified.
func scanVolumeWatch(volumesDir string, maxDepth int) ([]VolumeFileEntry, error) {
	var entries []VolumeFileEntry
	vols, err := os.ReadDir(volumesDir)
	if err != nil {
		return nil, err
	}
	for _, v := range vols {
		if !v.IsDir() {
			continue
		}
		dataDir := filepath.Join(volumesDir, v.Name(), "_data")
		if info, err := os.Stat(dataDir); err != nil || !info.IsDir() {
			continue
		}
		_ = filepath.WalkDir(dataDir, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(dataDir, path)
			depth := 0
			if rel != "." {
				depth = strings.Count(rel, string(filepath.Separator)) + 1
			}
			if d.IsDir() {
				if depth >= maxDepth && path != dataDir {
					return filepath.SkipDir
				}
				return nil
			}
			if depth > maxDepth {
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return nil
			}
			entries = append(entries, VolumeFileEntry{
				Volume:  v.Name(),
				Path:    path,
				Size:    info.Size(),
				ModTime: info.ModTime(),
				Symlink: d.Type()&os.ModeSymlink != 0,
				Regular: info.Mode().IsRegular(),
			})
			return nil
		})
	}
	return entries, nil
}

func (r *Runner) cleanBackups(dryRun bool, now time.Time) CategoryResult {
	res := CategoryResult{Category: CategoryBackups}
	var failures []string
	scanned := 0
	// Roots are planned independently, and one bad root never aborts
	// the category: a dump's app key is relative to its own root, so
	// planning across roots would conflate same-named apps and could
	// delete one root's only dump because another root holds a newer
	// one; and a refused or unreadable root says nothing about the
	// roots that follow it.
	for _, root := range r.cfg.BackupDirs {
		if ok, reason := ValidateBackupRoot(root); !ok {
			failures = append(failures, reason)
			continue
		}
		dumps, err := scanBackupDir(root, now, r.cfg.BackupInFlightGrace)
		if err != nil {
			// A missing backup dir is a fact to note, not a failure:
			// hosts without local backups simply skip the category.
			failures = append(failures, "scan "+root+": "+err.Error())
			continue
		}
		scanned++
		sizes := map[string]int64{}
		for _, d := range dumps {
			sizes[d.Path] = d.Size
			for _, s := range d.Sidecars {
				sizes[s.Path] = s.Size
			}
		}
		for _, path := range PlanBackupCleanup(dumps) {
			if !dryRun {
				if err := r.deps.Remove(path); err != nil {
					failures = append(failures, "remove "+path+": "+err.Error())
					continue
				}
			}
			res.Items = append(res.Items, path)
			res.ItemsRemoved++
			res.BytesReclaimed += uint64(sizes[path])
		}
	}
	switch {
	case scanned == 0 && len(failures) > 0:
		res.Skipped = strings.Join(failures, "; ")
	case len(failures) > 0:
		res.Error = strings.Join(failures, "; ")
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
	switch {
	case err == nil && after < before:
		res.BytesReclaimed = before - after
	case err == nil:
		// Measured, and the journal did not shrink: report zero, not
		// the plan's estimate — history must not record bytes that
		// were never freed.
		res.BytesReclaimed = 0
	default:
		// Unmeasurable afterwards: fall back to the plan estimate.
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
	// One unremovable file (sticky /tmp, another user's file) must not
	// abort the sweep: record the failures and keep cleaning.
	var failures []string
	for _, path := range SelectStaleTmp(entries, now, r.cfg.TmpMinAge) {
		if !dryRun {
			if err := r.deps.Remove(path); err != nil {
				failures = append(failures, path+": "+err.Error())
				continue
			}
		}
		res.Items = append(res.Items, path)
		res.ItemsRemoved++
		res.BytesReclaimed += uint64(sizes[path])
	}
	if len(failures) > 0 {
		res.Error = fmt.Sprintf("%d removal(s) failed: %s", len(failures), strings.Join(failures, "; "))
	}
	return res
}

// Loop is the daemon's automatic mode: check on the interval, run when
// triggered, until the context ends.  Each check and run is audit-logged
// by RunOnce; a failed check is logged and the loop carries on, because a
// disk watcher that dies on its first error protects nothing.
// containerMarkerPaths are the marker files container runtimes leave
// in a container's root filesystem (Docker, Podman).  A variable so
// tests can point it at fixtures.
var containerMarkerPaths = []string{"/.dockerenv", "/run/.containerenv"}

// looksContainerized reports whether this process runs inside a
// container.  Autoclean's defaults name host paths (/backups, /tmp,
// the journal); inside the scratch container image those are the
// container's own filesystems, the Docker categories still work, but
// the host's disk — the thing autoclean exists to reclaim — would
// never be touched, and the journal category could only error.  The
// unattended loop therefore refuses to start in a container; the
// supported automatic deployment is host-native (the systemd timer in
// deploy/).  An explicit CLI run stays the operator's call.
func looksContainerized() bool {
	for _, p := range containerMarkerPaths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

func (r *Runner) Loop(ctx context.Context) {
	if looksContainerized() {
		_ = r.deps.AuditLog(r.cfg.Actor, "autoclean-loop", r.cfg.RootPath,
			"refusing to start in a container: autoclean targets the host filesystem; use the systemd timer on a host-native install",
			"skipped")
		return
	}
	interval := r.cfg.CheckInterval
	if interval <= 0 {
		// A zero-value Config with Enabled flipped on must not panic
		// the daemon on time.NewTicker.
		interval = DefaultConfig().CheckInterval
	}
	t := time.NewTicker(interval)
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
	// Directory listings are cached per directory: sidecar discovery
	// needs the dump's siblings, and re-listing the directory for
	// every dump makes the scan quadratic in the number of dumps.
	listings := map[string][]os.DirEntry{}
	siblings := func(dir string) []os.DirEntry {
		if l, ok := listings[dir]; ok {
			return l
		}
		l, _ := os.ReadDir(dir)
		listings[dir] = l
		return l
	}
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
		for _, sib := range siblings(filepath.Dir(path)) {
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
		if strings.Count(rel, string(filepath.Separator)) >= 2 {
			// Beyond the two-level boundary even though the parent
			// directory was entered: an application's own layout,
			// never inventoried for deletion.
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
