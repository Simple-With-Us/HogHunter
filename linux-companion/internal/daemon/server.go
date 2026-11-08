// Package daemon is the hh-agent HTTP server: host/container reads and
// guarded writes.  Auth is pairing-based (SPEC.md §5): device tokens are
// minted on CLI approval of a pairing request and stored as SHA-256 hashes
// only; raw tokens are never persisted or logged.  The local Unix socket is
// trusted without a token — socket file permissions are the auth — while the
// Tailscale HTTP listener requires a Bearer token on every route except
// /v1/health, /v1/version, and POST /v1/pair-request (tailnet-only,
// rate-limited).  Pairing approval routes live under /v1/admin/* and answer
// only on the Unix socket: there is deliberately no HTTP approval route.
package daemon

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/audit"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/auth"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/autoclean"
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
	// StateDir holds the token store (devices.json, pair-requests.json).
	// Empty means auth.DefaultDir() (/var/lib/hh-agent, or HH_AGENT_STATE_DIR).
	StateDir string
	// Autoclean is the automatic root-disk cleanup mode.  The zero value
	// is disabled (the shipped default); Serve starts the check loop
	// only when Autoclean.Enabled is set.
	Autoclean autoclean.Config
}

// Server holds daemon state.
type Server struct {
	cfg         Config
	docker      *docker.Client
	mux         *http.ServeMux
	tokens      *auth.Store
	startedAt   time.Time
	pairLimiter *auth.RateLimiter
	autoclean   *autoclean.Runner
}

// New builds the server.  It opens (or creates) the token store; raw tokens
// are never stored, only their SHA-256 hashes.
func New(cfg Config) (*Server, error) {
	tokens, err := auth.Open(cfg.StateDir)
	if err != nil {
		return nil, err
	}
	s := &Server{
		cfg:         cfg,
		mux:         http.NewServeMux(),
		tokens:      tokens,
		startedAt:   time.Now(),
		pairLimiter: auth.NewRateLimiter(5, time.Hour),
		autoclean:   autoclean.NewRunner(cfg.Autoclean, autoclean.Deps{}),
	}
	if cfg.DockerSock != "" {
		s.docker = docker.New(cfg.DockerSock)
	}
	s.routes()
	return s, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func errJSON(w http.ResponseWriter, code int, reason string) {
	writeJSON(w, code, map[string]any{"ok": false, "error": reason})
}

// trustKey marks requests that arrived over the local Unix socket, where
// socket file permissions are the auth and no bearer token is needed.
type trustKey struct{}

func isTrusted(r *http.Request) bool {
	v, _ := r.Context().Value(trustKey{}).(bool)
	return v
}

// requireAuth enforces Bearer-token auth on the HTTP listener.  On the
// trusted Unix socket it passes through without a token.  The third
// argument to next is the actor identity: a device id, or "local" for the
// socket path.  Raw tokens are never exposed to handlers (and so can never
// reach the audit log).
func (s *Server) requireAuth(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if isTrusted(r) {
			next(w, r, "local")
			return
		}
		d, ok := s.tokens.VerifyBearer(r.Header.Get("Authorization"))
		if !ok {
			errJSON(w, 401, "bearer token required")
			return
		}
		next(w, r, d.DeviceID)
	}
}

// requireTrusted refuses the route unless it arrived over the Unix socket.
// Pairing approval/denial/revocation have no HTTP route by design —
// approval requires shell on the host.
func (s *Server) requireTrusted(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !isTrusted(r) {
			errJSON(w, 403, "this route is only available on the local Unix socket")
			return
		}
		next(w, r)
	}
}

func (s *Server) routes() {
	m := s.mux
	m.HandleFunc("/v1/health", s.handleHealth)
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
	m.HandleFunc("/v1/autoclean", s.requireAuth(s.handleAutoclean))
	m.HandleFunc("/v1/autoclean/history", s.requireAuth(s.handleAutocleanHistory))
	m.HandleFunc("/v1/lanes", s.requireAuth(s.handleLanes))
	// Pairing: request is tailnet-only, unauthenticated, rate-limited.
	m.HandleFunc("/v1/pair-request", s.handlePairRequest)
	// Pending-request list for any valid device token (Mac UI: "waiting").
	m.HandleFunc("/v1/pair-requests", s.requireAuth(s.handlePairRequests))
	// Admin: Unix-socket only.  No HTTP approval route, by design.
	m.HandleFunc("/v1/admin/pair-requests", s.requireTrusted(s.handleAdminPairRequests))
	m.HandleFunc("/v1/admin/pair-requests/", s.requireTrusted(s.handleAdminPairRequestAction))
	m.HandleFunc("/v1/admin/devices", s.requireTrusted(s.handleAdminDevices))
	m.HandleFunc("/v1/admin/devices/", s.requireTrusted(s.handleAdminDeviceAction))
}

