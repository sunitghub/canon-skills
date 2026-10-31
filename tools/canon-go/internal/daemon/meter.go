package daemon

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"sync"
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

type meterEntry struct {
	sig string
	m   sessionMeter
}

var (
	meterMu    sync.Mutex
	meterCache = map[string]meterEntry{}
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
// /sessions is polled, so a result is reused until a transcript's size or mtime changes.
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
	for _, f := range files {
		if st, err := os.Stat(f); err == nil {
			sig += f + "|" + st.ModTime().String() + "|" + strconv.FormatInt(st.Size(), 10) + ";"
		}
	}
	meterMu.Lock()
	if e, ok := meterCache[sid]; ok && e.sig == sig {
		meterMu.Unlock()
		return &e.m
	}
	meterMu.Unlock()
	m := sessionMeter{SubAgents: len(subs)}
	var fresh, cread int64
	seen := map[string]bool{}
	// Sub-agent files first so a message id in both counts once, as token-spend does.
	for i := len(files) - 1; i >= 0; i-- {
		meterScan(files[i], seen, &m, &fresh, &cread)
	}
	if fresh+cread > 0 {
		m.CachePct = int(cread * 100 / (fresh + cread))
	}
	meterMu.Lock()
	meterCache[sid] = meterEntry{sig: sig, m: m}
	meterMu.Unlock()
	return &m
}

func meterScan(path string, seen map[string]bool, m *sessionMeter, fresh, cread *int64) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20) // tool results make lines huge
	for sc.Scan() {
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
		if json.Unmarshal(sc.Bytes(), &line) != nil || line.Type != "assistant" {
			continue
		}
		id := line.Message.ID
		if id == "" { // synthetic turns have no msg_ id
			continue
		}
		// Claude Code writes each content block of one API message as its own line, all with the message's id and usage: the call
		// and its tokens count once per message id, each tool_use once per block id (the t-d00c review: by message id, 74% were lost).
		if !seen["m:"+id] {
			seen["m:"+id] = true
			m.LLMCalls++
			*fresh += line.Message.Usage.In + line.Message.Usage.Create
			*cread += line.Message.Usage.Read
		}
		for _, c := range line.Message.Content {
			if c.Type == "tool_use" && (c.ID == "" || !seen["t:"+c.ID]) {
				seen["t:"+c.ID] = true
				m.ToolCalls++
			}
		}
	}
}
