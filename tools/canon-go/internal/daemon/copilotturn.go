package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"
)

// t-c723: a Copilot session has no canon hook (copilot hooks are file-configured, not per-launch), so nothing ever posted
// awaiting-input for it and the t-3425 Build switch never ran. Copilot writes its own per-session log,
// <COPILOT_HOME>/session-state/<sid>/events.jsonl; the daemon reads it (never writes it) and derives the same two statuses:
//   - a main-agent assistant.turn_end whose last main-agent assistant.message asked for no tools, with no subagent running,
//     ends the response: awaiting-input, then the switch (as handleStatus does);
//   - a main-agent assistant.turn_start: running.
// A user.message or session.model_change changes nothing: the daemon's own `/model` must not cancel the continue line it
// types next. Copilot's session.idle would say this directly but is ephemeral (never written to disk).

// copilotTurnPoll is how often the log is read; copilotLineMax caps one line (a model.messages_snapshot can be large): a longer
// line is skipped whole. Vars so a test can shorten them.
var (
	copilotTurnPoll = time.Second
	copilotLineMax  = 8 << 20
)

// copilotEventsPath is the session's events.jsonl, or "" without a Copilot home or session id.
func copilotEventsPath(home, sid string) string {
	if home == "" || sid == "" {
		return ""
	}
	return filepath.Join(home, "session-state", sid, "events.jsonl")
}

// copilotTurn is the reader's state: the byte offset of the next unread line, whether a too-long line is being skipped, and what
// the events so far say about the main agent.
type copilotTurn struct {
	off       int64
	skipping  bool
	lastTools bool // the main agent's last assistant.message asked for tools
	ended     bool // the main agent's last turn ended without asking for tools
	subagents int  // subagents started and not yet completed or failed
}

// copilotEvent is the part of an events.jsonl line the reader needs; everything else is ignored.
type copilotEvent struct {
	Type    string `json:"type"`
	AgentID string `json:"agentId"`
	Data    struct {
		ToolRequests []json.RawMessage `json:"toolRequests"`
	} `json:"data"`
}

// apply folds one event into the state and returns the status it implies ("" for none).
func (t *copilotTurn) apply(e copilotEvent) string {
	switch e.Type {
	case "subagent.started":
		t.subagents++
	case "subagent.completed", "subagent.failed":
		if t.subagents > 0 {
			t.subagents--
		}
		if t.ended && t.subagents == 0 {
			return "awaiting-input"
		}
		return ""
	}
	if e.AgentID != "" { // a subagent's own turn
		return ""
	}
	switch e.Type {
	case "assistant.turn_start":
		t.ended = false
		return "running"
	case "assistant.message":
		t.lastTools = len(e.Data.ToolRequests) > 0
	case "assistant.turn_end":
		t.ended = !t.lastTools
		if t.ended && t.subagents == 0 {
			return "awaiting-input"
		}
	}
	return ""
}

// errNotRegular: the log path is not a plain file (a symlink, a FIFO, a folder): it is never opened.
var errNotRegular = errors.New("copilot events log is not a regular file")

// read consumes the whole lines written since the last call and returns the statuses they imply, in order. A partial last line
// is left for the next call; a malformed line is skipped.
func (t *copilotTurn) read(path string) ([]string, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, errNotRegular
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if ofi, err := f.Stat(); err != nil || !os.SameFile(fi, ofi) { // swapped between the Lstat and the open
		return nil, errNotRegular
	}
	if fi.Size() < t.off { // the log was replaced or truncated: start over
		t.off, t.skipping = 0, false
	}
	if _, err := f.Seek(t.off, io.SeekStart); err != nil {
		return nil, err
	}
	var out []string
	r := bufio.NewReaderSize(f, 64<<10)
	var line []byte
	var pending int64 // bytes of the current line read so far
	for {
		chunk, err := r.ReadSlice('\n')
		pending += int64(len(chunk))
		if !t.skipping {
			if len(line)+len(chunk) <= copilotLineMax {
				line = append(line, chunk...)
			} else {
				t.skipping, line = true, nil
			}
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if err != nil { // EOF: a partial line stays unread, unless it is being skipped (its bytes so far are done with)
			if t.skipping {
				t.off += pending
			}
			return out, nil
		}
		if !t.skipping {
			var e copilotEvent
			if json.Unmarshal(line, &e) == nil {
				if st := t.apply(e); st != "" {
					out = append(out, st)
				}
			}
		}
		t.off += pending
		pending, t.skipping, line = 0, false, nil
	}
}

// watchCopilotTurns reads se's events log every copilotTurnPoll until the session ends, and applies what it says. from is the
// offset to start at: the log's size at spawn for a resumed session (its old turns are history), 0 for a new one.
func (s *server) watchCopilotTurns(se *session, path string, from int64) {
	t := &copilotTurn{off: from}
	for {
		select {
		case <-se.done:
			return
		case <-time.After(copilotTurnPoll):
		}
		sts, _ := t.read(path) // not there yet, or not a regular file: try again next poll
		for _, st := range sts {
			se.setStatus(st)
			if st == "awaiting-input" {
				go s.switchToBuild(se)
			}
		}
	}
}

// copilotLogSize is the size of the log at spawn (0 when it is absent or not a regular file).
func copilotLogSize(path string) int64 {
	if fi, err := os.Lstat(path); err == nil && fi.Mode().IsRegular() {
		return fi.Size()
	}
	return 0
}
