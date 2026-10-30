package daemon

import (
	"os"
	"path/filepath"
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
{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use"},{"type":"tool_use"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":10,"cache_read_input_tokens":80,"iterations":[{"input_tokens":99999}]}}}
{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use"}],"usage":{"input_tokens":10}}}
{"type":"assistant","message":{"content":[],"usage":{"input_tokens":5}}}
`
	agent := `{"type":"assistant","message":{"id":"msg_2","content":[{"type":"tool_use"}],"usage":{"input_tokens":0,"cache_read_input_tokens":0}}}
`
	os.WriteFile(filepath.Join(dir, "sid1.jsonl"), []byte(main), 0o644)
	os.WriteFile(filepath.Join(sub, "agent-a.jsonl"), []byte(agent), 0o644)
	m := meterFor("sid1")
	if m == nil || m.LLMCalls != 2 || m.ToolCalls != 3 || m.SubAgents != 1 || m.CachePct != 80 {
		t.Fatalf("meter = %+v, want calls 2, tools 3, sub-agents 1, cache 80%%", m)
	}
	if meterFor("nosuch") != nil {
		t.Fatal("a session without a transcript must have no meter")
	}
}
