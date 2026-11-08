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
	for _, bad := range []string{"/", "/var/lib/docker", "/var/lib/docker/volumes", "/mnt/fleet-extra/apps/lanes/x", "/home/u/.git"} {
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
		{Path: "/tmp/old.log", ModTime: old},                                  // delete
		{Path: "/tmp/young.log", ModTime: young},                              // too young
		{Path: "/tmp/open.log", ModTime: old, Open: true},                     // open
		{Path: "/tmp/link", ModTime: old, Symlink: true},                      // symlink
		{Path: "/tmp/dir", ModTime: old, IsDir: true},                         // directory
		{Path: filepath.Join("/var/tmp", "stale.bin"), ModTime: old, Size: 5}, // delete
	}
	got := SelectStaleTmp(entries, now, 7*24*time.Hour)
	if len(got) != 2 || got[0] != "/tmp/old.log" || got[1] != "/var/tmp/stale.bin" {
		t.Fatalf("SelectStaleTmp=%v", got)
	}
	// Exactly at the age floor counts as stale.
	edge := []TmpEntry{{Path: "/tmp/edge", ModTime: now.Add(-7 * 24 * time.Hour)}}
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
