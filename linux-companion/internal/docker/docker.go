// Package docker is a minimal Docker Engine API client over the Unix
// socket.  Stdlib only — no external SDK.  Implemented.
package docker

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

// Client talks to the Docker daemon at the given socket path.
type Client struct {
	http *http.Client
}

// New returns a client for sock (usually /var/run/docker.sock).
func New(sock string) *Client {
	return &Client{http: &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", sock)
			},
		},
	}}
}

// Available reports whether the socket answers.
func (c *Client) Available() bool {
	req, _ := http.NewRequest("GET", "http://localhost/v1.41/version", nil)
	resp, err := c.http.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode < 500
}

func (c *Client) do(method, path string, body any) ([]byte, int, error) {
	var rdr io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, 0, err
		}
		rdr = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, "http://localhost/v1.41"+path, rdr)
	if err != nil {
		return nil, 0, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	return data, resp.StatusCode, err
}

// Container is the subset of the Docker API we need.
type Container struct {
	ID     string `json:"Id"`
	Names  []string `json:"Names"`
	Image  string `json:"Image"`
	State  string `json:"State"`
	Status string `json:"Status"`
}

// List returns all containers (running and stopped).
func (c *Client) List() ([]Container, error) {
	data, code, err := c.do("GET", "/containers/json?all=1&size=1", nil)
	if err != nil {
		return nil, err
	}
	if code >= 400 {
		return nil, fmt.Errorf("docker list: HTTP %d", code)
	}
	var out []Container
	return out, json.Unmarshal(data, &out)
}

// Stats is a one-shot (non-streaming) stats sample.
type Stats struct {
	CPUPercent  float64 `json:"cpu_percent"`
	MemUsage    uint64  `json:"mem_usage"`
	MemLimit    uint64  `json:"mem_limit"`
	BlockRead   uint64  `json:"block_read"`
	BlockWrite  uint64  `json:"block_write"`
	NetRx       uint64  `json:"net_rx"`
	NetTx       uint64  `json:"net_tx"`
	PIDs        uint64  `json:"pids"`
	OOMKills    uint64  `json:"oom_kills"`
}

