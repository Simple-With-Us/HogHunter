// Package auth is the hh-agent device-token store and pairing-request
// ledger.  Raw tokens exist only in memory, on approval output, and in the
// caller's transport; on disk we persist SHA-256 hashes only.  Token values
// are never logged.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	// TokenPrefix is the hh1_ convention shared with the Mac app.
	TokenPrefix = "hh1_"
	// tokenEntropyBytes is 24 bytes = 192 bits, the Mac-app convention.
	tokenEntropyBytes = 24
	// PairRequestTTL is how long a pairing request waits for CLI approval.
	PairRequestTTL = 15 * time.Minute
	// MaxPendingRequests caps the pairing ledger.
	MaxPendingRequests = 20
)

// Device is one paired device.  Only the hash of its token is stored.
type Device struct {
	DeviceID    string `json:"device_id"`
	DeviceName  string `json:"device_name"`
	TokenSHA256 string `json:"token_sha256"` // hex of SHA-256(token)
	CreatedAt   string `json:"created_at"`   // RFC3339
	Revoked     bool   `json:"revoked"`
}

// PairRequest is a pending new-device pairing request awaiting CLI approval.
type PairRequest struct {
	RequestID   string `json:"request_id"`
	DeviceName  string `json:"device_name"`
	RemoteAddr  string `json:"remote_addr"`
	RequestedAt string `json:"requested_at"` // RFC3339
	ExpiresAt   string `json:"expires_at"`   // RFC3339
}

// Expired reports whether the request is past its TTL.
func (p *PairRequest) Expired(now time.Time) bool {
	t, err := time.Parse(time.RFC3339, p.ExpiresAt)
	if err != nil {
		return true
	}
	return !now.Before(t)
}

// Store holds paired devices and pending pairing requests on disk.
type Store struct {
	mu       sync.Mutex
	dir      string
	devices  map[string]*Device      // deviceID -> Device
	requests map[string]*PairRequest // requestID -> PairRequest
}

// Open loads (or creates) the token store under dir.  Files are created
// with mode 0600.  dir is created when missing.
func Open(dir string) (*Store, error) {
	if dir == "" {
		dir = DefaultDir()
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, fmt.Errorf("auth state dir: %w", err)
	}
	s := &Store{
		dir:      dir,
		devices:  map[string]*Device{},
		requests: map[string]*PairRequest{},
	}
	if err := s.loadFile("devices.json", &s.devices); err != nil {
		return nil, err
	}
	if err := s.loadFile("pair-requests.json", &s.requests); err != nil {
		return nil, err
	}
	s.pruneExpiredLocked(time.Now())
	return s, nil
}

// DefaultDir is the state directory when none is configured.
func DefaultDir() string {
	if d := os.Getenv("HH_AGENT_STATE_DIR"); d != "" {
		return d
	}
	return "/var/lib/hh-agent"
}

func (s *Store) devicesPath() string  { return filepath.Join(s.dir, "devices.json") }
func (s *Store) requestsPath() string { return filepath.Join(s.dir, "pair-requests.json") }

func (s *Store) loadFile(name string, v any) error {
	path := filepath.Join(s.dir, name)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("auth %s: %w", name, err)
	}
	if len(data) == 0 {
		return nil
	}
	if err := json.Unmarshal(data, v); err != nil {
		return fmt.Errorf("auth %s: %w", name, err)
	}
	return nil
}

