package autoclean

import (
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
}

func (w *fakeWorld) deps() Deps {
	return Deps{
		Stat: func(string) (DiskUsage, error) { return w.usage, nil },
		Prune: func(target string, all bool) (docker.PruneResult, error) {
			w.pruned = append(w.pruned, target)
			w.pruneAll = append(w.pruneAll, all)
			return docker.PruneResult{ReclaimedBytes: 1000}, nil
		},
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
	// Docker: build cache and dangling images, both dangling-only.
	if len(w.pruned) != 2 || w.pruned[0] != "build-cache" || w.pruned[1] != "images" {
		t.Fatalf("pruned=%v, want [build-cache images]", w.pruned)
	}
	for _, all := range w.pruneAll {
		if all {
			t.Fatal("autoclean must never prune with all=true (dangling only)")
		}
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
	goneOld := filepath.Join(cfg.BackupDirs[0], "um", "a.db")
	goneStale := filepath.Join(cfg.TmpDirs[0], "stale.log")
	for _, p := range []string{goneOld, goneOld + ".sha256", goneStale} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s must be removed", p)
		}
	}
	// Journal vacuumed to the 500MiB target, above the floor.
	if !w.vacuumed || w.vacuumTo != 500<<20 {
		t.Errorf("vacuumed=%v to=%d, want 500MiB", w.vacuumed, w.vacuumTo)
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
	w := &fakeWorld{
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
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
		usage: DiskUsage{TotalBytes: 300 << 30, UsedBytes: 276 << 30, FreeBytes: 24 << 30, UsedPercent: 92},
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
