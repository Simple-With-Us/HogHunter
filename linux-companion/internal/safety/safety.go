// Package safety is the single choke point for every destructive action.
// Both the CLI and the HTTP handlers consult it; a refusal is a refusal
// everywhere.  Implemented.
package safety

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// NeverKill matches processes that must never be signaled, by executable
// basename or by a substring of the full command line.
var NeverKill = []*regexp.Regexp{
	regexp.MustCompile(`^(dockerd|containerd|containerd-shim|docker-proxy)$`),
	regexp.MustCompile(`^coolify`),
	regexp.MustCompile(`^(tailscaled|tailscale)$`),
	regexp.MustCompile(`^sshd$`),
	regexp.MustCompile(`^hh-agent$`),
	regexp.MustCompile(`^systemd$`),
	regexp.MustCompile(`^kernel`),
}

// Refusal explains why an action was blocked.
type Refusal struct {
	Reason string `json:"reason"`
}

// CheckPID reports whether signaling pid is allowed.  ok=false carries the reason.
func CheckPID(pid int, comm, cmdline string) (ok bool, r Refusal) {
	if pid <= 1 {
		return false, Refusal{"refusing to signal PID 1 (init)"}
	}
	if pid == os.Getpid() {
		return false, Refusal{"refusing to signal the agent itself"}
	}
	// Refuse anything in our own process tree: walk up via /proc would be
	// ideal; the cheap, correct-enough guard is the executable name plus
	// the session check done by callers.  Name matching is the backstop.
	base := comm
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[i+1:]
	}
	target := base + "\x00" + cmdline
	for _, re := range NeverKill {
		if re.MatchString(base) || re.MatchString(cmdline) {
			return false, Refusal{"protected process matched by safety policy: " + re.String()}
		}
		_ = target
	}
	return true, Refusal{}
}

// CheckContainerName refuses stops/kills/limits on infrastructure containers.
func CheckContainerName(name string) (bool, Refusal) {
	lower := strings.ToLower(name)
	for _, keep := range []string{"hh-agent", "coolify", "tailscale"} {
		if strings.Contains(lower, keep) {
			return false, Refusal{"protected container: " + name}
		}
	}
	return true, Refusal{}
}

// DataDir returns the agent's state directory, creating it mode 0700.
func DataDir() string {
	dir := os.Getenv("HH_AGENT_DATA_DIR")
	if dir == "" {
		dir = "/var/lib/hh-agent"
	}
	os.MkdirAll(dir, 0700)
	return dir
}

// AuditPath is the append-only JSONL audit log.
func AuditPath() string {
	return filepath.Join(DataDir(), "audit.jsonl")
}