// saveFileLocked writes JSON atomically with mode 0600.
func (s *Store) saveFileLocked(name string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(s.dir, name)
	tmp, err := os.CreateTemp(s.dir, name+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

// MintToken generates a cryptographically random device token: hh1_
// followed by 192 bits of base64url entropy.  The raw token is returned
// only here; callers must show it once and then drop it.
func MintToken() (string, error) {
	buf := make([]byte, tokenEntropyBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("mint token: %w", err)
	}
	return TokenPrefix + base64.RawURLEncoding.EncodeToString(buf), nil
}

// HashToken returns the hex SHA-256 of a token.  This is what we store.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// randomID makes a short unique id with the given prefix.
func randomID(prefix string) (string, error) {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("random id: %w", err)
	}
	return prefix + hex.EncodeToString(buf), nil
}

// Verify reports whether token is a known, non-revoked device token,
// comparing hashes in constant time.  It returns the device record.
func (s *Store) Verify(token string) (*Device, bool) {
	if token == "" {
		return nil, false
	}
	want := HashToken(token)
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, d := range s.devices {
		if d.Revoked {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(d.TokenSHA256), []byte(want)) == 1 {
			c := *d
			return &c, true
		}
	}
	return nil, false
}

// VerifyBearer parses an "Authorization: Bearer <token>" header and
// verifies it.  Empty or malformed headers fail closed.
func (s *Store) VerifyBearer(header string) (*Device, bool) {
	const scheme = "Bearer "
	if len(header) <= len(scheme) || header[:len(scheme)] != scheme {
		return nil, false
	}
	return s.Verify(trimSpace(header[len(scheme):]))
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t' || s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}

// AddDevice records a new paired device, storing only the token's SHA-256
// hash.  The raw token is never persisted.  It returns the device record.
func (s *Store) AddDevice(name, token string) (*Device, error) {
	if token == "" {
		return nil, fmt.Errorf("empty token")
	}
	id, err := randomID("dev_")
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.devices[id]; exists {
		return nil, fmt.Errorf("device id collision; retry")
	}
	d := &Device{
		DeviceID:    id,
		DeviceName:  name,
		TokenSHA256: HashToken(token),
		CreatedAt:   time.Now().UTC().Format(time.RFC3339),
		Revoked:     false,
	}
	s.devices[id] = d
	if err := s.saveFileLocked("devices.json", s.devices); err != nil {
		delete(s.devices, id)
		return nil, err
	}
	c := *d
	return &c, nil
}

// Revoke marks a device revoked so its token stops working immediately.
func (s *Store) Revoke(deviceID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[deviceID]
	if !ok {
		return fmt.Errorf("no such device")
	}
	d.Revoked = true
	return s.saveFileLocked("devices.json", s.devices)
}

// ListDevices returns copies of all device records.
func (s *Store) ListDevices() []*Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*Device, 0, len(s.devices))
	for _, d := range s.devices {
		c := *d
		out = append(out, &c)
	}
	return out
}

// RequestPairing creates a pending pairing request with a 15-minute TTL.
func (s *Store) RequestPairing(deviceName, remoteAddr string) (*PairRequest, error) {
	if len(deviceName) == 0 || len(deviceName) > 120 {
		return nil, fmt.Errorf("device_name must be 1-120 characters")
	}
	host, _, _ := net.SplitHostPort(remoteAddr)
	if host == "" {
		host = remoteAddr
	}
	id, err := randomID("pr_")
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneExpiredLocked(now)
	if len(s.requests) >= MaxPendingRequests {
		return nil, fmt.Errorf("too many pending requests")
	}
	p := &PairRequest{
		RequestID:   id,
		DeviceName:  deviceName,
		RemoteAddr:  host,
		RequestedAt: now.Format(time.RFC3339),
		ExpiresAt:   now.Add(PairRequestTTL).Format(time.RFC3339),
	}
	s.requests[id] = p
	if err := s.saveFileLocked("pair-requests.json", s.requests); err != nil {
		delete(s.requests, id)
		return nil, err
	}
	c := *p
	return &c, nil
}

// PendingRequests returns copies of all unexpired requests.
func (s *Store) PendingRequests() []*PairRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneExpiredLocked(time.Now())
	out := make([]*PairRequest, 0, len(s.requests))
	for _, p := range s.requests {
		c := *p
		out = append(out, &c)
	}
	return out
}

// TakeRequest removes and returns a pending request (approval or denial).
func (s *Store) TakeRequest(requestID string) (*PairRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.requests[requestID]
	if !ok {
		return nil, fmt.Errorf("no such pairing request")
	}
	if p.Expired(time.Now()) {
		delete(s.requests, requestID)
		_ = s.saveFileLocked("pair-requests.json", s.requests)
		return nil, fmt.Errorf("pairing request expired")
	}
	delete(s.requests, requestID)
	if err := s.saveFileLocked("pair-requests.json", s.requests); err != nil {
		return nil, err
	}
	c := *p
	return &c, nil
}

func (s *Store) pruneExpiredLocked(now time.Time) {
	for id, p := range s.requests {
		if p.Expired(now) {
			delete(s.requests, id)
		}
	}
}

// RateLimiter is a small per-IP sliding-window limiter for the
// unauthenticated pair-request route.
type RateLimiter struct {
	mu     sync.Mutex
	hits   map[string][]time.Time
	max    int
	window time.Duration
}

// NewRateLimiter allows max requests per window per client IP.
func NewRateLimiter(max int, window time.Duration) *RateLimiter {
	return &RateLimiter{hits: map[string][]time.Time{}, max: max, window: window}
}

// Allow reports whether ip may make another request now.
func (rl *RateLimiter) Allow(ip string) bool {
	now := time.Now()
	rl.mu.Lock()
	defer rl.mu.Unlock()
	cutoff := now.Add(-rl.window)
	kept := rl.hits[ip][:0]
	for _, t := range rl.hits[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= rl.max {
		rl.hits[ip] = kept
		return false
	}
	rl.hits[ip] = append(kept, now)
	return true
}

// ClientIP extracts the host part of a RemoteAddr.
func ClientIP(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}
