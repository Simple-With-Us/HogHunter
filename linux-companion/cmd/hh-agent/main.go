// Command hh-agent is the HogHunter Linux companion: one binary, two faces.
// `hh-agent serve` runs the daemon; `hh-agent <cmd>` is the local control
// surface for the server itself — over SSH, by fleet agents, or by scripts.
//
// Scripting contract (SPEC.md §7): --json on reads, exit 0 ok / 1 error /
// 2 usage / 3 refused-or-daemon-down, no prompts without a TTY unless --yes.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/autoclean"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/daemon"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/docker"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/host"
	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/lanes"
)

const (
	exitOK      = 0
	exitError   = 1
	exitUsage   = 2
	exitRefused = 3
)

func defaultSocket() string {
	if s := os.Getenv("HH_AGENT_SOCKET"); s != "" {
		return s
	}
	return "/run/hh-agent.sock"
}

func defaultHTTP() string {
	if h := os.Getenv("HH_AGENT_HTTP"); h != "" {
		return h
	}
	return "127.0.0.1:24241"
}

// unixClient talks HTTP to the daemon over the Unix socket.
func unixClient(sock string) *http.Client {
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", sock)
			},
		},
	}
}

// daemonGet performs a GET against the daemon; ok=false when the daemon is down.
func daemonGet(path string) (data []byte, ok bool) {
	c := unixClient(defaultSocket())
	req, _ := http.NewRequest("GET", "http://localhost"+path, nil)
	if tok := os.Getenv("HH_AGENT_TOKEN"); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	data, _ = io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	return data, true
}

// daemonPost performs a POST against the daemon; ok=false when the daemon is down.
func daemonPost(path string, body any) (data []byte, ok bool) {
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	c := unixClient(defaultSocket())
	req, _ := http.NewRequest("POST", "http://localhost"+path, rdr)
	req.Header.Set("Content-Type", "application/json")
	if tok := os.Getenv("HH_AGENT_TOKEN"); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	data, _ = io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	return data, true
}

func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func isTTY() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// confirmDestructive enforces the confirmation ladder: --yes, or an
// interactive prompt on a TTY, otherwise refuse (exit 3).
func confirmDestructive(yes bool, what string) int {
	if yes {
		return exitOK
	}
	if !isTTY() {
		fmt.Fprintf(os.Stderr, "refusing %s: not a TTY and --yes not given\n", what)
		return exitRefused
	}
	fmt.Fprintf(os.Stderr, "%s — type 'yes' to proceed: ", what)
	var answer string
	fmt.Scanln(&answer)
	if strings.TrimSpace(answer) != "yes" {
		fmt.Fprintln(os.Stderr, "aborted")
		return exitRefused
	}
	return exitOK
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%dB", n)
	}
	div, exp := int64(unit), 0
	for nn := n / unit; nn >= unit; nn /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%cB", float64(n)/float64(div), "KMGTPE"[exp])
}