// Stats fetches one sample for a container, computing CPU% from the
// precpu delta the API provides.
func (c *Client) Stats(id string) (Stats, error) {
	var s Stats
	data, code, err := c.do("GET", "/containers/"+id+"/stats?stream=false&one-shot=true", nil)
	if err != nil {
		return s, err
	}
	if code >= 400 {
		return s, fmt.Errorf("docker stats: HTTP %d", code)
	}
	var raw struct {
		CPUStats struct {
			CPUUsage struct {
				TotalUsage uint64 `json:"total_usage"`
			} `json:"cpu_usage"`
			SystemUsage uint64 `json:"system_cpu_usage"`
			OnlineCPUs  uint64 `json:"online_cpus"`
		} `json:"cpu_stats"`
		PreCPUStats struct {
			CPUUsage struct {
				TotalUsage uint64 `json:"total_usage"`
			} `json:"cpu_usage"`
			SystemUsage uint64 `json:"system_cpu_usage"`
		} `json:"precpu_stats"`
		MemoryStats struct {
			Usage uint64 `json:"usage"`
			Limit uint64 `json:"limit"`
			Stats map[string]uint64 `json:"stats"`
		} `json:"memory_stats"`
		BlkioStats struct {
			IoServiceBytesRecursive []struct {
				Op    string `json:"op"`
				Value uint64 `json:"value"`
			} `json:"io_service_bytes_recursive"`
		} `json:"blkio_stats"`
		Networks map[string]struct {
			RxBytes uint64 `json:"rx_bytes"`
			TxBytes uint64 `json:"tx_bytes"`
		} `json:"networks"`
		PIDsStats struct {
			Current uint64 `json:"current"`
		} `json:"pids_stats"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return s, err
	}
	cpuDelta := float64(raw.CPUStats.CPUUsage.TotalUsage - raw.PreCPUStats.CPUUsage.TotalUsage)
	sysDelta := float64(raw.CPUStats.SystemUsage - raw.PreCPUStats.SystemUsage)
	cpus := float64(raw.CPUStats.OnlineCPUs)
	if cpus == 0 {
		cpus = 1
	}
	if sysDelta > 0 {
		s.CPUPercent = cpuDelta / sysDelta * cpus * 100
	}
	s.MemUsage = raw.MemoryStats.Usage
	s.MemLimit = raw.MemoryStats.Limit
	s.OOMKills = raw.MemoryStats.Stats["oom_kill"]
	for _, io := range raw.BlkioStats.IoServiceBytesRecursive {
		switch io.Op {
		case "read", "Read":
			s.BlockRead += io.Value
		case "write", "Write":
			s.BlockWrite += io.Value
		}
	}
	for _, n := range raw.Networks {
		s.NetRx += n.RxBytes
		s.NetTx += n.TxBytes
	}
	s.PIDs = raw.PIDsStats.Current
	return s, nil
}

// Stop stops a container with a timeout in seconds.
func (c *Client) Stop(id string, timeout int) error {
	_, code, err := c.do("POST", fmt.Sprintf("/containers/%s/stop?t=%d", id, timeout), nil)
	if err != nil {
		return err
	}
	if code == 304 {
		return nil // already stopped
	}
	if code >= 400 {
		return fmt.Errorf("docker stop: HTTP %d", code)
	}
	return nil
}

// Kill sends a signal to a container (default SIGKILL via empty signal).
func (c *Client) Kill(id, signal string) error {
	path := "/containers/" + id + "/kill"
	if signal != "" {
		path += "?signal=" + signal
	}
	_, code, err := c.do("POST", path, nil)
	if err != nil {
		return err
	}
	if code >= 400 {
		return fmt.Errorf("docker kill: HTTP %d", code)
	}
	return nil
}

// UpdateLimits live-updates a container's cgroup CPU/memory caps.
func (c *Client) UpdateLimits(id string, memoryBytes int64, nanoCPUs int64) error {
	body := map[string]any{}
	if memoryBytes > 0 {
		body["Memory"] = memoryBytes
	}
	if nanoCPUs > 0 {
		body["NanoCpus"] = nanoCPUs
	}
	_, code, err := c.do("POST", "/containers/"+id+"/update", body)
	if err != nil {
		return err
	}
	if code >= 400 {
		return fmt.Errorf("docker update: HTTP %d", code)
	}
	return nil
}

// DiskUsage mirrors `docker system df -v`.
type DiskUsage struct {
	Images      []map[string]any `json:"images"`
	Containers  []map[string]any `json:"containers"`
	Volumes     []map[string]any `json:"volumes"`
	BuildCache  []map[string]any `json:"build_cache"`
}

// SystemDF returns verbose disk usage.
func (c *Client) SystemDF() (DiskUsage, error) {
	var df DiskUsage
	data, code, err := c.do("GET", "/system/df", nil)
	if err != nil {
		return df, err
	}
	if code >= 400 {
		return df, fmt.Errorf("docker system df: HTTP %d", code)
	}
	var raw struct {
		Images     []map[string]any `json:"Images"`
		Containers []map[string]any `json:"Containers"`
		Volumes    []map[string]any `json:"Volumes"`
		BuildCache []map[string]any `json:"BuildCache"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return df, err
	}
	df.Images, df.Containers, df.Volumes, df.BuildCache = raw.Images, raw.Containers, raw.Volumes, raw.BuildCache
	return df, nil
}

// PruneResult is the reclaimed-bytes summary.
type PruneResult struct {
	ReclaimedBytes uint64 `json:"reclaimed_bytes"`
}

// Prune prunes images (dangling or all unused), volumes, build cache, or
// stopped containers.  all=true means "all unused", not just dangling.
func (c *Client) Prune(target string, all bool) (PruneResult, error) {
	var res PruneResult
	var data []byte
	var code int
	var err error
	switch target {
	case "images":
		filters := `{"dangling":{"false":true}}`
		if !all {
			filters = `{"dangling":{"true":true}}`
		}
		data, code, err = c.do("POST", "/images/prune?filters="+filters, nil)
	case "volumes":
		data, code, err = c.do("POST", "/volumes/prune", nil)
	case "build-cache":
		data, code, err = c.do("POST", "/build/prune", nil)
	case "containers":
		data, code, err = c.do("POST", "/containers/prune", nil)
	default:
		return res, fmt.Errorf("unknown prune target %q", target)
	}
	if err != nil {
		return res, err
	}
	if code >= 400 {
		return res, fmt.Errorf("docker prune %s: HTTP %d", target, code)
	}
	var raw struct {
		SpaceReclaimed uint64 `json:"SpaceReclaimed"`
	}
	_ = json.Unmarshal(data, &raw)
	res.ReclaimedBytes = raw.SpaceReclaimed
	return res, nil
}

// SocketPath returns the docker socket path or "" when absent.
func SocketPath() string {
	for _, p := range []string{"/var/run/docker.sock", os.Getenv("DOCKER_SOCK")} {
		if p == "" {
			continue
		}
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}
	return ""
}
