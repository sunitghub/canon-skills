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