func usage() {
	fmt.Fprintln(os.Stderr, `hh-agent — HogHunter Linux companion

  hh-agent serve [--http 127.0.0.1:24241] [--socket /run/hh-agent.sock]
  hh-agent status [--json]
  hh-agent ps [--sort cpu|mem|pid] [--limit N] [--json]
  hh-agent top [--json]
  hh-agent containers [--json]
  hh-agent prune [--images] [--volumes] [--cache] [--stopped-containers] [--dry-run] [--yes] [--json]
  hh-agent autoclean [--dry-run] [--yes] [--force] [--json]
  hh-agent autoclean --history [--json]
  hh-agent stop <container|pid> [--timeout 10] [--yes] [--json]
  hh-agent kill <container|pid> [--yes] [--json]
  hh-agent limit <container> [--memory 2g] [--cpus 1.5] [--json]
  hh-agent lanes [--json]
  hh-agent pair [--approve <id> | --deny <id> | --revoke <device-id>] [--json]

Exit codes: 0 ok · 1 error · 2 usage · 3 refused or daemon unavailable.`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(exitUsage)
	}
	// Headless pairing nudge: every invocation prints a one-line notice
	// while pairing requests are pending, so approval is never missed.
	pendingNotice()
	var code int
	switch os.Args[1] {
	case "serve":
		code = cmdServe(os.Args[2:])
	case "status":
		code = cmdStatus(os.Args[2:])
	case "ps":
		code = cmdPs(os.Args[2:])
	case "top":
		code = cmdTop(os.Args[2:])
	case "containers":
		code = cmdContainers(os.Args[2:])
	case "prune":
		code = cmdPrune(os.Args[2:])
	case "autoclean":
		code = cmdAutoclean(os.Args[2:])
	case "stop":
		code = cmdStopKill(os.Args[2:], "stop")
	case "kill":
		code = cmdStopKill(os.Args[2:], "kill")
	case "limit":
		code = cmdLimit(os.Args[2:])
	case "lanes":
		code = cmdLanes(os.Args[2:])
	case "pair":
		code = cmdPair(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		usage()
		code = exitUsage
	}
	os.Exit(code)
}

func cmdServe(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	httpAddr := fs.String("http", defaultHTTP(), "HTTP listen address")
	sock := fs.String("socket", defaultSocket(), "Unix socket path")
	_ = fs.Parse(args)
	roots := []string{}
	if r := os.Getenv("HH_AGENT_LANE_ROOTS"); r != "" {
		roots = strings.Split(r, ",")
	}
	srv, err := daemon.New(daemon.Config{
		HTTPAddr:   *httpAddr,
		SocketPath: *sock,
		DockerSock: docker.SocketPath(),
		LaneRoots:  roots,
		StateDir:   os.Getenv("HH_AGENT_STATE_DIR"),
		Autoclean:  autoclean.ConfigFromEnv(),
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "serve:", err)
		return exitError
	}
	fmt.Fprintf(os.Stderr, "hh-agent %s listening on %s and %s\n", daemon.Version, *httpAddr, *sock)
	if err := srv.Serve(); err != nil {
		fmt.Fprintln(os.Stderr, "serve:", err)
		return exitError
	}
	return exitOK
}

func cmdStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	// Prefer the daemon; fall back to direct reads when it is down.
	if data, ok := daemonGet("/v1/snapshot"); ok {
		if *asJSON {
			fmt.Println(string(data))
		} else {
			fmt.Println("(daemon snapshot — detail stubbed in 0.1.0; see `hh-agent ps`)")
		}
		return exitOK
	}
	procs, err := host.Top("cpu", 5)
	if err != nil {
		fmt.Fprintln(os.Stderr, "status:", err)
		return exitError
	}
	if *asJSON {
		printJSON(map[string]any{"ok": true, "daemon": false, "top_processes": procs})
		return exitOK
	}
	fmt.Println("hh-agent status (daemon down — direct /proc read)")
	for _, p := range procs {
		fmt.Printf("%6d %6.1f%% %8s %s\n", p.PID, p.CPU, humanBytes(p.RSS), p.Comm)
	}
	return exitOK
}

func cmdPs(args []string) int {
	fs := flag.NewFlagSet("ps", flag.ExitOnError)
	sortBy := fs.String("sort", "cpu", "sort: cpu|mem|pid")
	limit := fs.Int("limit", 25, "row limit")
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	procs, err := host.Top(*sortBy, *limit)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ps:", err)
		return exitError
	}
	if *asJSON {
		printJSON(map[string]any{"ok": true, "processes": procs})
		return exitOK
	}
	fmt.Printf("%-7s %-7s %-10s %s\n", "PID", "CPU%", "RSS", "COMMAND")
	for _, p := range procs {
		cmd := p.Cmdline
		if cmd == "" {
			cmd = "[" + p.Comm + "]"
		}
		fmt.Printf("%-7d %-7.1f %-10s %s\n", p.PID, p.CPU, humanBytes(p.RSS), cmd)
	}
	return exitOK
}

func cmdTop(args []string) int {
	return cmdPs(append([]string{"--sort", "cpu"}, args...))
}

