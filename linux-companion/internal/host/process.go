// Package host reads host-level process and system state from /proc and
// /sys.  No daemon required.  Implemented.
package host

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Process is one host process as read from /proc.
type Process struct {
	PID     int    `json:"pid"`
	PPID    int    `json:"ppid"`
	User    string `json:"user"`
	Comm    string `json:"comm"`
	Cmdline string `json:"cmdline"`
	CPU     float64 `json:"cpu_percent"`
	RSS     int64  `json:"rss_bytes"`
	State   string `json:"state"`
}

// readStat parses /proc/<pid>/stat enough to get utime, stime, ppid, state, comm, starttime.
func readStat(pid int) (utime, stime uint64, ppid int, state, comm string, starttime uint64, err error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, 0, 0, "", "", 0, err
	}
	s := string(data)
	// comm is parenthesized and may contain spaces/parens: find the last ')'.
	l := strings.LastIndex(s, ")")
	if l < 0 {
		return 0, 0, 0, "", "", 0, fmt.Errorf("bad stat")
	}
	comm = s[strings.Index(s, "(")+1 : l]
	rest := strings.Fields(s[l+2:])
	if len(rest) < 20 {
		return 0, 0, 0, "", "", 0, fmt.Errorf("short stat")
	}
	state = rest[0]
	ppid, _ = strconv.Atoi(rest[1])
	utime, _ = strconv.ParseUint(rest[11], 10, 64)
	stime, _ = strconv.ParseUint(rest[12], 10, 64)
	starttime, _ = strconv.ParseUint(rest[19], 10, 64)
	return utime, stime, ppid, state, comm, starttime, nil
}

func rssBytes(pid int) int64 {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/statm", pid))
	if err != nil {
		return 0
	}
	f := strings.Fields(string(data))
	if len(f) < 2 {
		return 0
	}
	pages, _ := strconv.ParseInt(f[1], 10, 64)
	return pages * int64(os.Getpagesize())
}

func cmdlineOf(pid int) string {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return ""
	}
	s := strings.ReplaceAll(string(data), "\x00", " ")
	s = strings.TrimSpace(s)
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return s
}

func clkTck() float64 {
	// Almost universally 100 on Linux; parsing AT_CLKTCK via auxv is
	// overkill for a top-style readout.
	return 100.0
}

// List returns all processes with CPU% measured over a 1s sample window.
func List() ([]Process, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	type sample struct {
		pid            int
		utime, stime   uint64
	}
	var pids []int
	for _, e := range entries {
		if pid, err := strconv.Atoi(e.Name()); err == nil {
			pids = append(pids, pid)
		}
	}
	s1 := map[int]sample{}
	for _, pid := range pids {
		u, s, _, _, _, _, err := readStat(pid)
		if err == nil {
			s1[pid] = sample{pid, u, s}
		}
	}
	time.Sleep(time.Second)
	out := make([]Process, 0, len(s1))
	for _, pid := range pids {
		u2, s2, ppid, state, comm, _, err := readStat(pid)
		if err != nil {
			continue
		}
		first, ok := s1[pid]
		if !ok {
			continue
		}
		delta := float64((u2+s2)-(first.utime+first.stime)) / clkTck()
		out = append(out, Process{
			PID:     pid,
			PPID:    ppid,
			Comm:    comm,
			Cmdline: cmdlineOf(pid),
			CPU:     delta * 100, // percent of one core over the 1s window
			RSS:     rssBytes(pid),
			State:   state,
		})
	}
	return out, nil
}

// Top sorts processes by the given key: cpu, mem (rss), or pid.
func Top(sortBy string, limit int) ([]Process, error) {
	procs, err := List()
	if err != nil {
		return nil, err
	}
	switch sortBy {
	case "mem":
		sort.Slice(procs, func(i, j int) bool { return procs[i].RSS > procs[j].RSS })
	case "pid":
		sort.Slice(procs, func(i, j int) bool { return procs[i].PID < procs[j].PID })
	default:
		sort.Slice(procs, func(i, j int) bool { return procs[i].CPU > procs[j].CPU })
	}
	if limit > 0 && len(procs) > limit {
		procs = procs[:limit]
	}
	return procs, nil
}