// handleHealth is the cheap, unauthenticated liveness endpoint (Muster
// collector contract, SPEC.md §13).  It must never block on Docker or git:
// version + uptime only, no sensitive fields.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" && r.Method != "HEAD" {
		errJSON(w, 405, "method not allowed")
		return
	}
	writeJSON(w, 200, map[string]any{
		"status":   "ok",
		"version":  Version,
		"uptime_s": int64(time.Since(s.startedAt).Seconds()),
	})
}

// handlePairRequest creates a pending pairing request.  No credential:
// the tailnet-only bind plus rate limiting are the protection.  The body
// carries only a device name.
func (s *Server) handlePairRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		errJSON(w, 405, "method not allowed")
		return
	}
	ip := auth.ClientIP(r.RemoteAddr)
	if !s.pairLimiter.Allow(ip) {
		w.Header().Set("Retry-After", "60")
		errJSON(w, 429, "too many pairing requests; try again later")
		return
	}
	var body struct {
		DeviceName string `json:"device_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		errJSON(w, 400, "bad body")
		return
	}
	p, err := s.tokens.RequestPairing(body.DeviceName, r.RemoteAddr)
	if err != nil {
		errJSON(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{
		"ok": true, "request_id": p.RequestID, "expires_at": p.ExpiresAt,
	})
}

// handlePairRequests lists pending requests for any valid device token, so
// the Mac Devices view can show "waiting for approval".
func (s *Server) handlePairRequests(w http.ResponseWriter, r *http.Request, _ string) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "requests": s.tokens.PendingRequests()})
}

func (s *Server) handleAdminPairRequests(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "requests": s.tokens.PendingRequests()})
}

func (s *Server) handleAdminDevices(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "devices": s.tokens.ListDevices()})
}

// handleAdminPairRequestAction approves or denies one pending request.
// Approval mints a per-device hh1_ token; this response is the only time
// the raw token ever appears.  It is never logged or persisted.
func (s *Server) handleAdminPairRequestAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		errJSON(w, 405, "method not allowed")
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/v1/admin/pair-requests/")
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) != 2 {
		errJSON(w, 404, "not found")
		return
	}
	id, action := parts[0], parts[1]
	switch action {
	case "approve":
		p, err := s.tokens.TakeRequest(id)
		if err != nil {
			errJSON(w, 404, err.Error())
			return
		}
		token, err := auth.MintToken()
		if err != nil {
			errJSON(w, 500, "could not mint token")
			return
		}
		d, err := s.tokens.AddDevice(p.DeviceName, token)
		if err != nil {
			errJSON(w, 500, "could not store device")
			return
		}
		// Actor and detail carry no secret: the raw token is not logged.
		_ = audit.Log("local", "pair-approve", "device:"+d.DeviceID, "name="+p.DeviceName, "ok")
		writeJSON(w, 200, map[string]any{
			"ok": true, "device_id": d.DeviceID,
			"device_name": d.DeviceName, "token": token,
		})
	case "deny":
		p, err := s.tokens.TakeRequest(id)
		if err != nil {
			errJSON(w, 404, err.Error())
			return
		}
		_ = audit.Log("local", "pair-deny", "request:"+p.RequestID, "name="+p.DeviceName, "ok")
		writeJSON(w, 200, map[string]any{"ok": true, "request_id": p.RequestID})
	default:
		errJSON(w, 404, "not found")
	}
}

// handleAdminDeviceAction revokes a device; its token stops working
// immediately.
func (s *Server) handleAdminDeviceAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		errJSON(w, 405, "method not allowed")
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/v1/admin/devices/")
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) != 2 {
		errJSON(w, 404, "not found")
		return
	}
	id, action := parts[0], parts[1]
	if action != "revoke" {
		errJSON(w, 404, "not found")
		return
	}
	if err := s.tokens.Revoke(id); err != nil {
		errJSON(w, 404, err.Error())
		return
	}
	_ = audit.Log("local", "pair-revoke", "device:"+id, "", "ok")
	writeJSON(w, 200, map[string]any{"ok": true, "device_id": id, "revoked": true})
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
			"targets":    body.Targets,
			"note":       "dry-run: totals below are current reclaimable state; nothing was deleted",
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

// handleAutoclean serves the automatic root-disk cleanup mode.
// POST /v1/autoclean runs one pass on demand: {"dry_run": true} is the
// default, exactly like /v1/prune; {"dry_run": false} applies, and
// {"force": true} additionally bypasses the trigger and the cooldown.
// The daemon's own loop (Serve, when the mode is enabled) is what makes
// cleanup automatic — this route is the manual trigger and the status
// surface for the same runner, so the two can never disagree.
func (s *Server) handleAutoclean(w http.ResponseWriter, r *http.Request, actor string) {
	if r.Method == "GET" {
		u, triggered, err := s.autoclean.Check()
		if err != nil {
			errJSON(w, 500, err.Error())
			return
		}
		cfg := s.autoclean.Config()
		writeJSON(w, 200, map[string]any{
			"ok": true, "enabled": cfg.Enabled, "would_trigger": triggered,
			"disk": u, "categories": autoclean.AllCategories(),
		})
		return
	}
	if r.Method != "POST" {
		errJSON(w, 405, "method not allowed")
		return
	}
	var body struct {
		DryRun *bool `json:"dry_run"`
		Force  bool  `json:"force"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	dryRun := true
	if body.DryRun != nil {
		dryRun = *body.DryRun
	}
	// Applying is destructive, so it additionally requires the
	// daemon-side opt-in (HH_AGENT_AUTOCLEAN=1): an authenticated
	// device alone must not be able to delete files, with or without
	// force.  Dry runs stay available to any authenticated device —
	// they delete nothing and are the status surface's plan view.
	enabled := s.autoclean.Config().Enabled
	if !dryRun && !enabled {
		errJSON(w, 403, "autoclean apply is not enabled on this daemon (HH_AGENT_AUTOCLEAN=1 is not set); dry_run remains available")
		return
	}
	sum, err := s.autoclean.RunOnceAs(actor, dryRun, body.Force)
	if err != nil {
		errJSON(w, 409, err.Error())
		return
	}
	// "enabled" rides along so a client can tell "the mode is off"
	// apart from "the disk is below the trigger" — the summary alone
	// reads the same for both.
	writeJSON(w, 200, map[string]any{"ok": true, "enabled": enabled, "autoclean": sum})
}

