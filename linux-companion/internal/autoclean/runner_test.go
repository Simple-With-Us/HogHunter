package autoclean

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/docker"
)

// fakeWorld is a runner's outside world, fully in memory except the
// backup/tmp fixtures, which use a real temp directory because the
// walkers are part of what is being tested.
type fakeWorld struct {
	usage     DiskUsage
	removed   []string
	pruned    []string
	pruneAll  []bool
	vacuumTo  uint64
	vacuumed  bool
	audits    []string
	journalSz uint64
	now       time.Time

	images        []docker.ImageInfo
	containers    []docker.Container
	deletedImages []string
	storeBytes    uint64
	deleteErr     map[string]error
}

func (w *fakeWorld) deps() Deps {
	return Deps{
		Stat: func(string) (DiskUsage, error) { return w.usage, nil },
		Prune: func(target string, all bool) (docker.PruneResult, error) {
			w.pruned = append(w.pruned, target)
			w.pruneAll = append(w.pruneAll, all)
			return docker.PruneResult{ReclaimedBytes: 1000}, nil
		},
		Images:     func() ([]docker.ImageInfo, error) { return w.images, nil },
		Containers: func() ([]docker.Container, error) { return w.containers, nil },
		DeleteImage: func(id string) error {
			if err, bad := w.deleteErr[id]; bad {
				return err
			}
			w.deletedImages = append(w.deletedImages, id)
			return nil
		},
		ImageStoreBytes: func() (uint64, error) { return w.storeBytes, nil },
		Vacuum: func(to uint64) error {
			w.vacuumed = true
			w.vacuumTo = to
			w.journalSz = to
			return nil
		},
		DirSize: func(string) (uint64, error) { return w.journalSz, nil },
		Remove: func(p string) error {
			w.removed = append(w.removed, p)
			return os.Remove(p) // fixtures are real files; remove for real
		},
		OpenFiles: func() map[string]bool { return map[string]bool{} },
		Now:       func() time.Time { return w.now },
		AuditLog: func(actor, action, target, detail, result string) error {
			w.audits = append(w.audits, action+":"+target+":"+result)
			return nil
		},
	}
}

func testConfig(t *testing.T, w *fakeWorld) Config {
	t.Helper()
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.RootPath = "/"
	cfg.BackupDirs = []string{filepath.Join(t.TempDir(), "backups")}
	cfg.JournalDir = filepath.Join(t.TempDir(), "journal")
	cfg.TmpDirs = []string{filepath.Join(t.TempDir(), "tmp")}
	// Hermetic agent caches: an empty temp cache dir, so the category
	// runs but finds nothing — and never the host's real /home.
	cfg.AgentCacheDirs = []string{filepath.Join(t.TempDir(), ".cache", "deno")}
	cfg.Cooldown = 0
	return cfg
}

func writeFile(t *testing.T, path string, size int, mtime time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

func TestRunnerNotTriggeredDoesNothing(t *testing.T) {
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 100, UsedBytes: 50, FreeBytes: 50, UsedPercent: 50},
		now:   time.Date(2026, 11, 7, 0, 0, 0, 0, time.UTC),
	}
	cfg := testConfig(t, w)
	cfg.MinFreeBytes = 10
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Triggered {
		t.Fatal("run must not trigger at 50% used with free over the floor")
	}
	if len(w.removed) > 0 || len(w.pruned) > 0 || w.vacuumed {
		t.Fatalf("nothing may be deleted on an untriggered check: removed=%v pruned=%v vacuumed=%v", w.removed, w.pruned, w.vacuumed)
	}
	if _, err := os.Stat(d.HistoryPath); !os.IsNotExist(err) {
		t.Error("an untriggered check must not write history")
	}
}

