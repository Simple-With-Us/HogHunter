package autoclean

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"sync"
	"time"
)

// CleanupHistoryRecord is one finished autoclean run, appended to
// cleanup-history.jsonl.  The field names mirror the Mac app's
// CleanupHistoryRecord (Sources/Storage/CleanupHistoryStore.swift) —
// cleaned_at, bytes_reclaimed, items_removed, category_ids, item_titles —
// so a reader built for one platform's history reads the other's.  The
// Linux record adds per-category detail and the trigger that fired,
// because an unattended run has to explain itself after the fact.
type CleanupHistoryRecord struct {
	CleanedAt      time.Time `json:"cleaned_at"`
	BytesReclaimed uint64    `json:"bytes_reclaimed"`
	ItemsRemoved   int       `json:"items_removed"`
	// Tier is the Mac schema's run-kind field; autoclean runs are always
	// "automatic".
	Tier string `json:"tier"`
	// CategoryIDs lists the categories that removed something, in run
	// order.
	CategoryIDs []string `json:"category_ids"`
	// ItemTitles names what was removed, capped at 50 like the Mac store.
	ItemTitles []string `json:"item_titles"`
	// Source is who started the run: "autoclean" for the daemon loop, a
	// device id or "local" for an API/CLI run.  Matches the Mac field.
	Source string `json:"source,omitempty"`
	// Trigger describes the disk state that fired the run.
	Trigger string `json:"trigger,omitempty"`
	// Categories carries the per-category outcome for this run.
	Categories []CategoryResult `json:"categories,omitempty"`
	// DryRun marks a report-only run.  Dry runs are recorded in the audit
	// log only, never here — history mirrors reclaimed space, and a dry
	// run reclaims nothing (the Mac store's rule).
	DryRun bool `json:"dry_run,omitempty"`
}

var historyMu sync.Mutex

// AppendHistory appends one record to the history file at path,
// creating parent directories as needed.  Append-only, one JSON object
// per line, under a lock — the same discipline as the Mac store and the
// audit log, so a crash loses at most the in-flight record.
func AppendHistory(path string, rec CleanupHistoryRecord) error {
	historyMu.Lock()
	defer historyMu.Unlock()
	data, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(data, '\n'))
	return err
}

// ReadHistory reads every record, newest first.  A missing file reads as
// empty, and a line that fails to decode is skipped — a half-written row
// must never brick the reader (the Mac store's rule).  Lines are read
// with an unbounded reader, not a capped scanner: a single oversized
// legacy line must not fail every later read.
func ReadHistory(path string) ([]CleanupHistoryRecord, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []CleanupHistoryRecord
	rd := bufio.NewReader(f)
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			var rec CleanupHistoryRecord
			if jerr := json.Unmarshal(line, &rec); jerr == nil {
				out = append(out, rec)
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, nil
}
