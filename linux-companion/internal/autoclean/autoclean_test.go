package autoclean

import (
	"path/filepath"
	"testing"
	"time"
)

func TestShouldRunThresholds(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.MinFreeBytes = 10 // raw units, to match the small fixtures below
	cases := []struct {
		name string
		u    DiskUsage
		want bool
	}{
		{"under both", DiskUsage{TotalBytes: 100, UsedBytes: 79, FreeBytes: 40, UsedPercent: 79}, false},
		{"at percent line", DiskUsage{TotalBytes: 100, UsedBytes: 80, FreeBytes: 40, UsedPercent: 80}, true},
		{"over percent", DiskUsage{TotalBytes: 100, UsedBytes: 92, FreeBytes: 8, UsedPercent: 92}, true},
		{"free floor alone", DiskUsage{TotalBytes: 1000, UsedBytes: 500, FreeBytes: 5, UsedPercent: 50}, true},
		{"free exactly at floor", DiskUsage{TotalBytes: 1000, UsedBytes: 500, FreeBytes: 10, UsedPercent: 50}, false},
		{"empty disk", DiskUsage{}, false},
	}
	for _, c := range cases {
		if got := cfg.ShouldRun(c.u); got != c.want {
			t.Errorf("%s: ShouldRun=%v, want %v", c.name, got, c.want)
		}
	}
	// Free-floor trigger with realistic byte counts.
	small := DefaultConfig()
	small.Enabled = true
	small.MinFreeBytes = 30 << 30
	u := DiskUsage{TotalBytes: 300 << 30, UsedBytes: 150 << 30, FreeBytes: 25 << 30, UsedPercent: 50}
	if !small.ShouldRun(u) {
		t.Error("free under the 30GiB floor must trigger even at 50% used")
	}
	u.FreeBytes = 30 << 30
	if small.ShouldRun(u) {
		t.Error("free exactly at the floor must not trigger on the free rule")
	}
	// Disabled never runs, however full the disk is.
	off := DefaultConfig()
	full := DiskUsage{TotalBytes: 100, UsedBytes: 99, FreeBytes: 1, UsedPercent: 99}
	if off.ShouldRun(full) {
		t.Error("disabled config must never trigger")
	}
}

func TestUsageFromStatfsMatchesDf(t *testing.T) {
	// Every expectation below is the `df` Use% for the same statfs
	// counts, worked out by hand from df's formula:
	// used = blocks - bfree; avail = bavail;
	// pct = ceil(100 * used / (used + avail)).
	// The cases with bfree != bavail are the reserved-blocks cases: the
	// old code divided used by the total block count instead, which
	// understates usage by roughly the reserve fraction.
	const bsize = 4096
	cases := []struct {
		name         string
		blocks       uint64
		bfree        uint64
		bavail       uint64
		wantPercent  float64
		wantUsed     uint64 // in blocks
		wantFreeByte uint64 // bavail * bsize
	}{
		// The live Coolify-host shape: used/total is exactly 77.3%, so
		// the old calculation sat under the 80% trigger, while df's
		// 773000/(773000+190000) = 80.27% rounds up to 81% and fires.
		{"host reserved blocks", 1_000_000, 227_000, 190_000, 81, 773_000, 190_000 * bsize},
		// A textbook 5% ext4 reserve: 1500/(1500+400) = 78.95% -> 79,
		// where used/total would read 75%.
		{"five percent reserve", 2000, 500, 400, 79, 1500, 400 * bsize},
		// No reserve at all: bfree == bavail, denominator is the total.
		{"no reserve exact", 1000, 200, 200, 80, 800, 200 * bsize},
		// No reserve, fractional: df rounds 79.1% up to 80.
		{"no reserve rounds up", 1000, 209, 209, 80, 791, 209 * bsize},
		// Empty filesystem with a reserve: nothing used, 0%.
		{"empty with reserve", 1000, 1000, 950, 0, 0, 950 * bsize},
		// Only reserved blocks remain free: avail is 0, so df reads
		// 100% even though bfree is not 0.
		{"only reserve free", 1000, 50, 0, 100, 950, 0},
		// Degenerate zero-block filesystem: 0, never NaN.
		{"zero blocks", 0, 0, 0, 0, 0, 0},
	}
	for _, c := range cases {
		u := usageFromStatfs("/", c.blocks, c.bfree, c.bavail, bsize)
		if u.UsedPercent != c.wantPercent {
			t.Errorf("%s: UsedPercent=%v, want df value %v", c.name, u.UsedPercent, c.wantPercent)
		}
		if u.UsedBytes != c.wantUsed*bsize {
			t.Errorf("%s: UsedBytes=%d, want %d", c.name, u.UsedBytes, c.wantUsed*bsize)
		}
		if u.FreeBytes != c.wantFreeByte {
			t.Errorf("%s: FreeBytes=%d, want %d (bavail, not bfree)", c.name, u.FreeBytes, c.wantFreeByte)
		}
		if u.TotalBytes != c.blocks*bsize {
			t.Errorf("%s: TotalBytes=%d, want %d", c.name, u.TotalBytes, c.blocks*bsize)
		}
	}
	// The host-shaped measurement must cross the default 80% trigger on
	// the percent rule alone: this is the regression the fix exists for.
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.MinFreeBytes = 0 // isolate the percent rule from the free floor
	u := usageFromStatfs("/", 1_000_000, 227_000, 190_000, bsize)
	if !cfg.ShouldRun(u) {
		t.Errorf("df 81%% measurement must trigger at the 80%% line, got %v%%", u.UsedPercent)
	}
}