func cmdContainers(args []string) int {
	fs := flag.NewFlagSet("containers", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	data, ok := daemonGet("/v1/containers")
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable (needs the Docker socket mount)")
		return exitRefused
	}
	var resp struct {
		OK         bool `json:"ok"`
		Containers []struct {
			ID    string `json:"id"`
			Name  string `json:"name"`
			Image string `json:"image"`
			State string `json:"state"`
			Stats struct {
				CPUPercent float64 `json:"cpu_percent"`
				MemUsage   uint64  `json:"mem_usage"`
				MemLimit   uint64  `json:"mem_limit"`
				OOMKills   uint64  `json:"oom_kills"`
			} `json:"stats"`
		} `json:"containers"`
	}
	if err := json.Unmarshal(data, &resp); err != nil || !resp.OK {
		fmt.Fprintln(os.Stderr, "containers: bad daemon response")
		return exitError
	}
	if *asJSON {
		fmt.Println(string(data))
		return exitOK
	}
	fmt.Printf("%-12s %-20s %-8s %-8s %-12s %s\n", "ID", "NAME", "CPU%", "MEM", "OOMK", "IMAGE")
	for _, c := range resp.Containers {
		fmt.Printf("%-12s %-20s %-8.1f %-8s %-12d %s\n",
			c.ID, c.Name, c.Stats.CPUPercent, humanBytes(int64(c.Stats.MemUsage)),
			c.Stats.OOMKills, c.Image)
	}
	return exitOK
}

func cmdPrune(args []string) int {
	fs := flag.NewFlagSet("prune", flag.ExitOnError)
	images := fs.Bool("images", false, "prune unused images")
	volumes := fs.Bool("volumes", false, "prune dangling volumes")
	cache := fs.Bool("cache", false, "prune build cache")
	stopped := fs.Bool("stopped-containers", false, "prune stopped containers")
	dryRun := fs.Bool("dry-run", false, "report only (default unless --yes)")
	yes := fs.Bool("yes", false, "apply the prune")
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	targets := []string{}
	if *images {
		targets = append(targets, "images")
	}
	if *volumes {
		targets = append(targets, "volumes")
	}
	if *cache {
		targets = append(targets, "build-cache")
	}
	if *stopped {
		targets = append(targets, "stopped-containers")
	}
	if len(targets) == 0 {
		targets = []string{"images", "volumes", "build-cache", "stopped-containers"}
	}
	apply := *yes
	if !apply {
		// Default-safe: without --yes this is always a dry-run.
		*dryRun = true
	}
	data, ok := daemonPost("/v1/prune", map[string]any{"targets": targets, "dry_run": *dryRun})
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable (needs the Docker socket mount)")
		return exitRefused
	}
	if *asJSON {
		fmt.Println(string(data))
		return exitOK
	}
	var resp struct {
		OK      bool   `json:"ok"`
		DryRun  bool   `json:"dry_run"`
		Note    string `json:"note"`
		Results map[string]struct {
			ReclaimedBytes uint64 `json:"reclaimed_bytes"`
		} `json:"results"`
		Total uint64 `json:"total_reclaimed_bytes"`
	}
	_ = json.Unmarshal(data, &resp)
	if resp.DryRun {
		fmt.Println("dry-run — nothing deleted.  Re-run with --yes to apply.")
		fmt.Println(resp.Note)
		return exitOK
	}
	for t, r := range resp.Results {
		fmt.Printf("%-18s reclaimed %s\n", t, humanBytes(int64(r.ReclaimedBytes)))
	}
	fmt.Printf("total reclaimed: %s\n", humanBytes(int64(resp.Total)))
	return exitOK
}