func TestRunnerAppliedRunEndToEnd(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage:     DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:       now,
		journalSz: 3 << 30,
	}
	cfg := testConfig(t, w)
	// Fixtures: two generations of um backups (old one has a checksum),
	// one stale tmp file, one fresh tmp file.
	old := now.Add(-72 * time.Hour)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "a.db"), 500, old)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "a.db.sha256"), 10, old)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "b.db"), 500, now.Add(-time.Hour))
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "b.db.sha256"), 10, now.Add(-time.Hour))
	writeFile(t, filepath.Join(cfg.TmpDirs[0], "stale.log"), 100, now.Add(-8*24*time.Hour))
	writeFile(t, filepath.Join(cfg.TmpDirs[0], "fresh.log"), 100, now.Add(-time.Hour))
	// A live daemon socket with a stale mtime must survive: it is not a
	// regular file, and its fd does not resolve to its path.
	sockPath := filepath.Join(cfg.TmpDirs[0], "daemon.sock")
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if err := os.Chtimes(sockPath, now.Add(-8*24*time.Hour), now.Add(-8*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	// A stale file below the two-level scan boundary is an app's own
	// layout and must survive too.
	deepPath := filepath.Join(cfg.TmpDirs[0], "app", "sub", "deep.log")
	writeFile(t, deepPath, 100, now.Add(-8*24*time.Hour))
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)

	sum, err := r.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !sum.Triggered {
		t.Fatal("92% used must trigger")
	}
	// Docker: build cache first, then dangling images.  The build
	// cache is pruned with all=true (the `builder prune -af` behavior —
	// with all=false, Coolify's regular cache survives and the category
	// reclaims 0); images stay all=false forever (dangling only).
	if len(w.pruned) != 2 || w.pruned[0] != "build-cache" || w.pruned[1] != "images" {
		t.Fatalf("pruned=%v, want [build-cache images]", w.pruned)
	}
	if !w.pruneAll[0] {
		t.Error("build cache must be pruned with all=true")
	}
	if w.pruneAll[1] {
		t.Error("images must never be pruned with all=true (dangling only)")
	}
	// The newest um dump and its generation survive; the old generation
	// and its checksum go.  Fresh tmp survives; stale tmp goes.
	kept := filepath.Join(cfg.BackupDirs[0], "um", "b.db")
	if _, err := os.Stat(kept); err != nil {
		t.Errorf("newest complete dump must survive: %v", err)
	}
	if _, err := os.Stat(filepath.Join(cfg.TmpDirs[0], "fresh.log")); err != nil {
		t.Errorf("fresh tmp file must survive: %v", err)
	}
	if _, err := os.Stat(sockPath); err != nil {
		t.Errorf("daemon socket must survive: %v", err)
	}
	if _, err := os.Stat(deepPath); err != nil {
		t.Errorf("file below the scan depth boundary must survive: %v", err)
	}
	goneOld := filepath.Join(cfg.BackupDirs[0], "um", "a.db")
	goneStale := filepath.Join(cfg.TmpDirs[0], "stale.log")
	for _, p := range []string{goneOld, goneOld + ".sha256", goneStale} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s must be removed", p)
		}
	}
	// Journal vacuumed to the 200MiB target, above the 100MiB floor.
	if !w.vacuumed || w.vacuumTo != 200<<20 {
		t.Errorf("vacuumed=%v to=%d, want 200MiB", w.vacuumed, w.vacuumTo)
	}
	// History: exactly one record, with the categories that removed
	// something and a nonzero total.
	recs, err := ReadHistory(d.HistoryPath)
	if err != nil || len(recs) != 1 {
		t.Fatalf("history records=%v err=%v", recs, err)
	}
	rec := recs[0]
	if rec.BytesReclaimed == 0 || rec.ItemsRemoved == 0 {
		t.Errorf("history record must carry reclaimed bytes and items: %+v", rec)
	}
	if rec.Tier != "automatic" || rec.Source != "autoclean" {
		t.Errorf("history tier/source wrong: %+v", rec)
	}
	found := map[string]bool{}
	for _, id := range rec.CategoryIDs {
		found[id] = true
	}
	for _, id := range []string{CategoryBuildCache, CategoryImages, CategoryBackups, CategoryJournal, CategoryStaleTmp} {
		if !found[id] {
			t.Errorf("history missing category %s: %v", id, rec.CategoryIDs)
		}
	}
	if len(w.audits) == 0 {
		t.Error("an applied run must write audit entries")
	}
}

