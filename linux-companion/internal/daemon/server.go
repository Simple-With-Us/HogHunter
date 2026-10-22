// Package daemon is the hh-agent HTTP server: host/container reads and
// guarded writes.  Routes are wired; destructive handlers consult the
// safety policy and the audit log.  Implemented (auth: token check stubbed
// to "any non-empty bearer" until the enroll/token store lands).
package daemon

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/audit"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/docker"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/host"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/lanes"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/safety"
)

// Version of the agent protocol.
const Version = "0.1.0"

// Config for the daemon.
type Config struct {
	HTTPAddr   string
	SocketPath string
	DockerSock string
	LaneRoots  []string
}

// Server holds daemon state.
type Server struct {
	cfg    Config
	docker *docker.Client
	mux    *http.ServeMux
}

// New builds the server.  Auth is STUBBED: any non-empty Bearer token is
// accepted on reads; writes additionally require the token to be non-empty.
// The enroll/token store (hh1_ tokens, SHA-256 hashes, pairing code) is
// specified in SPEC.md §5 and not yet implemented.
func New(cfg Config) *Server {
	s := &Server{cfg: cfg, mux: http.NewServeMux()}
	if cfg.DockerSock != "" {
		s.docker = docker.New(cfg.DockerSock)
	}
	s.routes()
	return s
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func errJSON(w http.ResponseWriter, code int, reason string) {
	writeJSON(w, code, map[string]any{"ok": false, "error": reason})
}

// authed extracts the bearer token; empty means unauthenticated.
// STUB: accepts any non-empty token.  Replace with the token store.
func authed(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return "", false
	}
	tok := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	return tok, tok != ""
}

func (s *Server) routes() {
	m := s.mux
	m.HandleFunc("/v1/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "version": Version})
	})
	m.HandleFunc("/v1/version", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"version": Version})
	})
	m.HandleFunc("/v1/snapshot", s.requireAuth(s.handleSnapshot))
	m.HandleFunc("/v1/processes", s.requireAuth(s.handleProcesses))
	m.HandleFunc("/v1/processes/", s.requireAuth(s.handleProcessAction))
	m.HandleFunc("/v1/containers", s.requireAuth(s.handleContainers))
	m.HandleFunc("/v1/containers/", s.requireAuth(s.handleContainerAction))
	m.HandleFunc("/v1/storage", s.requireAuth(s.handleStorage))
	m.HandleFunc("/v1/prune", s.requireAuth(s.handlePrune))
	m.HandleFunc("/v1/lanes", s.requireAuth(s.handleLanes))
}

func (s *Server) requireAuth(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := authed(r)
		if !ok {
			errJSON(w, 401, "bearer token required")
			return
		}
		next(w, r, tok)
	}
}

func (s *Server) needDocker(w http.ResponseWriter) bool {
	if s.docker == nil || !s.docker.Available() {
		errJSON(w, 503, "docker socket unavailable")
		return false
	}
	return true
}

func (s *Server) handleSnapshot(w http.ResponseWriter, r *http.Request, _ string) {
	// STUB: full host snapshot (loadavg, mem, disks, PSI) not yet wired.
	// /v1/processes and /v1/storage carry the real data today.
	writeJSON(w, 200, map[string]any{
		"ok": true, "version": Version,
		"note": "host snapshot detail is stubbed; see /v1/processes and /v1/storage",
		"time": time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *Server) handleProcesses(w http.ResponseWriter, r *http.Request, _ string) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	sortBy := r.URL.Query().Get("sort")
	if sortBy == "" {
		sortBy = "cpu"
	}
	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	procs, err := host.Top(sortBy, limit)
	if err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "processes": procs})
}