func TestDfUsedPercent(t *testing.T) {
	if got := dfUsedPercent(0, 0); got != 0 {
		t.Errorf("dfUsedPercent(0,0)=%v, want 0", got)
	}
	if got := dfUsedPercent(1, 3); got != 25 {
		t.Errorf("dfUsedPercent(1,3)=%v, want 25", got)
	}
	// 1/3 is 33.33..%: df rounds up to 34.
	if got := dfUsedPercent(1, 2); got != 34 {
		t.Errorf("dfUsedPercent(1,2)=%v, want 34 (ceil)", got)
	}
}

func TestConfigFromEnv(t *testing.T) {
	t.Setenv("HH_AGENT_AUTOCLEAN", "1")
	t.Setenv("HH_AGENT_AUTOCLEAN_USED_PCT", "85")
	t.Setenv("HH_AGENT_AUTOCLEAN_MIN_FREE_GB", "20")
	t.Setenv("HH_AGENT_AUTOCLEAN_DISABLE", "journal,stale-tmp")
	c := ConfigFromEnv()
	if !c.Enabled {
		t.Error("HH_AGENT_AUTOCLEAN=1 must enable")
	}
	if c.UsedPercentTrigger != 85 {
		t.Errorf("UsedPercentTrigger=%v, want 85", c.UsedPercentTrigger)
	}
	if c.MinFreeBytes != 20<<30 {
		t.Errorf("MinFreeBytes=%d, want %d", c.MinFreeBytes, 20<<30)
	}
	if c.CategoryEnabled(CategoryJournal) || c.CategoryEnabled(CategoryStaleTmp) {
		t.Error("disabled categories must report disabled")
	}
	if !c.CategoryEnabled(CategoryBuildCache) {
		t.Error("unlisted category must stay enabled")
	}
	// Garbage overrides are ignored, defaults survive.
	t.Setenv("HH_AGENT_AUTOCLEAN_USED_PCT", "banana")
	if got := ConfigFromEnv().UsedPercentTrigger; got != 80 {
		t.Errorf("garbage pct override must fall back to the 80 default, got %v", got)
	}
	// Backup dir lists are trimmed element by element, like DISABLE.
	t.Setenv("HH_AGENT_AUTOCLEAN_BACKUP_DIRS", "/backups, /mnt/fleet-extra/backups ,")
	dirs := ConfigFromEnv().BackupDirs
	if len(dirs) != 2 || dirs[0] != "/backups" || dirs[1] != "/mnt/fleet-extra/backups" {
		t.Errorf("BackupDirs=%q, want trimmed pair", dirs)
	}
}

func TestPlanBackupCleanupKeepsNewestCompletePerApp(t *testing.T) {
	old := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	mid := old.Add(24 * time.Hour)
	newest := old.Add(48 * time.Hour)
	dumps := []BackupDump{
		{App: "um", Path: "/backups/um/a.db", Size: 10, ModTime: old, Complete: true,
			Sidecars: []Sidecar{{Path: "/backups/um/a.db.sha256", Size: 1}}},
		{App: "um", Path: "/backups/um/b.db", Size: 10, ModTime: mid, Complete: true},
		{App: "um", Path: "/backups/um/c.db", Size: 10, ModTime: newest, Complete: true,
			Sidecars: []Sidecar{{Path: "/backups/um/c.db.sha256", Size: 1}}},
		// st has exactly one complete dump: its plan must be empty.
		{App: "st", Path: "/backups/st/only.db", Size: 10, ModTime: old, Complete: true},
		// ct has an in-flight newest dump and one complete: nothing goes.
		{App: "ct", Path: "/backups/ct/done.db", Size: 10, ModTime: old, Complete: true},
		{App: "ct", Path: "/backups/ct/writing.db", Size: 10, ModTime: newest, Complete: false},
		// solo has no complete dump at all: nothing goes.
		{App: "solo", Path: "/backups/solo/x.db", Size: 10, ModTime: old, Complete: false},
	}
	got := PlanBackupCleanup(dumps)
	want := []string{"/backups/um/a.db", "/backups/um/a.db.sha256", "/backups/um/b.db"}
	if len(got) != len(want) {
		t.Fatalf("plan=%v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("plan=%v, want %v", got, want)
		}
	}
}