func TestRunnerDryRunDeletesNothingAndWritesNoHistory(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage:     DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:       now,
		journalSz: 3 << 30,
	}
	cfg := testConfig(t, w)
	old := now.Add(-72 * time.Hour)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "a.db"), 500, old)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "b.db"), 500, now.Add(-time.Hour))
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "b.db.sha256"), 10, now.Add(-time.Hour))
	writeFile(t, filepath.Join(cfg.TmpDirs[0], "stale.log"), 100, now.Add(-8*24*time.Hour))
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)

	sum, err := r.RunOnce(true, false)
	if err != nil {
		t.Fatal(err)
	}
	if !sum.DryRun || sum.ItemsRemoved == 0 {
		t.Fatalf("dry-run must still produce a plan with items: %+v", sum)
	}
	for _, p := range []string{
		filepath.Join(cfg.BackupDirs[0], "um", "a.db"),
		filepath.Join(cfg.TmpDirs[0], "stale.log"),
	} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("dry-run deleted %s", p)
		}
	}
	if len(w.pruned) > 0 || w.vacuumed {
		t.Error("dry-run must not call docker prune or journal vacuum")
	}
	if _, err := os.Stat(d.HistoryPath); !os.IsNotExist(err) {
		t.Error("dry-run must not write cleanup history")
	}
}

func TestRunnerCooldownSuppressesSecondRun(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	// Triggered (85% ≥ 80%) but NOT emergency (under 90%, free over
	// the 16 GiB emergency floor): the cooldown must hold.  The
	// emergency bypass has its own test below.
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 255 << 30, FreeBytes: 40 << 30, UsedPercent: 85},
		now:   now,
	}
	cfg := testConfig(t, w)
	cfg.Cooldown = 6 * time.Hour
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	if _, err := r.RunOnce(false, false); err != nil {
		t.Fatal(err)
	}
	prunedAfterFirst := len(w.pruned)
	sum, err := r.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !sum.InCooldown {
		t.Error("second run inside the cooldown must be suppressed")
	}
	if len(w.pruned) != prunedAfterFirst {
		t.Error("a cooldown-suppressed run must not prune again")
	}
	// Force bypasses the cooldown: an operator's explicit run-now.
	if _, err := r.RunOnce(false, true); err != nil {
		t.Fatal(err)
	}
	if len(w.pruned) <= prunedAfterFirst {
		t.Error("a forced run must bypass the cooldown")
	}
}

func TestRunnerCooldownSurvivesRestart(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 255 << 30, FreeBytes: 40 << 30, UsedPercent: 85},
		now:   now,
	}
	cfg := testConfig(t, w)
	cfg.Cooldown = 6 * time.Hour
	hist := filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	d1 := w.deps()
	d1.HistoryPath = hist
	r1 := NewRunner(cfg, d1)
	if _, err := r1.RunOnce(false, false); err != nil {
		t.Fatal(err)
	}
	prunedAfterFirst := len(w.pruned)
	// A brand-new Runner over the same state dir — the systemd oneshot
	// case — must still honor the cooldown from the persisted clock.
	d2 := w.deps()
	d2.HistoryPath = hist
	r2 := NewRunner(cfg, d2)
	sum, err := r2.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !sum.InCooldown {
		t.Error("cooldown must survive a process restart via the persisted last-run clock")
	}
	if len(w.pruned) != prunedAfterFirst {
		t.Error("a cooldown-suppressed run after restart must not prune again")
	}
}