// cmdAutoclean is the local control surface for the automatic root-disk
// cleanup mode.  It runs in-process (no daemon needed — SSH and scripts
// are the point), under the env-derived config, with one deliberate
// difference from the daemon loop: invoking the command at all is the
// operator's opt-in for this run, so the runner is enabled here even
// when HH_AGENT_AUTOCLEAN is unset.  The trigger still applies unless
// --force is given, and applying still requires --yes.
func cmdAutoclean(args []string) int {
	fs := flag.NewFlagSet("autoclean", flag.ExitOnError)
	dryRun := fs.Bool("dry-run", false, "report only (default unless --yes)")
	yes := fs.Bool("yes", false, "apply the cleanup")
	force := fs.Bool("force", false, "bypass the disk trigger and the cooldown")
	history := fs.Bool("history", false, "print the cleanup history instead of running")
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)

	if *history {
		recs, err := autoclean.ReadHistory(autoclean.HistoryPath())
		if err != nil {
			fmt.Fprintln(os.Stderr, "autoclean history:", err)
			return exitError
		}
		if *asJSON {
			printJSON(map[string]any{"ok": true, "history": recs})
			return exitOK
		}
		if len(recs) == 0 {
			fmt.Println("no automatic cleanups recorded yet")
			return exitOK
		}
		for _, r := range recs {
			fmt.Printf("%s  freed %-9s %3d items  [%s]\n",
				r.CleanedAt.Format("2006-01-02 15:04"), humanBytes(int64(r.BytesReclaimed)),
				r.ItemsRemoved, strings.Join(r.CategoryIDs, ", "))
		}
		return exitOK
	}

	cfg := autoclean.ConfigFromEnv()
	cfg.Enabled = true // an explicit invocation is the opt-in for this run
	cfg.Actor = "local"
	runner := autoclean.NewRunner(cfg, autoclean.Deps{})
	apply := *yes
	if !apply {
		*dryRun = true
	}
	sum, err := runner.RunOnceAs("local", *dryRun, *force)
	if err != nil {
		fmt.Fprintln(os.Stderr, "autoclean:", err)
		return exitError
	}
	if *asJSON {
		printJSON(map[string]any{"ok": true, "autoclean": sum})
		return exitOK
	}
	fmt.Printf("root %s: %.1f%% used, %s free — triggered: %v\n",
		sum.DiskBefore.Path, sum.DiskBefore.UsedPercent, humanBytes(int64(sum.DiskBefore.FreeBytes)), sum.Triggered)
	if sum.InCooldown {
		fmt.Println("skipped: inside the cooldown since the last applied run (use --force to override)")
		return exitOK
	}
	if !sum.Triggered && !*force && !*dryRun {
		fmt.Println("not triggered — nothing cleaned.  Use --force to run anyway, or --dry-run to see the plan.")
		return exitOK
	}
	for _, c := range sum.Categories {
		switch {
		case c.Error != "":
			fmt.Printf("%-24s error: %s\n", c.Category, c.Error)
		case c.Skipped != "":
			fmt.Printf("%-24s skipped: %s\n", c.Category, c.Skipped)
		default:
			fmt.Printf("%-24s reclaimed %-9s %d items\n", c.Category, humanBytes(int64(c.BytesReclaimed)), c.ItemsRemoved)
		}
	}
	if sum.DryRun {
		fmt.Println("dry-run — nothing deleted.  Re-run with --yes to apply.")
	} else {
		fmt.Printf("total reclaimed: %s\n", humanBytes(int64(sum.BytesReclaimed)))
	}
	return exitOK
}

func cmdStopKill(args []string, action string) int {
	fs := flag.NewFlagSet(action, flag.ExitOnError)
	timeout := fs.Int("timeout", 10, "stop timeout seconds")
	yes := fs.Bool("yes", false, "skip confirmation")
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintf(os.Stderr, "usage: hh-agent %s <container|pid> [--yes]\n", action)
		return exitUsage
	}
	target := rest[0]
	if code := confirmDestructive(*yes, action+" "+target); code != exitOK {
		return code
	}
	var data []byte
	var ok bool
	if pid, err := strconv.Atoi(target); err == nil {
		// Host PID kill goes through the daemon's process route.
		_ = pid
		data, ok = daemonPost("/v1/processes/"+target+"/kill", map[string]any{"signal": map[string]string{"stop": "TERM", "kill": "KILL"}[action]})
	} else {
		path := "/v1/containers/" + target + "/" + action
		var body any
		if action == "stop" {
			body = map[string]any{"timeout": *timeout}
		}
		data, ok = daemonPost(path, body)
	}
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable")
		return exitRefused
	}
	if *asJSON {
		fmt.Println(string(data))
		return exitOK
	}
	var resp struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	_ = json.Unmarshal(data, &resp)
	if !resp.OK {
		fmt.Fprintln(os.Stderr, "refused:", resp.Error)
		return exitRefused
	}
	fmt.Printf("%s %s: ok\n", action, target)
	return exitOK
}