func TestValidateBackupRoot(t *testing.T) {
	for _, bad := range []string{"/", "/var/lib/docker", "/var/lib/docker/volumes", "/mnt/fleet-extra/apps/lanes/x", "/home/u/.git",
		"/etc", "/usr/share/doc", "/opt/app/data", "/srv/data", "/var/www", "/var/lib/postgresql", "/var/lib/mysql/data",
		"/data", "relative/backups", "/mnt/fleet-extra/snapshots"} {
		if ok, _ := ValidateBackupRoot(bad); ok {
			t.Errorf("ValidateBackupRoot(%q) must refuse", bad)
		}
	}
	for _, good := range []string{"/backups", "/data/backups", "/mnt/fleet-extra/backups"} {
		if ok, reason := ValidateBackupRoot(good); !ok {
			t.Errorf("ValidateBackupRoot(%q) refused: %s", good, reason)
		}
	}
}

func TestSelectStaleTmp(t *testing.T) {
	now := time.Date(2026, 11, 7, 0, 0, 0, 0, time.UTC)
	old := now.Add(-8 * 24 * time.Hour)
	young := now.Add(-24 * time.Hour)
	entries := []TmpEntry{
		{Path: "/tmp/old.log", ModTime: old, Regular: true},                                  // delete
		{Path: "/tmp/young.log", ModTime: young, Regular: true},                              // too young
		{Path: "/tmp/open.log", ModTime: old, Open: true, Regular: true},                     // open
		{Path: "/tmp/link", ModTime: old, Symlink: true},                                     // symlink
		{Path: "/tmp/dir", ModTime: old, IsDir: true},                                        // directory
		{Path: "/tmp/tmux.sock", ModTime: old},                                               // socket: not regular, never delete
		{Path: "/tmp/daemon.fifo", ModTime: old},                                             // FIFO: not regular, never delete
		{Path: filepath.Join("/var/tmp", "stale.bin"), ModTime: old, Size: 5, Regular: true}, // delete
	}
	got := SelectStaleTmp(entries, now, 7*24*time.Hour)
	if len(got) != 2 || got[0] != "/tmp/old.log" || got[1] != "/var/tmp/stale.bin" {
		t.Fatalf("SelectStaleTmp=%v", got)
	}
	// Exactly at the age floor counts as stale.
	edge := []TmpEntry{{Path: "/tmp/edge", ModTime: now.Add(-7 * 24 * time.Hour), Regular: true}}
	if got := SelectStaleTmp(edge, now, 7*24*time.Hour); len(got) != 1 {
		t.Fatalf("edge age must be selected, got %v", got)
	}
}

func TestPlanJournalVacuum(t *testing.T) {
	const gb = 1 << 30
	if _, ok := PlanJournalVacuum(400<<20, 500<<20, 200<<20); ok {
		t.Error("journal under target must not vacuum")
	}
	to, ok := PlanJournalVacuum(3*gb, 500<<20, 200<<20)
	if !ok || to != 500<<20 {
		t.Errorf("vacuum=%d ok=%v, want 500MiB", to, ok)
	}
	// A target set below the floor is clamped up to the floor.
	to, ok = PlanJournalVacuum(3*gb, 100<<20, 200<<20)
	if !ok || to != 200<<20 {
		t.Errorf("floor clamp: vacuum=%d ok=%v, want 200MiB", to, ok)
	}
	// Floor at or over current size means nothing may be vacuumed.
	if _, ok := PlanJournalVacuum(150<<20, 500<<20, 200<<20); ok {
		t.Error("journal already under target size must not vacuum even with a floor")
	}
}

func TestDumpNameClassification(t *testing.T) {
	if !isDumpName("app-2026-11-07.db") || !isDumpName("dump.sql.gz") || !isDumpName("x.tar.zst") {
		t.Error("dump names must classify as dumps")
	}
	if isDumpName("app.db.sha256") || isDumpName("notes.txt") || isDumpName("config.json") {
		t.Error("sidecars and non-dump files must not classify as dumps")
	}
	if !isIncompleteName("app.db.partial") || isIncompleteName("app.db") {
		t.Error("incomplete suffix detection wrong")
	}
	if _, ok := isSidecarOf("app.db.sha256", "app.db"); !ok {
		t.Error("sha256 sidecar must be recognised")
	}
	if _, ok := isSidecarOf("other.db.sha256", "app.db"); ok {
		t.Error("another dump's sidecar must not attach")
	}
}