func TestRunnerEmergencyBypassesCooldown(t *testing.T) {
	now := time.Date(2026, 11, 21, 18, 0, 0, 0, time.UTC)
	mkRunner := func(w *fakeWorld, hist string) *Runner {
		cfg := testConfig(t, w)
		cfg.Cooldown = 6 * time.Hour
		d := w.deps()
		d.HistoryPath = hist
		return NewRunner(cfg, d)
	}
	// Percent emergency: 92% used.  First run applies; the second,
	// minutes later and deep inside the cooldown, must run anyway.
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	hist := filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := mkRunner(w, hist)
	if _, err := r.RunOnce(false, false); err != nil {
		t.Fatal(err)
	}
	prunedAfterFirst := len(w.pruned)
	sum, err := r.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if sum.InCooldown {
		t.Error("an emergency run must not be suppressed by the cooldown")
	}
	if !sum.Emergency {
		t.Error("the bypassed run must be marked emergency")
	}
	if len(w.pruned) <= prunedAfterFirst {
		t.Error("the emergency run must actually prune again")
	}
	// Free-space emergency: 85% used but free under the 16 GiB floor.
	w2 := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 255 << 30, FreeBytes: 10 << 30, UsedPercent: 85},
		now:   now,
	}
	r2 := mkRunner(w2, filepath.Join(t.TempDir(), "cleanup-history.jsonl"))
	if _, err := r2.RunOnce(false, false); err != nil {
		t.Fatal(err)
	}
	sum2, err := r2.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if sum2.InCooldown || !sum2.Emergency {
		t.Errorf("free-floor emergency must bypass the cooldown: %+v", sum2)
	}
	// And the control case: triggered but not emergency stays
	// suppressed (also covered by TestRunnerCooldownSuppressesSecondRun).
	w3 := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 255 << 30, FreeBytes: 40 << 30, UsedPercent: 85},
		now:   now,
	}
	r3 := mkRunner(w3, filepath.Join(t.TempDir(), "cleanup-history.jsonl"))
	if _, err := r3.RunOnce(false, false); err != nil {
		t.Fatal(err)
	}
	sum3, err := r3.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !sum3.InCooldown || sum3.Emergency {
		t.Errorf("a non-emergency run inside the cooldown must stay suppressed: %+v", sum3)
	}
}

func TestRunnerUnusedImages(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	img := func(id, repo string, age time.Duration) docker.ImageInfo {
		return docker.ImageInfo{
			ID:       id,
			RepoTags: []string{repo + ":" + id},
			Created:  now.Add(-age).Unix(),
			Size:     1000,
		}
	}
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
		images: []docker.ImageInfo{
			img("um4", "um", time.Hour), img("um3", "um", 2*time.Hour),
			img("um2", "um", 3*time.Hour), img("um1", "um", 4*time.Hour),
			{ID: "dangling", RepoTags: []string{"<none>:<none>"}, Created: now.Add(-72 * time.Hour).Unix(), Size: 5},
		},
		containers: []docker.Container{{ID: "c1", ImageID: "um4"}},
	}
	cfg := testConfig(t, w)
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, true)
	if err != nil {
		t.Fatal(err)
	}
	// Beyond keep=2 goes; the used newest and the previous stay; the
	// dangling image is not this category's business.
	if len(w.deletedImages) != 2 || w.deletedImages[0] != "um1" && w.deletedImages[0] != "um2" {
		t.Fatalf("deleted=%v, want um1+um2 in some order", w.deletedImages)
	}
	for _, c := range sum.Categories {
		if c.Category == CategoryUnusedImages {
			if c.ItemsRemoved != 2 {
				t.Errorf("unused-images ItemsRemoved=%d, want 2", c.ItemsRemoved)
			}
			// Store measurement is constant in the fake, so the
			// fallback (deleted sizes) applies: 2 x 1000.
			if c.BytesReclaimed != 2000 {
				t.Errorf("unused-images BytesReclaimed=%d, want 2000 (fallback sizes)", c.BytesReclaimed)
			}
		}
	}
}

func TestRunnerUnusedImagesOrphanAcrossRestarts(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	img := func(id string, age time.Duration) docker.ImageInfo {
		return docker.ImageInfo{
			ID:       id,
			RepoTags: []string{"coollabsio/coolify-helper:" + id},
			Created:  now.Add(-age).Unix(),
			Size:     1000,
		}
	}
	hist := filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	run := func(at time.Time) *fakeWorld {
		w := &fakeWorld{
			usage:  DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
			now:    at,
			images: []docker.ImageInfo{img("help2", 24*time.Hour), img("help1", 48*time.Hour)},
		}
		cfg := testConfig(t, w)
		d := w.deps()
		d.HistoryPath = hist
		if _, err := NewRunner(cfg, d).RunOnce(false, true); err != nil {
			t.Fatal(err)
		}
		return w
	}
	// First sight: nothing deleted — the grace clock starts.
	if w := run(now); len(w.deletedImages) != 0 {
		t.Fatalf("first orphan sighting must delete nothing, got %v", w.deletedImages)
	}
	// 49h later, via a brand-new Runner over the same state dir (the
	// systemd oneshot case): the older generation goes, newest stays.
	if w := run(now.Add(49 * time.Hour)); len(w.deletedImages) != 1 || w.deletedImages[0] != "help1" {
		t.Fatalf("expired orphan must delete only help1, got %v", w.deletedImages)
	}
}

