package transcript

import (
	"bufio"
	"strings"
	"testing"
)

// Protects: sprint token-spend and the daemon's session meter (both read Claude Code transcripts through ParseAssistant).
func TestParseAssistant(t *testing.T) {
	line := `{"type":"assistant","timestamp":"2026-10-01T10:10:00.000Z","cwd":"/p/x","message":{"id":"msg_1","model":"m","content":[{"type":"text","text":"x"},{"type":"tool_use","id":"toolu_1"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":9,"cache_read_input_tokens":1000,"output_tokens":10,"iterations":[{"input_tokens":99999}]}}}`
	a, ok := ParseAssistant([]byte(line))
	if !ok || a.ID != "msg_1" || a.Model != "m" || a.CWD != "/p/x" || !a.HasUsage || a.In != 3 || a.CacheWrite != 9 || a.CacheRead != 1000 || a.Out != 10 {
		t.Fatalf("parsed %+v ok=%v", a, ok)
	}
	if a.Context() != 1012 || len(a.ToolUses) != 1 || a.ToolUses[0] != "toolu_1" {
		t.Fatalf("context %d tool uses %v", a.Context(), a.ToolUses)
	}
}

// Protects: sprint token-spend's step.cost tools and cost_usd (t-0abe): each tool_use's name, and the cache write's 5m/1h split.
func TestParseAssistantToolNamesAndCacheSplit(t *testing.T) {
	line := `{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_1","name":"Bash"},{"type":"tool_use","id":"toolu_2","name":"Read"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}`
	a, ok := ParseAssistant([]byte(line))
	if !ok || strings.Join(a.ToolNames, ",") != "Bash,Read" || a.CacheWrite5m != 10 || a.CacheWrite1h != 20 || a.CacheWrite != 30 {
		t.Fatalf("%+v %v", a, ok)
	}
	if a, _ := ParseAssistant([]byte(`{"type":"assistant","message":{"id":"msg_2","usage":{"cache_creation_input_tokens":7}}}`)); a.CacheWrite5m != 0 || a.CacheWrite1h != 0 || a.CacheWrite != 7 {
		t.Fatalf("no split: %+v", a)
	}
}

// Protects: sprint token-spend's step.cost user_turns (t-0abe): only what the person sent counts.
func TestParseUser(t *testing.T) {
	for line, want := range map[string]bool{
		`{"type":"user","timestamp":"T","cwd":"/p","message":{"content":"sprint continue t-1"}}`:                            true,
		`{"type":"user","message":{"content":[{"type":"text","text":"hi"}]}}`:                                               true,
		`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"x"}]}}`:              false,
		`{"type":"user","message":{"content":[{"type":"text","text":"x"},{"type":"tool_result","tool_use_id":"toolu_1"}]}}`: false,
		`{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>"}}`:                                      false,
		`{"type":"user","isSidechain":true,"message":{"content":"prompt for a subagent"}}`:                                  false,
	} {
		u, ok := ParseUser([]byte(line))
		if !ok || u.Prompt != want {
			t.Errorf("%s: prompt %v ok %v, want %v", line, u.Prompt, ok, want)
		}
	}
	if u, ok := ParseUser([]byte(`{"type":"user","uuid":"u-1","timestamp":"T","cwd":"/p","message":{"content":"x"}}`)); !ok || u.TS != "T" || u.CWD != "/p" || u.UUID != "u-1" {
		t.Errorf("fields: %+v", u)
	}
	if _, ok := ParseUser([]byte(`{"type":"assistant","message":{"content":"x"}}`)); ok {
		t.Error("an assistant line parsed as a user line")
	}
}

func TestParseAssistantSkips(t *testing.T) {
	for name, line := range map[string]string{
		"user":      `{"type":"user","message":{"content":"{\"type\":\"assistant\"}"}}`,
		"not json":  `{"type":"assistant"`,
		"empty":     ``,
		"array":     `[1,2]`,
		"bad usage": `{"type":"assistant","message":{"id":"msg_1","usage":"x"}}`,
	} {
		if a, ok := ParseAssistant([]byte(line)); ok {
			t.Errorf("%s: parsed as %+v", name, a)
		}
	}
	// no usage: still an assistant line, with HasUsage false (the caller decides)
	if a, ok := ParseAssistant([]byte(`{"type":"assistant","message":{"id":"msg_2"}}`)); !ok || a.HasUsage {
		t.Errorf("no usage: %+v %v", a, ok)
	}
}

// A raw control byte in a cwd (not valid JSON) is read as '?', as token-spend's no-match message shows it.
func TestParseAssistantControlByte(t *testing.T) {
	a, ok := ParseAssistant([]byte("{\"type\":\"assistant\",\"cwd\":\"/p\x1b[2J\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":1}}}"))
	if !ok || a.CWD != "/p?[2J" || a.In != 1 {
		t.Fatalf("%+v %v", a, ok)
	}
}

// Protects: a transcript line over the cap is skipped and the file read on past it; a last line without a newline still counts.
func TestNextLineCap(t *testing.T) {
	old := MaxLine
	MaxLine = 64
	defer func() { MaxLine = old }()
	for _, c := range []struct {
		name, in string
		want     []string // "<nil>" for a skipped line
	}{
		{"under (the newline counts)", strings.Repeat("a", 63) + "\nb\n", []string{strings.Repeat("a", 63), "b"}},
		{"over", strings.Repeat("x", 64) + "\nb\n", []string{"<nil>", "b"}},
		{"unterminated", "a\nb", []string{"a", "b"}},
		{"over across the buffer", strings.Repeat("y", 5000) + "\nz\n", []string{"<nil>", "z"}},
	} {
		br := bufio.NewReaderSize(strings.NewReader(c.in), 16)
		var got []string
		for {
			l, more := NextLine(br)
			if !more {
				break
			}
			if l == nil {
				got = append(got, "<nil>")
			} else {
				got = append(got, string(l))
			}
		}
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

// FuzzParseAssistant: transcripts are files others write (t-9a2b): no input may panic, and a refused line yields nothing.
func FuzzParseAssistant(f *testing.F) {
	f.Add([]byte(`{"type":"assistant","timestamp":"t","cwd":"/p","message":{"id":"msg_1","model":"m","content":[{"type":"tool_use","id":"a"}],"usage":{"input_tokens":1,"cache_read_input_tokens":2}}}`))
	f.Add([]byte("{\"type\":\"assistant\",\"cwd\":\"\x1b\",\"message\":{\"usage\":{}}}"))
	f.Add([]byte(`{"type":"assistant","message":{"content":"s","usage":null}}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		a, ok := ParseAssistant(b)
		if !ok && (a.ID != "" || a.HasUsage || a.In != 0) {
			t.Fatalf("a refused line left data: %+v", a)
		}
	})
}