func (s *Server) handleProcessAction(w http.ResponseWriter, r *http.Request, actor string) {
	// POST /v1/processes/{pid}/kill  {"signal":"TERM"|"KILL"}
	if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/kill") {
		errJSON(w, 404, "not found")
		return
	}
	pidStr := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/processes/"), "/kill")
	pid, err := strconv.Atoi(pidStr)
	if err != nil {
		errJSON(w, 400, "bad pid")
		return
	}
	var body struct {
		Signal string `json:"signal"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	sig := body.Signal
	if sig == "" {
		sig = "TERM"
	}
	// Re-read the process's own comm/cmdline for the safety check.
	comm := ""
	if data, err := os.ReadFile("/proc/" + pidStr + "/comm"); err == nil {
		comm = strings.TrimSpace(string(data))
	}
	cmdline := ""
	if data, err := os.ReadFile("/proc/" + pidStr + "/cmdline"); err == nil {
		cmdline = strings.ReplaceAll(string(data), "\x00", " ")
	}
	if ok, refusal := safety.CheckPID(pid, comm, cmdline); !ok {
		_ = audit.Log(actor, "kill", "pid:"+pidStr, "signal="+sig, "refused: "+refusal.Reason)
		writeJSON(w, 200, map[string]any{"ok": false, "error": refusal.Reason, "refused_by": "safety-policy"})
		return
	}
	var syscallSig syscall.Signal = syscall.SIGTERM
	if sig == "KILL" {
		syscallSig = syscall.SIGKILL
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		errJSON(w, 404, "no such process")
		return
	}
	if err := proc.Signal(syscallSig); err != nil {
		_ = audit.Log(actor, "kill", "pid:"+pidStr, "signal="+sig, "error: "+err.Error())
		errJSON(w, 500, err.Error())
		return
	}
	_ = audit.Log(actor, "kill", "pid:"+pidStr, "signal="+sig, "ok")
	writeJSON(w, 200, map[string]any{"ok": true, "pid": pid, "signal": sig})
}

func (s *Server) handleContainers(w http.ResponseWriter, r *http.Request, _ string) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	if !s.needDocker(w) {
		return
	}
	list, err := s.docker.List()
	if err != nil {
		errJSON(w, 502, err.Error())
		return
	}
	type row struct {
		ID       string       `json:"id"`
		Name     string       `json:"name"`
		Image    string       `json:"image"`
		State    string       `json:"state"`
		Status   string       `json:"status"`
		Stats    docker.Stats `json:"stats"`
		StatsErr string       `json:"stats_error,omitempty"`
	}
	out := make([]row, 0, len(list))
	for _, c := range list {
		name := ""
		if len(c.Names) > 0 {
			name = strings.TrimPrefix(c.Names[0], "/")
		}
		r := row{ID: shortID(c.ID), Name: name, Image: c.Image, State: c.State, Status: c.Status}
		if c.State == "running" {
			st, err := s.docker.Stats(c.ID)
			if err != nil {
				r.StatsErr = err.Error()
			} else {
				r.Stats = st
			}
		}
		out = append(out, r)
	}
	writeJSON(w, 200, map[string]any{"ok": true, "containers": out})
}

func shortID(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

func (s *Server) handleContainerAction(w http.ResponseWriter, r *http.Request, actor string) {
	// POST /v1/containers/{id}/stop | /kill | /limit
	if r.Method != "POST" {
		errJSON(w, 405, "method not allowed")
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/v1/containers/")
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) != 2 {
		errJSON(w, 404, "not found")
		return
	}
	id, action := parts[0], parts[1]
	if !s.needDocker(w) {
		return
	}
	// Resolve the container name for the safety check.
	name := id
	if list, err := s.docker.List(); err == nil {
		for _, c := range list {
			if strings.HasPrefix(c.ID, id) || id == c.ID {
				if len(c.Names) > 0 {
					name = strings.TrimPrefix(c.Names[0], "/")
				}
				id = c.ID
				break
			}
		}
	}
	if ok, refusal := safety.CheckContainerName(name); !ok {
		_ = audit.Log(actor, action, "container:"+name, "", "refused: "+refusal.Reason)
		writeJSON(w, 200, map[string]any{"ok": false, "error": refusal.Reason, "refused_by": "safety-policy"})
		return
	}
	var detail, result string
	var opErr error
	switch action {
	case "stop":
		var body struct {
			Timeout int `json:"timeout"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Timeout <= 0 {
			body.Timeout = 10
		}
		detail = "timeout=" + strconv.Itoa(body.Timeout)
		opErr = s.docker.Stop(id, body.Timeout)
	case "kill":
		var body struct {
			Signal string `json:"signal"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		sig := body.Signal
		if sig == "" {
			sig = "SIGKILL"
		}
		detail = "signal=" + sig
		opErr = s.docker.Kill(id, sig)
	case "limit":
		var body struct {
			Memory string  `json:"memory"`
			CPUs   float64 `json:"cpus"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			errJSON(w, 400, "bad body")
			return
		}
		memBytes, err := parseBytes(body.Memory)
		if err != nil {
			errJSON(w, 400, "bad memory value: "+err.Error())
			return
		}
		if memBytes <= 0 && body.CPUs <= 0 {
			errJSON(w, 400, "at least one of memory, cpus is required")
			return
		}
		nano := int64(body.CPUs * 1e9)
		detail = "memory=" + body.Memory + " cpus=" + strconv.FormatFloat(body.CPUs, 'f', -1, 64)
		opErr = s.docker.UpdateLimits(id, memBytes, nano)
	default:
		errJSON(w, 404, "not found")
		return
	}
	if opErr != nil {
		result = "error: " + opErr.Error()
		_ = audit.Log(actor, action, "container:"+name, detail, result)
		errJSON(w, 502, opErr.Error())
		return
	}
	_ = audit.Log(actor, action, "container:"+name, detail, "ok")
	writeJSON(w, 200, map[string]any{"ok": true, "container": name, "action": action})
}

