// Package audit appends every destructive action to a JSONL audit log.
// Implemented.
package audit

import (
	"encoding/json"
	"os"
	"sync"
	"time"

	"github.com/Simple-With-Us/HogHunter/linux-companion/internal/safety"
)

// Entry is one audited action.
type Entry struct {
	At     string `json:"at"`
	Actor  string `json:"actor"`
	Action string `json:"action"`
	Target string `json:"target"`
	Detail string `json:"detail,omitempty"`
	Result string `json:"result"`
}

var mu sync.Mutex

// Log appends an entry to the audit log.  Failures to write are returned
// but never block the action they describe.
func Log(actor, action, target, detail, result string) error {
	mu.Lock()
	defer mu.Unlock()
	f, err := os.OpenFile(safety.AuditPath(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	e := Entry{
		At:     time.Now().UTC().Format(time.RFC3339),
		Actor:  actor,
		Action: action,
		Target: target,
		Detail: detail,
		Result: result,
	}
	data, err := json.Marshal(e)
	if err != nil {
		return err
	}
	_, err = f.Write(append(data, '\n'))
	return err
}
