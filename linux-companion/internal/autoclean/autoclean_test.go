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

func TestEmergencyThresholds(t *testing.T) {
	cfg := DefaultConfig()
	cases := []struct {
		name string
		u    DiskUsage
		want bool
	}{
		{"at emergency percent", DiskUsage{TotalBytes: 100, UsedPercent: 90, FreeBytes: 50}, true},
		{"over emergency percent", DiskUsage{TotalBytes: 100, UsedPercent: 93, FreeBytes: 8}, true},
		{"triggered but not emergency", DiskUsage{TotalBytes: 300 << 30, UsedPercent: 85, FreeBytes: 40 << 30}, false},
		{"emergency free floor alone", DiskUsage{TotalBytes: 300 << 30, UsedPercent: 85, FreeBytes: 15 << 30}, true},
		{"free exactly at emergency floor", DiskUsage{TotalBytes: 300 << 30, UsedPercent: 85, FreeBytes: 16 << 30}, false},
		{"empty disk", DiskUsage{}, false},
	}
	for _, c := range cases {
		if got := cfg.Emergency(c.u); got != c.want {
			t.Errorf("%s: Emergency=%v, want %v", c.name, got, c.want)
		}
	}
}

func TestDefaultConfigJournalAndEmergency(t *testing.T) {
	cfg := DefaultConfig()
	if cfg.JournalTargetBytes != 200<<20 || cfg.JournalFloorBytes != 100<<20 {
		t.Errorf("journal target/floor = %d/%d, want 200MiB/100MiB", cfg.JournalTargetBytes, cfg.JournalFloorBytes)
	}
	if cfg.EmergencyUsedPercent != 90 || cfg.EmergencyMinFreeBytes != 16<<30 {
		t.Errorf("emergency line = %v%%/%d, want 90%%/16GiB", cfg.EmergencyUsedPercent, cfg.EmergencyMinFreeBytes)
	}
	if cfg.ImageKeepPerRepo != 2 {
		t.Errorf("ImageKeepPerRepo=%d, want 2 (current + previous)", cfg.ImageKeepPerRepo)
	}
	if cfg.VolumeWatchThresholdBytes != 5<<30 {
		t.Errorf("VolumeWatchThresholdBytes=%d, want 5GiB", cfg.VolumeWatchThresholdBytes)
	}
	dirs := cfg.AgentCacheDirList()
	if len(dirs) != 5 || dirs[0] != "/home/jay/.npm/_cacache" || dirs[4] != "/home/jay/.cache/node" {
		t.Errorf("default agent cache dirs=%v", dirs)
	}
}

func TestImageRepoTag(t *testing.T) {
	if repo, tag, ok := ImageRepoTag("yagelvqux9e8l1kztif7bf2o:e2ff91c5"); !ok || repo != "yagelvqux9e8l1kztif7bf2o" || tag != "e2ff91c5" {
		t.Errorf("plain ref: %q %q %v", repo, tag, ok)
	}
	if repo, tag, ok := ImageRepoTag("localhost:5000/app:v1"); !ok || repo != "localhost:5000/app" || tag != "v1" {
		t.Errorf("registry port must not split as a tag: %q %q %v", repo, tag, ok)
	}
	if _, _, ok := ImageRepoTag("app@sha256:deadbeef"); ok {
		t.Error("digest reference must not parse as a tag")
	}
	if _, _, ok := ImageRepoTag("app"); ok {
		t.Error("untagged reference must not parse")
	}
	if _, _, ok := ImageRepoTag(""); ok {
		t.Error("empty reference must not parse")
	}
}

