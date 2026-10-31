package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-d00c: /sessions rows carry the meter, derived from the claude transcript with no new storage.
func TestSessionMeter(t *testing.T) {
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	dir := filepath.Join(cfg, "projects", "-x")
	sub := filepath.Join(dir, "sid1", "subagents")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	main := `{"type":"user","message":{"content":"usage text"}}
{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_a"},{"type":"tool_use","id":"toolu_b"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":10,"cache_read_input_tokens":80,"iterations":[{"input_tokens":99999}]}}}
{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_c"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":10,"cache_read_input_tokens":80}}}
{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_c"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":10,"cache_read_input_tokens":80}}}
{"type":"assistant","message":{"content":[],"usage":{"input_tokens":5}}}
`
	agent := `{"type":"assistant","message":{"id":"msg_2","content":[{"type":"tool_use","id":"toolu_d"}],"usage":{"input_tokens":0,"cache_read_input_tokens":0}}}
`
	os.WriteFile(filepath.Join(dir, "sid1.jsonl"), []byte(main), 0o644)
	os.WriteFile(filepath.Join(sub, "agent-a.jsonl"), []byte(agent), 0o644)
	m := meterFor("sid1")
	// msg_1 is one API call written as three lines (one per content block, as Claude Code writes them): its tokens count once,
	// each tool_use block once (toolu_a, toolu_b, toolu_c; the repeated toolu_c line is the same block); the sub-agent adds 1.
	if m == nil || m.LLMCalls != 2 || m.ToolCalls != 4 || m.SubAgents != 1 || m.CachePct != 80 {
		t.Fatalf("meter = %+v, want calls 2, tools 4, sub-agents 1, cache 80%%", m)
	}
	if meterFor("nosuch") != nil {
		t.Fatal("a session without a transcript must have no meter")
	}
}

// t-d00c: the meter is recounted when a transcript grows (the cache is keyed on size and mtime), a session with no input
// tokens reads 0% without dividing by zero, a tool result line past bufio's default 64 KB does not end the scan, and a
// line that is not an assistant turn never counts, even with a message id.
func TestSessionMeterEdges(t *testing.T) {
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	dir := filepath.Join(cfg, "projects", "-x")
	os.MkdirAll(dir, 0o755)
	f := filepath.Join(dir, "sid2.jsonl")
	huge := `{"type":"user","message":{"content":"` + strings.Repeat("x", 200<<10) + `"}}`
	os.WriteFile(f, []byte(huge+"\n"+`{"type":"user","message":{"id":"msg_u","content":[{"type":"tool_use"}]}}`+"\n"+
		`{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use"}]}}`+"\n"), 0o644)
	if m := meterFor("sid2"); m == nil || m.LLMCalls != 1 || m.ToolCalls != 1 || m.CachePct != 0 {
		t.Fatalf("meter = %+v, want 1 call, 1 tool, 0%% cache (a huge line skipped, a user line with an id not counted)", m)
	}
	af, _ := os.OpenFile(f, os.O_APPEND|os.O_WRONLY, 0)
	af.WriteString(`{"type":"assistant","message":{"id":"msg_2","content":[],"usage":{"input_tokens":1,"cache_read_input_tokens":3}}}` + "\n")
	af.Close()
	if m := meterFor("sid2"); m == nil || m.LLMCalls != 2 || m.CachePct != 75 {
		t.Fatalf("after the transcript grew: meter = %+v, want 2 calls, 75%% cache", m)
	}
	if m := meterFor("sid2"); m == nil || m.LLMCalls != 2 { // unchanged: served from the cache, and the lock was released
		t.Fatalf("unchanged transcript: meter = %+v", m)
	}
	// with CLAUDE_CONFIG_DIR unset the transcripts are under ~/.claude
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, ".claude", "projects", "-y"), 0o755)
	os.WriteFile(filepath.Join(home, ".claude", "projects", "-y", "sid3.jsonl"), []byte(`{"type":"assistant","message":{"id":"msg_3","content":[]}}`+"\n"), 0o644)
	if m := meterFor("sid3"); m == nil || m.LLMCalls != 1 {
		t.Fatalf("meter under ~/.claude = %+v, want 1 call", m)
	}
}
