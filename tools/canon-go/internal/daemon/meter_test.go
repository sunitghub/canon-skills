package daemon

import (
	"os"
	"path/filepath"
	"strconv"
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

// t-c21a: /sessions is polled every 5 s while a transcript grows, so the meter reads only what was appended after its last
// complete line. Every step's counts must equal a fresh full scan of the same files (fullMeter), and the bytes read must be
// what the step added: 0 when unchanged, the appended length after an append, the whole file after a shrink or a replace.
func TestSessionMeterIncremental(t *testing.T) {
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	dir := filepath.Join(cfg, "projects", "-x")
	sub := filepath.Join(dir, "sid4", "subagents")
	os.MkdirAll(sub, 0o755)
	f := filepath.Join(dir, "sid4.jsonl")
	line := func(id, tool string, in, read int) string {
		return `{"type":"assistant","message":{"id":"` + id + `","content":[{"type":"tool_use","id":"` + tool + `"}],"usage":{"input_tokens":` +
			strconv.Itoa(in) + `,"cache_read_input_tokens":` + strconv.Itoa(read) + `}}}` + "\n"
	}
	appendTo := func(path, s string) {
		af, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		af.WriteString(s)
		af.Close()
	}
	// fullMeter is the meter of a cold cache: what the pre-t-c21a full scan returned for the same files.
	fullMeter := func() sessionMeter {
		meterMu.Lock()
		saved := meterCache["sid4"]
		delete(meterCache, "sid4")
		meterMu.Unlock()
		m := meterFor("sid4")
		meterMu.Lock()
		meterCache["sid4"] = saved
		meterMu.Unlock()
		return *m
	}
	step := func(name string, wantRead int64) {
		t.Helper()
		before := meterReadBytes.Load()
		m := meterFor("sid4")
		read := meterReadBytes.Load() - before
		if m == nil {
			t.Fatalf("%s: no meter", name)
		}
		if full := fullMeter(); *m != full {
			t.Fatalf("%s: incremental %+v != full scan %+v", name, *m, full)
		}
		if wantRead >= 0 && read != wantRead {
			t.Fatalf("%s: read %d bytes, want %d", name, read, wantRead)
		}
	}
	first := line("msg_1", "toolu_1", 10, 30) + line("msg_1", "toolu_2", 10, 30)
	appendTo(f, first)
	step("first read", int64(len(first)))
	step("unchanged", 0)
	more := line("msg_2", "toolu_3", 1, 3) +
		`{"type":"assistant","message":{"id":"msg_0","content":[{"type":"tool_use"},{"type":"tool_use"}],"usage":{"input_tokens":0}}}` + "\n" // two blocks with no id: each counts
	appendTo(f, more)
	step("append", int64(len(more)))
	partial := `{"type":"assistant","message":{"id":"msg_3","con`
	appendTo(f, partial)
	step("a last line still being written", int64(len(partial))) // read, not counted, and not consumed
	step("unchanged while a line is half written", 0)            // same size and mtime: served from the cache, nothing re-read
	rest := `tent":[{"type":"tool_use","id":"toolu_4"}],"usage":{"input_tokens":2}}}` + "\n"
	appendTo(f, rest)
	step("the line completed", int64(len(partial)+len(rest)))
	agent := line("msg_2", "toolu_3", 1, 3) + line("msg_9", "toolu_9", 4, 4) // msg_2/toolu_3 also in the main file: counted once
	appendTo(filepath.Join(sub, "agent-a.jsonl"), agent)
	step("a new sub-agent file", int64(len(agent)))
	if m := meterFor("sid4"); m.SubAgents != 1 || m.LLMCalls != 5 || m.ToolCalls != 7 {
		t.Fatalf("after the sub-agent: %+v, want 1 sub-agent, 5 calls, 7 tools", *m)
	}
	os.WriteFile(f, []byte(line("msg_5", "toolu_5", 1, 1)), 0o644) // rewritten shorter: count again from the start
	step("shrunk", -1)
	repl := f + ".new"
	// msg_6's tokens differ from msg_5's, so reading on from the old offset would give another cache %.
	os.WriteFile(repl, []byte(line("msg_6", "toolu_6", 1, 99)+line("msg_7", "toolu_7", 1, 1)+strings.Repeat(" ", 200)+"\n"), 0o644)
	os.Rename(repl, f) // replaced by a longer file: another file, not more of the same one
	step("replaced", -1)
	if m := meterFor("sid4"); m.LLMCalls != 4 { // msg_6, msg_7, and the sub-agent's msg_2 and msg_9
		t.Fatalf("after the replace: %+v, want 4 calls (the old file's msg_1..3 gone)", *m)
	}
	os.Remove(filepath.Join(sub, "agent-a.jsonl")) // a counted file gone: its calls go with it
	step("a sub-agent file removed", -1)
	if m := meterFor("sid4"); m.SubAgents != 0 || m.LLMCalls != 2 {
		t.Fatalf("after the sub-agent file went: %+v, want 0 sub-agents, 2 calls", *m)
	}
	meterPrune(map[string]bool{"other": true})
	meterMu.Lock()
	_, kept := meterCache["sid4"]
	meterMu.Unlock()
	if kept {
		t.Fatal("meterPrune kept a session /sessions no longer lists")
	}
}