func TestPlanUnusedImages(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	gen := func(id, repo string, age time.Duration) DeployImage {
		return DeployImage{ID: id, Repo: repo, Tag: id, Created: now.Add(-age), Size: 100}
	}
	images := []DeployImage{
		// Live app "um": four generations; the newest is container-used.
		gen("um4", "um", time.Hour),
		gen("um3", "um", 2*time.Hour),
		gen("um2", "um", 3*time.Hour),
		gen("um1", "um", 4*time.Hour),
		// Live app "ct": its OLDEST generation is still referenced by a
		// stopped container — protected despite sitting beyond keep.
		gen("ct3", "ct", time.Hour),
		gen("ct2", "ct", 2*time.Hour),
		gen("ct1", "ct", 3*time.Hour),
		// Orphan helper: two generations, no containers at all.
		gen("help2", "coollabsio/coolify-helper", 24*time.Hour),
		gen("help1", "coollabsio/coolify-helper", 48*time.Hour),
		// Orphan app with FOUR generations: inside its grace it must
		// lose nothing at any index — not even the generations beyond
		// keep, which a live group would lose on sight.
		gen("gone4", "gone", time.Hour),
		gen("gone3", "gone", 2*time.Hour),
		gen("gone2", "gone", 3*time.Hour),
		gen("gone1", "gone", 4*time.Hour),
		// Untagged: never the planner's business.
		{ID: "dangling", Repo: "", Created: now.Add(-72 * time.Hour)},
	}
	used := map[string]bool{"um4": true, "ct1": true}

	// First sight of the orphan group: only beyond-keep generations of
	// live groups go (um2, um1).  The helper's older generation stays —
	// its grace clock starts now.
	del, next := PlanUnusedImages(images, used, 2, map[string]time.Time{}, now, 48*time.Hour)
	gotIDs := map[string]bool{}
	for _, d := range del {
		gotIDs[d.ID] = true
	}
	for _, want := range []string{"um2", "um1"} {
		if !gotIDs[want] {
			t.Errorf("first pass must delete %s, got %v", want, del)
		}
	}
	for _, notWant := range []string{"um4", "um3", "ct3", "ct2", "ct1", "help2", "help1", "dangling",
		"gone4", "gone3", "gone2", "gone1"} {
		if gotIDs[notWant] {
			t.Errorf("first pass must keep %s, got %v", notWant, del)
		}
	}
	if since, ok := next["coollabsio/coolify-helper"]; !ok || !since.Equal(now) {
		t.Errorf("orphan clock must start at first sight: %v", next)
	}
	if _, ok := next["um"]; ok {
		t.Error("a live group must not carry an orphan clock")
	}

	// 49 hours later, still unreferenced: the helper's older generation
	// goes; its newest stays.  The four-generation orphan app loses
	// everything but its newest.  The clock keeps its original start.
	later := now.Add(49 * time.Hour)
	del, next = PlanUnusedImages(images, used, 2, next, later, 48*time.Hour)
	gotIDs = map[string]bool{}
	for _, d := range del {
		gotIDs[d.ID] = true
	}
	if !gotIDs["help1"] || gotIDs["help2"] {
		t.Errorf("expired orphan pass must delete only help1, got %v", del)
	}
	for _, want := range []string{"gone3", "gone2", "gone1"} {
		if !gotIDs[want] {
			t.Errorf("expired orphan pass must delete %s, got %v", want, del)
		}
	}
	if gotIDs["gone4"] {
		t.Errorf("an orphan group always keeps its newest generation, got %v", del)
	}
	if since := next["coollabsio/coolify-helper"]; !since.Equal(now) {
		t.Errorf("orphan clock must keep its first-sight start, got %v", since)
	}

	// The group gains a container again: the clock is dropped, so a
	// later orphanhood starts a fresh grace.
	used["help1"] = true
	_, next = PlanUnusedImages(images, used, 2, next, later, 48*time.Hour)
	if _, ok := next["coollabsio/coolify-helper"]; ok {
		t.Error("a group with a container again must drop its orphan clock")
	}
}

func TestValidateAgentCacheDir(t *testing.T) {
	for _, bad := range []string{"/", "/home/jay", "/home/jay/.claude", "/home/jay/Code/app",
		"/home/jay/.cache", "/home/jay/.npm", "/home/jay/.npm/_logs",
		"/etc/.cache/x", "/var/lib/docker/volumes", "/home/jay/apps/lanes/x/.cache", "relative/.cache"} {
		if ok, _ := ValidateAgentCacheDir(bad); ok {
			t.Errorf("ValidateAgentCacheDir(%q) must refuse", bad)
		}
	}
	for _, good := range []string{"/home/jay/.npm/_cacache", "/home/jay/.npm/_npx",
		"/home/jay/.cache/deno", "/home/jay/.cache/pnpm", "/home/jay/.cache/node"} {
		if ok, reason := ValidateAgentCacheDir(good); !ok {
			t.Errorf("ValidateAgentCacheDir(%q) refused: %s", good, reason)
		}
	}
}

func TestFindLargeNewFiles(t *testing.T) {
	now := time.Date(2026, 11, 21, 18, 0, 0, 0, time.UTC)
	entries := []VolumeFileEntry{
		{Volume: "st-data", Path: "/v/st-data/_data/.backup-repair/snapshot.db", Size: 21 << 30, ModTime: now.Add(-time.Hour), Regular: true}, // finding
		{Volume: "st-data", Path: "/v/st-data/_data/app.db", Size: 23 << 30, ModTime: now.Add(-30 * 24 * time.Hour), Regular: true},           // large but old
		{Volume: "um-data", Path: "/v/um-data/_data/new.bin", Size: 6 << 30, ModTime: now.Add(-2 * time.Hour), Regular: true},                 // finding
		{Volume: "um-data", Path: "/v/um-data/_data/small.bin", Size: 1 << 30, ModTime: now.Add(-time.Hour), Regular: true},                   // new but small
		{Volume: "um-data", Path: "/v/um-data/_data/link", Size: 9 << 30, ModTime: now.Add(-time.Hour), Symlink: true},                        // symlink
		{Volume: "um-data", Path: "/v/um-data/_data/skew.bin", Size: 9 << 30, ModTime: now.Add(time.Hour), Regular: true},                     // future mtime counts as new
	}
	got := FindLargeNewFiles(entries, 5<<30, 24*time.Hour, now, 20)
	if len(got) != 3 {
		t.Fatalf("findings=%v, want 3", got)
	}
	// Largest first.
	if got[0].Size != 21<<30 || got[1].Size != 9<<30 || got[2].Size != 6<<30 {
		t.Fatalf("findings must sort largest first: %v", got)
	}
	if got[0].Volume != "st-data" {
		t.Errorf("finding must name its volume: %+v", got[0])
	}
	// The clock-skewed file (9 GiB, future mtime) is a finding, but its
	// recorded age is clamped to 0, never negative.
	if got[1].AgeSeconds != 0 {
		t.Errorf("future-mtime finding AgeSeconds=%d, want 0 (clamped)", got[1].AgeSeconds)
	}
	// The cap holds.
	if capped := FindLargeNewFiles(entries, 5<<30, 24*time.Hour, now, 2); len(capped) != 2 {
		t.Errorf("cap: got %d findings, want 2", len(capped))
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