func (s *Server) handleStorage(w http.ResponseWriter, r *http.Request, _ string) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	if !s.needDocker(w) {
		return
	}
	df, err := s.docker.SystemDF()
	if err != nil {
		errJSON(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "disk_usage": df})
}

func (s *Server) handlePrune(w http.ResponseWriter, r *http.Request, actor string) {
	if r.Method != "POST" {
		errJSON(w, 405, "method not allowed")
		return
	}
	if !s.needDocker(w) {
		return
	}
	var body struct {
		Targets []string `json:"targets"`
		DryRun  *bool    `json:"dry_run"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		errJSON(w, 400, "bad body")
		return
	}
	dryRun := true
	if body.DryRun != nil {
		dryRun = *body.DryRun
	}
	if len(body.Targets) == 0 {
		body.Targets = []string{"images", "volumes", "build-cache", "stopped-containers"}
	}
	if dryRun {
		// Dry-run reports current reclaimable totals without deleting.
		df, err := s.docker.SystemDF()
		if err != nil {
			errJSON(w, 502, err.Error())
			return
		}
		writeJSON(w, 200, map[string]any{
			"ok": true, "dry_run": true,
			"targets": body.Targets,
			"note":    "dry-run: totals below are current reclaimable state; nothing was deleted",
			"disk_usage": df,
		})
		return
	}
	results := map[string]any{}
	var total uint64
	for _, t := range body.Targets {
		target := t
		if t == "stopped-containers" {
			target = "containers"
		}
		// Safety: the Docker API's own prune endpoints never remove running
		// containers, in-use images, or attached volumes.  No extra filter
		// needed beyond the API's guarantees.
		res, err := s.docker.Prune(target, false)
		if err != nil {
			_ = audit.Log(actor, "prune", target, "", "error: "+err.Error())
			errJSON(w, 502, err.Error())
			return
		}
		results[t] = map[string]any{"reclaimed_bytes": res.ReclaimedBytes}
		total += res.ReclaimedBytes
		_ = audit.Log(actor, "prune", target, "", "ok")
	}
	writeJSON(w, 200, map[string]any{"ok": true, "dry_run": false, "results": results, "total_reclaimed_bytes": total})
}

func (s *Server) handleLanes(w http.ResponseWriter, r *http.Request, _ string) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	// The daemon holds no cache yet; every request scans fresh.
	// STUB: add the 15-minute cached copy per SPEC.md §9.
	lanesOut := lanes.Scan(s.cfg.LaneRoots)
	writeJSON(w, 200, map[string]any{"ok": true, "lanes": lanesOut})
}

// parseBytes parses "2g", "512m", "1024k", or a bare byte count.
func parseBytes(s string) (int64, error) {
	s = strings.TrimSpace(strings.ToLower(s))
	if s == "" {
		return 0, nil
	}
	mult := int64(1)
	for _, suf := range []struct {
		suffix string
		mult   int64
	}{
		{"g", 1 << 30}, {"gb", 1 << 30},
		{"m", 1 << 20}, {"mb", 1 << 20},
		{"k", 1 << 10}, {"kb", 1 << 10},
	} {
		if strings.HasSuffix(s, suf.suffix) {
			mult = suf.mult
			s = strings.TrimSuffix(s, suf.suffix)
			break
		}
	}
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0, err
	}
	return n * mult, nil
}

// Serve starts the HTTP listener and the Unix-socket listener.
func (s *Server) Serve() error {
	errCh := make(chan error, 2)
	go func() {
		errCh <- http.ListenAndServe(s.cfg.HTTPAddr, s.mux)
	}()
	go func() {
		os.Remove(s.cfg.SocketPath)
		l, err := net.Listen("unix", s.cfg.SocketPath)
		if err != nil {
			errCh <- err
			return
		}
		os.Chmod(s.cfg.SocketPath, 0660)
		errCh <- http.Serve(l, s.mux)
	}()
	return <-errCh
}