func cmdLimit(args []string) int {
	fs := flag.NewFlagSet("limit", flag.ExitOnError)
	memory := fs.String("memory", "", "memory cap (e.g. 2g, 512m)")
	cpus := fs.Float64("cpus", 0, "CPU cap (e.g. 1.5)")
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	rest := fs.Args()
	if len(rest) != 1 || (*memory == "" && *cpus <= 0) {
		fmt.Fprintln(os.Stderr, "usage: hh-agent limit <container> [--memory 2g] [--cpus 1.5]")
		return exitUsage
	}
	data, ok := daemonPost("/v1/containers/"+rest[0]+"/limit",
		map[string]any{"memory": *memory, "cpus": *cpus})
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable")
		return exitRefused
	}
	if *asJSON {
		fmt.Println(string(data))
		return exitOK
	}
	fmt.Printf("limit %s: memory=%s cpus=%.2f applied\n", rest[0], *memory, *cpus)
	return exitOK
}

func cmdLanes(args []string) int {
	fs := flag.NewFlagSet("lanes", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	roots := []string{}
	if r := os.Getenv("HH_AGENT_LANE_ROOTS"); r != "" {
		roots = strings.Split(r, ",")
	}
	// Prefer the daemon's cached scan; fall back to a direct scan.
	if data, ok := daemonGet("/v1/lanes"); ok {
		if *asJSON {
			fmt.Println(string(data))
		} else {
			printLanes(data)
		}
		return exitOK
	}
	out := lanes.Scan(roots)
	if *asJSON {
		printJSON(map[string]any{"ok": true, "lanes": out, "daemon": false})
		return exitOK
	}
	data, _ := json.Marshal(map[string]any{"lanes": out})
	printLanes(data)
	return exitOK
}

func printLanes(data []byte) {
	var resp struct {
		Lanes []lanes.Lane `json:"lanes"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		fmt.Fprintln(os.Stderr, "lanes: bad response")
		return
	}
	fmt.Printf("%-8s %-5s %-5s %-24s %s\n", "VERDICT", "AHEAD", "BEHIND", "BRANCH", "PATH")
	for _, l := range resp.Lanes {
		up := ""
		if l.Upstream != nil {
			up = *l.Upstream
		}
		_ = up
		fmt.Printf("%-8s %-5d %-5d %-24s %s\n", l.Verdict, l.Ahead, l.Behind, l.Branch, l.Path)
	}
}

// pendingNotice prints a one-line stderr notice when pairing requests are
// waiting, so no request is missed.  Silent when the daemon is down or
// when nothing is pending.
func pendingNotice() {
	data, ok := daemonGet("/v1/admin/pair-requests")
	if !ok {
		return
	}
	var resp struct {
		OK       bool `json:"ok"`
		Requests []struct {
			RequestID string `json:"request_id"`
		} `json:"requests"`
	}
	if err := json.Unmarshal(data, &resp); err != nil || !resp.OK {
		return
	}
	if n := len(resp.Requests); n > 0 {
		plural := ""
		if n > 1 {
			plural = "s"
		}
		fmt.Fprintf(os.Stderr, "hh-agent: %d pairing request%s pending — run `hh-agent pair` to review\n", n, plural)
	}
}

type pairRequest struct {
	RequestID   string `json:"request_id"`
	DeviceName  string `json:"device_name"`
	RemoteAddr  string `json:"remote_addr"`
	RequestedAt string `json:"requested_at"`
	ExpiresAt   string `json:"expires_at"`
}

// pairFetch lists pending pairing requests from the daemon.
func pairFetch() ([]pairRequest, int) {
	data, ok := daemonGet("/v1/admin/pair-requests")
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable")
		return nil, exitRefused
	}
	var resp struct {
		OK       bool          `json:"ok"`
		Error    string        `json:"error"`
		Requests []pairRequest `json:"requests"`
	}
	if err := json.Unmarshal(data, &resp); err != nil || !resp.OK {
		fmt.Fprintln(os.Stderr, "pair: bad daemon response")
		return nil, exitError
	}
	return resp.Requests, exitOK
}

func cmdPair(args []string) int {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	approve := fs.String("approve", "", "approve pairing request id")
	deny := fs.String("deny", "", "deny pairing request id")
	revoke := fs.String("revoke", "", "revoke device id")
	asJSON := fs.Bool("json", false, "JSON output")
	_ = fs.Parse(args)
	switch {
	case *approve != "":
		return pairApprove(*approve, *asJSON)
	case *deny != "":
		return pairDeny(*deny, *asJSON)
	case *revoke != "":
		return pairRevoke(*revoke, *asJSON)
	default:
		return pairInteractive(*asJSON)
	}
}

func pairInteractive(asJSON bool) int {
	reqs, code := pairFetch()
	if code != exitOK {
		return code
	}
	if asJSON {
		printJSON(map[string]any{"ok": true, "requests": reqs})
		return exitOK
	}
	if len(reqs) == 0 {
		fmt.Println("no pending pairing requests")
		return exitOK
	}
	printPairTable(reqs)
	if !isTTY() {
		return exitOK
	}
	fmt.Fprint(os.Stderr, "approve which request id? (empty to quit): ")
	var id string
	fmt.Scanln(&id)
	id = strings.TrimSpace(id)
	if id == "" {
		return exitOK
	}
	return pairApprove(id, false)
}

func printPairTable(reqs []pairRequest) {
	fmt.Printf("%-20s %-24s %-16s %s\n", "REQUEST", "DEVICE", "FROM", "EXPIRES")
	for _, r := range reqs {
		fmt.Printf("%-20s %-24s %-16s %s\n", r.RequestID, r.DeviceName, r.RemoteAddr, r.ExpiresAt)
	}
}

// pairApprove approves one request and prints the minted device token
// exactly once — the only time the raw token appears.  It is never logged.
func pairApprove(id string, asJSON bool) int {
	data, ok := daemonPost("/v1/admin/pair-requests/"+id+"/approve", nil)
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable")
		return exitRefused
	}
	var resp struct {
		OK         bool   `json:"ok"`
		Error      string `json:"error"`
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		Token      string `json:"token"`
	}
	if err := json.Unmarshal(data, &resp); err != nil || !resp.OK {
		fmt.Fprintf(os.Stderr, "approve %s: %s\n", id, resp.Error)
		return exitRefused
	}
	if asJSON {
		printJSON(resp)
		return exitOK
	}
	fmt.Printf("Approved %q as device %s.\n", resp.DeviceName, resp.DeviceID)
	fmt.Println("Device token — shown once, store it now:")
	fmt.Println(resp.Token)
	return exitOK
}

func pairDeny(id string, asJSON bool) int {
	data, ok := daemonPost("/v1/admin/pair-requests/"+id+"/deny", nil)
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable")
		return exitRefused
	}
	var resp struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(data, &resp); err != nil || !resp.OK {
		fmt.Fprintf(os.Stderr, "deny %s: %s\n", id, resp.Error)
		return exitRefused
	}
	if asJSON {
		printJSON(resp)
		return exitOK
	}
	fmt.Printf("Denied pairing request %s.\n", id)
	return exitOK
}

// pairRevoke cuts off one device; its token stops working immediately.
func pairRevoke(deviceID string, asJSON bool) int {
	data, ok := daemonPost("/v1/admin/devices/"+deviceID+"/revoke", nil)
	if !ok {
		fmt.Fprintln(os.Stderr, "daemon unavailable")
		return exitRefused
	}
	var resp struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(data, &resp); err != nil || !resp.OK {
		fmt.Fprintf(os.Stderr, "revoke %s: %s\n", deviceID, resp.Error)
		return exitRefused
	}
	if asJSON {
		printJSON(resp)
		return exitOK
	}
	fmt.Printf("Revoked device %s.\n", deviceID)
	return exitOK
}
