package auth

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestMintTokenFormat(t *testing.T) {
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(tok, TokenPrefix) {
		t.Fatalf("token %q missing prefix %q", tok, TokenPrefix)
	}
	// 24 bytes entropy -> 32 base64url chars.
	if len(tok) != len(TokenPrefix)+32 {
		t.Fatalf("token %q has unexpected length %d", tok, len(tok))
	}
	other, _ := MintToken()
	if tok == other {
		t.Fatal("two minted tokens must not collide")
	}
}

func TestVerifyAndRevoke(t *testing.T) {
	s := testStore(t)
	tok, _ := MintToken()
	d, err := s.AddDevice("Test Device", tok)
	if err != nil {
		t.Fatal(err)
	}
	// The raw token must never appear on disk.
	data, _ := os.ReadFile(filepath.Join(s.dir, "devices.json"))
	if strings.Contains(string(data), tok) {
		t.Fatal("raw token persisted to devices.json")
	}
	// File permissions: owner-only.
	fi, _ := os.Stat(filepath.Join(s.dir, "devices.json"))
	if fi.Mode().Perm() != 0600 {
		t.Fatalf("devices.json mode = %o, want 600", fi.Mode().Perm())
	}
	// Verify works.
	got, ok := s.Verify(tok)
	if !ok || got.DeviceID != d.DeviceID || got.DeviceName != "Test Device" {
		t.Fatalf("verify failed: %+v %v", got, ok)
	}
	// Wrong token rejected.
	if _, ok := s.Verify(tok + "x"); ok {
		t.Fatal("corrupted token must not verify")
	}
	if _, ok := s.Verify(""); ok {
		t.Fatal("empty token must not verify")
	}
	// Bearer header parsing.
	if _, ok := s.VerifyBearer("Bearer " + tok); !ok {
		t.Fatal("bearer header must verify")
	}
	if _, ok := s.VerifyBearer("Token " + tok); ok {
		t.Fatal("non-bearer scheme must fail")
	}
	if _, ok := s.VerifyBearer("Bearer "); ok {
		t.Fatal("empty bearer must fail")
	}
	// Revoke cuts the token off immediately.
	if err := s.Revoke(d.DeviceID); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Verify(tok); ok {
		t.Fatal("revoked device token must not verify")
	}
	// Reload from disk keeps the revocation.
	s2, err := Open(s.dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := s2.Verify(tok); ok {
		t.Fatal("revocation must survive reload")
	}
}

func TestPairingTTL(t *testing.T) {
	s := testStore(t)
	p, err := s.RequestPairing("Jay's Mac", "100.64.0.1:54321")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(p.RequestID, "pr_") {
		t.Fatalf("bad request id %q", p.RequestID)
	}
	if len(s.PendingRequests()) != 1 {
		t.Fatal("expected one pending request")
	}
	// Approval takes the request.
	got, err := s.TakeRequest(p.RequestID)
	if err != nil {
		t.Fatal(err)
	}
	if got.DeviceName != "Jay's Mac" || got.RemoteAddr != "100.64.0.1" {
		t.Fatalf("bad request record: %+v", got)
	}
	if _, err := s.TakeRequest(p.RequestID); err == nil {
		t.Fatal("double-approve must fail")
	}
	// Expired requests prune on access.
	p2, err := s.RequestPairing("Phone", "100.64.0.2:1")
	if err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	exp := *s.requests[p2.RequestID]
	exp.ExpiresAt = time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	s.requests[p2.RequestID] = &exp
	s.mu.Unlock()
	if len(s.PendingRequests()) != 0 {
		t.Fatal("expired request must be pruned")
	}
}

func TestPairingValidation(t *testing.T) {
	s := testStore(t)
	if _, err := s.RequestPairing("", "1.2.3.4:5"); err == nil {
		t.Fatal("empty device name must be rejected")
	}
	if _, err := s.RequestPairing(strings.Repeat("x", 121), "1.2.3.4:5"); err == nil {
		t.Fatal("oversized device name must be rejected")
	}
}

func TestRateLimiter(t *testing.T) {
	rl := NewRateLimiter(3, time.Hour)
	for i := 0; i < 3; i++ {
		if !rl.Allow("10.0.0.1") {
			t.Fatalf("request %d should be allowed", i)
		}
	}
	if rl.Allow("10.0.0.1") {
		t.Fatal("4th request in window must be denied")
	}
	// Another IP is unaffected.
	if !rl.Allow("10.0.0.2") {
		t.Fatal("different IP must be allowed")
	}
}