// handleAutocleanHistory returns the cleanup history, newest first —
// the same cleanup-history.jsonl schema the Mac app writes.
func (s *Server) handleAutocleanHistory(w http.ResponseWriter, r *http.Request, _ string) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	recs, err := autoclean.ReadHistory(autoclean.HistoryPath())
	if err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "history": recs})
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

// withTrust marks requests by listener: the Unix socket is trusted (socket
// permissions are the auth); the HTTP listener is not.
func (s *Server) withTrust(trusted bool, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), trustKey{}, trusted)))
	})
}

// Serve starts the HTTP listener and the Unix-socket listener.
func (s *Server) Serve() error {
	if s.cfg.Autoclean.Enabled {
		// The automatic mode: check on the interval, clean only when
		// the root disk crosses the trigger.  The loop lives and dies
		// with the process.
		go s.autoclean.Loop(context.Background())
		_ = audit.Log("autoclean", "autoclean-loop", s.cfg.Autoclean.RootPath,
			"enabled: threshold-triggered automatic root-disk cleanup", "ok")
	}
	errCh := make(chan error, 2)
	go func() {
		srv := &http.Server{Addr: s.cfg.HTTPAddr, Handler: s.withTrust(false, s.mux)}
		errCh <- srv.ListenAndServe()
	}()
	go func() {
		os.Remove(s.cfg.SocketPath)
		l, err := net.Listen("unix", s.cfg.SocketPath)
		if err != nil {
			errCh <- err
			return
		}
		os.Chmod(s.cfg.SocketPath, 0660)
		srv := &http.Server{Handler: s.withTrust(true, s.mux)}
		errCh <- srv.Serve(l)
	}()
	return <-errCh
}
