package docker

import (
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

// testDaemon serves a scripted Docker API over a real Unix socket and
// records every request path, so tests can pin the exact requests the
// client sends — for the build-cache prune, the request IS the fix.
type testDaemon struct {
	t        *testing.T
	requests []string
	respond  func(path string) (int, string)
}

func newTestDaemon(t *testing.T, respond func(path string) (int, string)) (*Client, *testDaemon) {
	t.Helper()
	d := &testDaemon{t: t, respond: respond}
	sock := filepath.Join(t.TempDir(), "docker.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		d.requests = append(d.requests, r.Method+" "+r.URL.RequestURI())
		code, body := d.respond(r.URL.RequestURI())
		w.WriteHeader(code)
		fmt.Fprint(w, body)
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	return New(sock), d
}

func (d *testDaemon) last() string {
	if len(d.requests) == 0 {
		return ""
	}
	return d.requests[len(d.requests)-1]
}

func TestPruneBuildCacheAllUsesNegotiatedVersion(t *testing.T) {
	client, d := newTestDaemon(t, func(path string) (int, string) {
		if path == "/version" {
			return 200, `{"ApiVersion":"1.56"}`
		}
		return 200, `{"SpaceReclaimed": 42}`
	})
	res, err := client.Prune("build-cache", true)
	if err != nil {
		t.Fatal(err)
	}
	if res.ReclaimedBytes != 42 {
		t.Errorf("reclaimed=%d, want 42", res.ReclaimedBytes)
	}
	// The daemon speaks 1.56; the client negotiates up from its 1.41
	// baseline, capped at 1.45, and sends all=1 — without the version
	// bump the daemon would silently prune dangling-only.
	if got := d.last(); got != "POST /v1.45/build/prune?all=1" {
		t.Errorf("build prune request=%q, want POST /v1.45/build/prune?all=1", got)
	}
	// all=false stays a plain dangling prune on the same version.
	if _, err := client.Prune("build-cache", false); err != nil {
		t.Fatal(err)
	}
	if got := d.last(); got != "POST /v1.45/build/prune" {
		t.Errorf("dangling build prune request=%q, want POST /v1.45/build/prune", got)
	}
}

func TestPruneBuildCacheOldDaemonFallsBack(t *testing.T) {
	client, d := newTestDaemon(t, func(path string) (int, string) {
		if path == "/version" {
			return 200, `{"ApiVersion":"1.41"}`
		}
		return 200, `{"SpaceReclaimed": 1}`
	})
	if _, err := client.Prune("build-cache", true); err != nil {
		t.Fatal(err)
	}
	// A 1.41 daemon has no `all` parameter; the request stays on the
	// baseline version (and the caller's reclaimed-bytes report shows
	// the dangling-only result honestly).
	if got := d.last(); got != "POST /v1.41/build/prune?all=1" {
		t.Errorf("old-daemon build prune request=%q", got)
	}
}

func TestVersionProbeFailureIsNotCached(t *testing.T) {
	probes := 0
	client, d := newTestDaemon(t, func(path string) (int, string) {
		if path == "/version" {
			probes++
			if probes == 1 {
				return 500, `{"message":"daemon restarting"}`
			}
			return 200, `{"ApiVersion":"1.56"}`
		}
		return 200, `{"SpaceReclaimed": 1}`
	})
	// First prune: the probe fails, so the request falls back to the
	// baseline version.
	if _, err := client.Prune("build-cache", true); err != nil {
		t.Fatal(err)
	}
	if got := d.last(); got != "POST /v1.41/build/prune?all=1" {
		t.Errorf("failed-probe prune request=%q, want the v1.41 fallback", got)
	}
	// Second prune: the probe is retried, succeeds, and the negotiated
	// version applies.  A cached failure would pin v1.41 forever.
	if _, err := client.Prune("build-cache", true); err != nil {
		t.Fatal(err)
	}
	if got := d.last(); got != "POST /v1.45/build/prune?all=1" {
		t.Errorf("recovered-probe prune request=%q, want POST /v1.45/build/prune?all=1", got)
	}
	if probes != 2 {
		t.Errorf("probes=%d, want exactly 2 (failure retried, success cached)", probes)
	}
	// Third prune: the success is cached — no third probe.
	if _, err := client.Prune("build-cache", true); err != nil {
		t.Fatal(err)
	}
	if probes != 2 {
		t.Errorf("probes=%d after a success, want 2 (cached)", probes)
	}
}

func TestPruneImagesDanglingFilter(t *testing.T) {
	client, d := newTestDaemon(t, func(string) (int, string) {
		return 200, `{"SpaceReclaimed": 7}`
	})
	if _, err := client.Prune("images", false); err != nil {
		t.Fatal(err)
	}
	if got := d.last(); !strings.HasPrefix(got, "POST /v1.41/images/prune?filters=") || !strings.Contains(got, "dangling") {
		t.Errorf("images prune request=%q, want a dangling filter on the baseline version", got)
	}
}

func TestImagesAndDelete(t *testing.T) {
	client, d := newTestDaemon(t, func(path string) (int, string) {
		switch {
		case strings.HasPrefix(path, "/v1.41/images/json"):
			return 200, `[{"Id":"sha256:aaa","RepoTags":["app:gen2"],"Created":1700000000,"Size":3000},
			              {"Id":"sha256:bbb","RepoTags":["app:gen1"],"Created":1690000000,"Size":2000}]`
		case strings.HasPrefix(path, "/v1.41/images/sha256:aaa"):
			return 200, `[{"Deleted":"sha256:aaa"}]`
		case strings.HasPrefix(path, "/v1.41/images/sha256:busy"):
			return 409, `{"message":"conflict: unable to delete (must be forced) - image is being used by running container"}`
		}
		return 404, `{}`
	})
	images, err := client.Images()
	if err != nil {
		t.Fatal(err)
	}
	if len(images) != 2 || images[0].ID != "sha256:aaa" || images[0].RepoTags[0] != "app:gen2" || images[0].Size != 3000 {
		t.Fatalf("images=%+v", images)
	}
	if err := client.DeleteImage("sha256:aaa"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if got := d.last(); got != "DELETE /v1.41/images/sha256:aaa" {
		t.Errorf("delete request=%q", got)
	}
	// A 409 (container using the image) must surface as an error — the
	// retention planner's backstop depends on it.
	if err := client.DeleteImage("sha256:busy"); err == nil {
		t.Error("a 409 delete must return an error")
	}
}

func TestImageUniqueBytes(t *testing.T) {
	client, _ := newTestDaemon(t, func(string) (int, string) {
		return 200, `{"Images":[{"Size":3000,"SharedSize":1000},{"Size":2000,"SharedSize":2000},{"Size":500,"SharedSize":0}]}`
	})
	got, err := client.ImageUniqueBytes()
	if err != nil {
		t.Fatal(err)
	}
	// (3000-1000) + (2000-2000) + (500-0) = 2500.
	if got != 2500 {
		t.Errorf("unique bytes=%d, want 2500", got)
	}
}

func TestListParsesImageID(t *testing.T) {
	client, _ := newTestDaemon(t, func(string) (int, string) {
		return 200, `[{"Id":"c1","Names":["/app"],"Image":"app:gen2","ImageID":"sha256:aaa","State":"running"}]`
	})
	containers, err := client.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(containers) != 1 || containers[0].ImageID != "sha256:aaa" {
		t.Fatalf("containers=%+v, want ImageID parsed", containers)
	}
}
