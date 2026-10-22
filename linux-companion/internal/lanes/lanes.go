// Package lanes scans fleet lane checkouts and reports which ones have
// changes not in GitHub — dirty trees or unpushed commits — in the shared
// schema defined by linux-companion/SPEC.md §9.  Read-only git commands
// only.  Implemented.
package lanes

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Verdicts for a lane.
const (
	VerdictClean      = "clean"
	VerdictDirty      = "dirty"
	VerdictUnpushed   = "unpushed"
	VerdictDiverged   = "diverged"
	VerdictNoUpstream = "no-upstream"
	VerdictError      = "error"
)

// Lane is one checkout's drift status.
type Lane struct {
	Path          string   `json:"path"`
	Repo          string   `json:"repo"`
	Branch        string   `json:"branch"`
	Upstream      *string  `json:"upstream"`
	Dirty         bool     `json:"dirty"`
	DirtyFileCount int     `json:"dirty_file_count"`
	DirtyPaths    []string `json:"dirty_paths"`
	Ahead         int      `json:"ahead"`
	Behind        int      `json:"behind"`
	LastCommitAt  *string  `json:"last_commit_at"`
	Verdict       string   `json:"verdict"`
	Error         string   `json:"error,omitempty"`
	ScannedAt     string   `json:"scanned_at"`
}

func git(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	// Read-only by construction: callers only ever pass rev-parse,
	// status, rev-list, log.  Belt and braces: block anything else.
	for _, a := range args {
		if a == "fetch" || a == "pull" || a == "push" || a == "reset" || a == "checkout" {
			return "", errMutating("refusing mutating git command")
		}
	}
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

type mutatingErr string

func (e mutatingErr) Error() string { return string(e) }
func errMutating(s string) error    { return mutatingErr(s) }

func scanOne(path string) Lane {
	now := time.Now().UTC().Format(time.RFC3339)
	lane := Lane{
		Path:       path,
		Repo:       filepath.Base(path),
		DirtyPaths: []string{},
		ScannedAt:  now,
		Verdict:    VerdictError,
	}
	fail := func(reason string) Lane {
		lane.Error = reason
		lane.Verdict = VerdictError
		return lane
	}

	branch, err := git(path, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		// Empty repo (no commits yet): still a lane, just unreadable state.
		if out, e2 := git(path, "rev-parse", "--is-inside-work-tree"); e2 == nil && out == "true" {
			lane.Branch = "(no commits)"
			lane.Verdict = VerdictClean
			lane.Error = ""
			return lane
		}
		return fail("rev-parse HEAD: " + err.Error())
	}
	if branch == "HEAD" {
		if sha, err := git(path, "rev-parse", "--short", "HEAD"); err == nil {
			branch = "DETACHED@" + sha
		}
	}
	lane.Branch = branch

	upstream, err := git(path, "rev-parse", "--abbrev-ref", "@{u}")
	if err != nil {
		lane.Verdict = VerdictNoUpstream
	} else {
		lane.Upstream = &upstream
		if ahead, err := git(path, "rev-list", "--count", "@{u}..HEAD"); err == nil {
			//nolint:errcheck — count parse failure leaves zero, which is safe.
			lane.Ahead = atoi(ahead)
		}
		if behind, err := git(path, "rev-list", "--count", "HEAD..@{u}"); err == nil {
			lane.Behind = atoi(behind)
		}
	}

	if out, err := git(path, "log", "-1", "--format=%cI"); err == nil && out != "" {
		lane.LastCommitAt = &out
	}

	porcelain, err := git(path, "status", "--porcelain=v1")
	if err != nil {
		return fail("status: " + err.Error())
	}
	if porcelain != "" {
		lines := strings.Split(porcelain, "\n")
		lane.Dirty = true
		lane.DirtyFileCount = len(lines)
		for i, line := range lines {
			if i >= 10 {
				break
			}
			if len(line) > 3 {
				lane.DirtyPaths = append(lane.DirtyPaths, strings.TrimSpace(line[3:]))
			}
		}
	}

	switch {
	case lane.Dirty:
		lane.Verdict = VerdictDirty
	case lane.Upstream == nil:
		lane.Verdict = VerdictNoUpstream
	case lane.Ahead > 0 && lane.Behind > 0:
		lane.Verdict = VerdictDiverged
	case lane.Ahead > 0:
		lane.Verdict = VerdictUnpushed
	default:
		lane.Verdict = VerdictClean
	}
	return lane
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// isLane reports whether dir is a git checkout: .git as a directory
// (full clone) or as a file (worktree pointer).
func isLane(dir string) bool {
	fi, err := os.Stat(filepath.Join(dir, ".git"))
	return err == nil && (fi.IsDir() || fi.Mode().IsRegular())
}

// Scan walks each root's immediate children and scans lanes in parallel.
func Scan(roots []string) []Lane {
	var dirs []string
	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			full := filepath.Join(root, e.Name())
			if isLane(full) {
				dirs = append(dirs, full)
			}
		}
	}
	out := make([]Lane, len(dirs))
	sem := make(chan struct{}, 8) // bounded worker pool
	var wg sync.WaitGroup
	for i, d := range dirs {
		wg.Add(1)
		go func(i int, d string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			done := make(chan Lane, 1)
			go func() { done <- scanOne(d) }()
			select {
			case lane := <-done:
				out[i] = lane
			case <-time.After(10 * time.Second):
				out[i] = Lane{Path: d, Repo: filepath.Base(d), Verdict: VerdictError,
					Error: "scan timed out", ScannedAt: time.Now().UTC().Format(time.RFC3339)}
			}
		}(i, d)
	}
	wg.Wait()
	return out
}