func TestRunnerAgentCaches(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	cfg := testConfig(t, w)
	cacheDir := filepath.Join(t.TempDir(), ".npm", "_cacache")
	cfg.AgentCacheDirs = []string{cacheDir}
	oldFile := filepath.Join(cacheDir, "content-v2", "old.bin")
	freshFile := filepath.Join(cacheDir, "index-v5", "fresh.bin")
	writeFile(t, oldFile, 500, now.Add(-2*time.Hour))
	writeFile(t, freshFile, 500, now.Add(-5*time.Minute))
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(oldFile); !os.IsNotExist(err) {
		t.Error("a cache file older than the min age must be purged")
	}
	if _, err := os.Stat(freshFile); err != nil {
		t.Error("a cache file inside the min age must survive (an install may be reading it)")
	}
	if info, err := os.Stat(cacheDir); err != nil || !info.IsDir() {
		t.Error("the cache root itself must survive — only its contents are purged")
	}
	if _, err := os.Stat(filepath.Join(cacheDir, "content-v2")); !os.IsNotExist(err) {
		t.Error("a subdirectory the purge emptied must be removed")
	}
	for _, c := range sum.Categories {
		if c.Category == CategoryAgentCaches && (c.ItemsRemoved != 1 || c.BytesReclaimed != 500) {
			t.Errorf("agent-caches result=%+v, want 1 item / 500 bytes", c)
		}
	}
}

func TestRunnerAgentCachesRefusesSymlink(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	cfg := testConfig(t, w)
	target := filepath.Join(t.TempDir(), "real-cache")
	writeFile(t, filepath.Join(target, "keep.bin"), 100, now.Add(-72*time.Hour))
	link := filepath.Join(t.TempDir(), ".cache", "deno")
	if err := os.MkdirAll(filepath.Dir(link), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	cfg.AgentCacheDirs = []string{link}
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(target, "keep.bin")); err != nil {
		t.Error("a symlinked cache dir must never be followed into its target")
	}
	for _, c := range sum.Categories {
		if c.Category == CategoryAgentCaches && !strings.Contains(c.Error, "symlink") {
			t.Errorf("the symlink refusal must be surfaced, got %+v", c)
		}
	}
}

func TestRunnerVolumeWatchAlertsAndDeletesNothing(t *testing.T) {
	now := time.Date(2026, 11, 21, 18, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	cfg := testConfig(t, w)
	cfg.DockerVolumesDir = filepath.Join(t.TempDir(), "volumes")
	cfg.VolumeWatchThresholdBytes = 100
	big := filepath.Join(cfg.DockerVolumesDir, "st-prod-app-data", "_data", ".backup-repair-20261121", "snapshot.db")
	writeFile(t, big, 500, now.Add(-time.Hour))
	old := filepath.Join(cfg.DockerVolumesDir, "st-prod-app-data", "_data", "app.db")
	writeFile(t, old, 500, now.Add(-72*time.Hour))
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(sum.Alerts) != 1 || sum.Alerts[0].Path != big {
		t.Fatalf("alerts=%v, want exactly the new snapshot file", sum.Alerts)
	}
	if _, err := os.Stat(big); err != nil {
		t.Error("the watch must never delete: the snapshot file must survive the run")
	}
	foundWatch := false
	for _, a := range w.audits {
		if strings.HasPrefix(a, "autoclean-watch:") {
			foundWatch = true
		}
	}
	if !foundWatch {
		t.Error("a watch finding must be audit-logged")
	}
	// An alert alone (nothing reclaimed by any category in this
	// fixture beyond docker fakes...) — the docker fakes reclaim, so
	// just assert the record carries the alert.
	recs, err := ReadHistory(d.HistoryPath)
	if err != nil || len(recs) == 0 {
		t.Fatalf("history=%v err=%v", recs, err)
	}
	if len(recs[0].Alerts) != 1 {
		t.Errorf("the history record must carry the alert: %+v", recs[0])
	}
}

func TestRunnerBackupsRetentionLine(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	cfg := testConfig(t, w)
	old := now.Add(-72 * time.Hour)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "a.db"), 500, old)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "a.db.sha256"), 10, old)
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "b.db"), 700, now.Add(-time.Hour))
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "um", "b.db.sha256"), 10, now.Add(-time.Hour))
	writeFile(t, filepath.Join(cfg.BackupDirs[0], "notes.txt"), 50, old)
	d := w.deps()
	// The fake DirSize reports the journal size for every path; use
	// the real walker for this test.
	d.DirSize = dirSize
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(sum.BackupsRetention) != 1 {
		t.Fatalf("retention lines=%v, want 1", sum.BackupsRetention)
	}
	line := sum.BackupsRetention[0]
	// a.db is superseded and deleted by the run; the retention line is
	// measured after the categories, so it reflects what remains:
	// b.db (700) + its sidecar (10) + notes.txt (50) total, 710 in
	// 1 dump (sidecars count toward the dump's bytes).
	if line.TotalBytes != 760 || line.DumpBytes != 710 || line.Dumps != 1 {
		t.Errorf("retention line=%+v, want total=760 dump=710 dumps=1", line)
	}
	recs, err := ReadHistory(d.HistoryPath)
	if err != nil || len(recs) == 0 {
		t.Fatalf("history=%v err=%v", recs, err)
	}
	if recs[0].BackupsRetentionBytes != 760 {
		t.Errorf("history retention total=%d, want 760", recs[0].BackupsRetentionBytes)
	}
}

func TestReadHistoryToleratesOversizedLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	big := CleanupHistoryRecord{
		CleanedAt:      time.Date(2026, 11, 7, 0, 0, 0, 0, time.UTC),
		BytesReclaimed: 7,
		ItemsRemoved:   1,
		Tier:           "automatic",
		Categories: []CategoryResult{{
			Category:     CategoryStaleTmp,
			ItemsRemoved: 1,
			Items:        []string{strings.Repeat("x", 5<<20)},
		}},
	}
	if err := AppendHistory(path, big); err != nil {
		t.Fatal(err)
	}
	small := CleanupHistoryRecord{
		CleanedAt:      time.Date(2026, 11, 7, 1, 0, 0, 0, time.UTC),
		BytesReclaimed: 9,
		Tier:           "automatic",
	}
	if err := AppendHistory(path, small); err != nil {
		t.Fatal(err)
	}
	recs, err := ReadHistory(path)
	if err != nil {
		t.Fatalf("an oversized line must not break ReadHistory: %v", err)
	}
	if len(recs) != 2 || recs[0].BytesReclaimed != 9 || recs[1].BytesReclaimed != 7 {
		t.Fatalf("recs=%v", recs)
	}
}

func TestLoopZeroIntervalDoesNotPanic(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	cfg := testConfig(t, w)
	cfg.CheckInterval = 0 // a zero-value config with Enabled on must not panic NewTicker
	r := NewRunner(cfg, w.deps())
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.Loop(ctx); close(done) }()
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("loop must return when its context is cancelled")
	}
}

func TestLoopRefusesToStartInContainer(t *testing.T) {
	marker := filepath.Join(t.TempDir(), ".dockerenv")
	if err := os.WriteFile(marker, []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	old := containerMarkerPaths
	containerMarkerPaths = []string{marker}
	defer func() { containerMarkerPaths = old }()
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	r := NewRunner(testConfig(t, w), w.deps())
	done := make(chan struct{})
	go func() { r.Loop(context.Background()); close(done) }()
	select {
	case <-done:
		// Returned promptly despite the live context: the guard fired.
	case <-time.After(2 * time.Second):
		t.Fatal("loop must refuse to start inside a container")
	}
	if len(w.pruned) != 0 {
		t.Error("a container-refused loop must not prune anything")
	}
}

func TestRunnerBackupsPlannedPerRoot(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	cfg := testConfig(t, w)
	rootA := filepath.Join(t.TempDir(), "backups")
	rootB := filepath.Join(t.TempDir(), "backups")
	old := now.Add(-72 * time.Hour)
	// Root A: two generations of app "um" — the older is superseded.
	writeFile(t, filepath.Join(rootA, "um", "a.db"), 500, old)
	writeFile(t, filepath.Join(rootA, "um", "a.db.sha256"), 10, old)
	writeFile(t, filepath.Join(rootA, "um", "b.db"), 500, now.Add(-time.Hour))
	writeFile(t, filepath.Join(rootA, "um", "b.db.sha256"), 10, now.Add(-time.Hour))
	// Root B: the same app name, but its only dump.  Planning across
	// roots would delete it because root A's b.db is newer.
	writeFile(t, filepath.Join(rootB, "um", "only.db"), 500, old)
	writeFile(t, filepath.Join(rootB, "um", "only.db.sha256"), 10, old)
	// An invalid root first in the list must not abort the others.
	cfg.BackupDirs = []string{"/etc", rootA, rootB}
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(rootA, "um", "a.db")); !os.IsNotExist(err) {
		t.Error("root A's superseded dump must be removed")
	}
	if _, err := os.Stat(filepath.Join(rootB, "um", "only.db")); err != nil {
		t.Errorf("root B's only dump must survive per-root planning: %v", err)
	}
	for _, c := range sum.Categories {
		if c.Category == CategoryBackups && c.Error == "" {
			t.Error("the refused /etc root must be surfaced in the category error")
		}
	}
}

