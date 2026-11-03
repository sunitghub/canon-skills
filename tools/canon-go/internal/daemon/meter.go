package daemon

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
)

// sessionMeter is the ambient per-session figures (t-d00c): derived read-only from the claude
// transcripts token-spend already reads, held in memory only (no new file or setting).
// CachePct is cache_read / (input + cache_creation + cache_read), the same split token-spend prints.
type sessionMeter struct {
	CachePct  int `json:"cache_pct"`
	LLMCalls  int `json:"llm_calls"`
	ToolCalls int `json:"tool_calls"`
	SubAgents int `json:"sub_agents"`
}

// meterEntry is one session's running count (t-c21a): /sessions is polled every 5 s while the transcript grows, so each file
// is read on from the end of its last complete line instead of from the start. seen, fresh and cread carry the dedupe and the
// token sums across reads, so the counts equal a full scan of the same files.
type meterEntry struct {
	sig          string
	m            sessionMeter
	files        map[string]meterFile
	seen         map[string]bool
	fresh, cread int64
}

type meterFile struct {
	fi  os.FileInfo
	off int64 // bytes counted: through the last newline read
}

var (
	meterMu        sync.Mutex
	meterCache     = map[string]*meterEntry{}
	meterReadBytes atomic.Int64 // transcript bytes read, for the tests and the polling budget
)

func claudeConfigDir() string {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude")
}

// meterFor returns the meter for a claude session id, or nil when its transcript is missing.
// /sessions is polled: an unchanged set of files (size and mtime) is served from the cache; a grown file is read only past its
// last counted line; a file that shrank, was replaced or went away, or a new one, starts the count again from the start.
func meterFor(sid string) *sessionMeter {
	dir := claudeConfigDir()
	if sid == "" || dir == "" {
		return nil
	}
	mains, err := filepath.Glob(filepath.Join(dir, "projects", "*", sid+".jsonl"))
	if err != nil || len(mains) == 0 {
		return nil
	}
	subs, _ := filepath.Glob(filepath.Join(filepath.Dir(mains[0]), sid, "subagents", "agent-*.jsonl"))
	files := append([]string{mains[0]}, subs...)
	sig := ""
	stats := map[string]os.FileInfo{}
	for _, f := range files {
		if st, err := os.Stat(f); err == nil {
			stats[f] = st
			sig += f + "|" + st.ModTime().String() + "|" + strconv.FormatInt(st.Size(), 10) + ";"
		}
	}
	meterMu.Lock()
	defer meterMu.Unlock() // one reader per daemon: two polls never read the same bytes twice
	e := meterCache[sid]
	if e != nil && e.sig == sig {
		m := e.m
		return &m
	}
	if e == nil || !meterContinues(e, stats) {
		e = &meterEntry{files: map[string]meterFile{}, seen: map[string]bool{}}
	}
	e.m.SubAgents = len(subs)
	// Sub-agent files first so a message id in both counts once, as token-spend does.
	for i := len(files) - 1; i >= 0; i-- {
		st, ok := stats[files[i]]
		if !ok {
			continue
		}
		f := e.files[files[i]]
		e.files[files[i]] = meterFile{st, meterScan(files[i], f.off, e)}
	}
	e.m.CachePct = 0
	if e.fresh+e.cread > 0 {
		e.m.CachePct = int(e.cread * 100 / (e.fresh + e.cread))
	}
	e.sig = sig
	meterCache[sid] = e
	m := e.m
	return &m
}

// meterContinues reports whether every counted file is still the same file, no shorter than what was counted.
func meterContinues(e *meterEntry, stats map[string]os.FileInfo) bool {
	for path, f := range e.files {
		st, ok := stats[path]
		if !ok || !os.SameFile(f.fi, st) || st.Size() < f.off {
			return false
		}
	}
	return true
}

// meterPrune drops the counts of sessions /sessions no longer lists (live: their conversation ids).
func meterPrune(live map[string]bool) {
	meterMu.Lock()
	defer meterMu.Unlock()
	for sid := range meterCache {
		if !live[sid] {
			delete(meterCache, sid)
		}
	}
}

// meterScan counts the complete lines of path after off and returns the offset after the last newline it read; a last line
// still being written is left for the next read.
func meterScan(path string, off int64, e *meterEntry) int64 {
	f, err := os.Open(path)
	if err != nil {
		return off
	}
	defer f.Close()
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		return off
	}
	rd := bufio.NewReaderSize(f, 1<<20)
	for {
		raw, err := rd.ReadBytes('\n')
		if err != nil { // EOF before a newline: not a whole line yet
			meterReadBytes.Add(int64(len(raw)))
			return off
		}
		meterReadBytes.Add(int64(len(raw)))
		off += int64(len(raw))
		meterLine(raw, e)
	}
}

func meterLine(raw []byte, e *meterEntry) {
	var line struct {
		Type    string `json:"type"`
		Message struct {
			ID      string `json:"id"`
			Content []struct {
				Type string `json:"type"`
				ID   string `json:"id"`
			} `json:"content"`
			Usage struct {
				In     int64 `json:"input_tokens"`
				Create int64 `json:"cache_creation_input_tokens"`
				Read   int64 `json:"cache_read_input_tokens"`
			} `json:"usage"`
		} `json:"message"`
	}
	if json.Unmarshal(raw, &line) != nil || line.Type != "assistant" {
		return
	}
	id := line.Message.ID
	if id == "" { // synthetic turns have no msg_ id
		return
	}
	// Claude Code writes each content block of one API message as its own line, all with the message's id and usage: the call
	// and its tokens count once per message id, each tool_use once per block id (the t-d00c review: by message id, 74% were lost).
	if !e.seen["m:"+id] {
		e.seen["m:"+id] = true
		e.m.LLMCalls++
		e.fresh += line.Message.Usage.In + line.Message.Usage.Create
		e.cread += line.Message.Usage.Read
	}
	for _, c := range line.Message.Content {
		if c.Type == "tool_use" && (c.ID == "" || !e.seen["t:"+c.ID]) {
			e.seen["t:"+c.ID] = true
			e.m.ToolCalls++
		}
	}
}