func TestRunnerTmpRemovalFailureDoesNotAbortSweep(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:   now,
	}
	cfg := testConfig(t, w)
	stale := now.Add(-8 * 24 * time.Hour)
	bad := filepath.Join(cfg.TmpDirs[0], "a-bad.log")
	good := filepath.Join(cfg.TmpDirs[0], "b-good.log")
	writeFile(t, bad, 100, stale)
	writeFile(t, good, 100, stale)
	d := w.deps()
	realRemove := d.Remove
	d.Remove = func(p string) error {
		if p == bad {
			return errors.New("permission denied")
		}
		return realRemove(p)
	}
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(good); !os.IsNotExist(err) {
		t.Error("the removable stale file must still be removed after a sibling failure")
	}
	for _, c := range sum.Categories {
		if c.Category == CategoryStaleTmp {
			if c.ItemsRemoved != 1 {
				t.Errorf("stale-tmp ItemsRemoved=%d, want 1", c.ItemsRemoved)
			}
			if c.Error == "" {
				t.Error("the failed removal must be recorded in the category error")
			}
		}
	}
}

func TestRunnerJournalNoShrinkReportsZero(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage:     DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:       now,
		journalSz: 3 << 30,
	}
	cfg := testConfig(t, w)
	d := w.deps()
	d.Vacuum = func(uint64) error { return nil } // succeeds, frees nothing
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	sum, err := r.RunOnce(false, true)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range sum.Categories {
		if c.Category == CategoryJournal && c.BytesReclaimed != 0 {
			t.Errorf("journal BytesReclaimed=%d, want measured 0 when nothing shrank", c.BytesReclaimed)
		}
	}
}

func TestRunnerDisabledCategorySkipped(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &fakeWorld{
		usage:     DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
		now:       now,
		journalSz: 3 << 30,
	}
	cfg := testConfig(t, w)
	cfg.Categories = map[string]bool{CategoryJournal: false}
	d := w.deps()
	d.HistoryPath = filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	r := NewRunner(cfg, d)
	if _, err := r.RunOnce(false, true); err != nil {
		t.Fatal(err)
	}
	if w.vacuumed {
		t.Error("a disabled journal category must not vacuum")
	}
}

func TestHistoryRoundTripSkipsCorruptLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cleanup-history.jsonl")
	rec := CleanupHistoryRecord{
		CleanedAt:      time.Date(2026, 11, 7, 0, 0, 0, 0, time.UTC),
		BytesReclaimed: 42,
		ItemsRemoved:   2,
		Tier:           "automatic",
		CategoryIDs:    []string{CategoryBackups},
		ItemTitles:     []string{"/backups/um/a.db"},
	}
	if err := AppendHistory(path, rec); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(mustRead(t, path), []byte("{corrupt\n")...), 0600); err != nil {
		t.Fatal(err)
	}
	recs, err := ReadHistory(path)
	if err != nil || len(recs) != 1 || recs[0].BytesReclaimed != 42 {
		t.Fatalf("recs=%v err=%v", recs, err)
	}
	if recs, err := ReadHistory(filepath.Join(t.TempDir(), "missing.jsonl")); err != nil || recs != nil {
		t.Fatalf("missing history must read empty: recs=%v err=%v", recs, err)
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
