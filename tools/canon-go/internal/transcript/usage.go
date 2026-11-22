// Package transcript reads token usage out of the harnesses' own session files (Claude Code's transcripts, Copilot's session record):
// one line reader and one line parser, shared by the board's token-spend (t-0829) and the daemon's session meter (t-d00c). It only
// parses lines; what a call belongs to (a phase, a gate, a sprint) is the caller's business. Nothing here keeps transcript text.
package transcript

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"os"
)

// MaxLine bounds one session-file line (a line holds whole tool results). A var: the tests lower it.
var MaxLine = 64 << 20

// NextLine returns the next line without its newline; nil for a line longer than MaxLine (read past and dropped);
// more is false at the end of the file or on a read error. A last line without a newline is returned.
func NextLine(br *bufio.Reader) (line []byte, more bool) {
	var buf []byte
	tooLong := false
	for {
		part, err := br.ReadSlice('\n')
		if !tooLong {
			if len(buf)+len(part) > MaxLine {
				tooLong, buf = true, nil
			} else {
				buf = append(buf, part...)
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil && len(part) == 0 && len(buf) == 0 && !tooLong {
			return nil, false
		}
		if tooLong {
			return nil, true
		}
		return bytes.TrimRight(buf, "\r\n"), true
	}
}

// EachLine calls fn with every line of path that fits MaxLine, in order; a file that cannot be opened has none. An over-long line
// is skipped and the file read on past it.
func EachLine(path string, fn func(line []byte)) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	br := bufio.NewReaderSize(f, 1<<20)
	for {
		line, more := NextLine(br)
		if !more {
			return
		}
		if line != nil {
			fn(line)
		}
	}
}

// Assistant is the part of one Claude Code transcript line that token accounting needs.
type Assistant struct {
	ID       string // message.id: Claude Code writes each content block of one API message as its own line, all with this id
	Model    string
	TS       string // the line's timestamp, as written
	CWD      string // the line's cwd as written between its quotes (JSON escapes kept), "" when absent
	HasUsage bool
	// the message's usage: In is input_tokens (fresh, not cached)
	In, CacheWrite, CacheRead, Out int64
	CacheWrite5m, CacheWrite1h     int64    // t-0abe: the cache write's TTL split, when the usage has one (0, 0 otherwise)
	ToolUses                       []string // the id of each tool_use block
	ToolNames                      []string // t-0abe: each tool_use block's name, in ToolUses' order
}

// Context is the call's whole context: fresh input plus the cache tokens it wrote and read.
func (a Assistant) Context() int64 { return a.In + a.CacheWrite + a.CacheRead }

type assistantLine struct {
	Type      string          `json:"type"`
	Timestamp string          `json:"timestamp"`
	CWD       json.RawMessage `json:"cwd"`
	Message   struct {
		ID      string          `json:"id"`
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
		Usage   *struct {
			In     int64 `json:"input_tokens"`
			Create int64 `json:"cache_creation_input_tokens"`
			Read   int64 `json:"cache_read_input_tokens"`
			Out    int64 `json:"output_tokens"`
			Split  struct {
				M5 int64 `json:"ephemeral_5m_input_tokens"`
				H1 int64 `json:"ephemeral_1h_input_tokens"`
			} `json:"cache_creation"`
		} `json:"usage"`
	} `json:"message"`
}

// ParseAssistant decodes one transcript line; ok is false for a line that is not JSON or not an assistant line (skipped, never fatal).
// A raw control byte inside a string (invalid JSON, but seen in a hostile cwd) is read as '?'.
func ParseAssistant(raw []byte) (Assistant, bool) {
	var l assistantLine
	if err := json.Unmarshal(raw, &l); err != nil {
		var typeErr *json.UnmarshalTypeError
		if errors.As(err, &typeErr) { // a field of another shape: the line is not a usable assistant line
			return Assistant{}, false
		}
		clean := bytes.Map(func(r rune) rune {
			if r < 0x20 {
				return '?'
			}
			return r
		}, raw)
		l = assistantLine{}
		if json.Unmarshal(clean, &l) != nil {
			return Assistant{}, false
		}
	}
	if l.Type != "assistant" {
		return Assistant{}, false
	}
	a := Assistant{ID: l.Message.ID, Model: l.Message.Model, TS: l.Timestamp}
	if c := l.CWD; len(c) >= 2 && c[0] == '"' && c[len(c)-1] == '"' {
		a.CWD = string(c[1 : len(c)-1])
	}
	if u := l.Message.Usage; u != nil {
		a.HasUsage, a.In, a.CacheWrite, a.CacheRead, a.Out = true, u.In, u.Create, u.Read, u.Out
		a.CacheWrite5m, a.CacheWrite1h = u.Split.M5, u.Split.H1
	}
	var blocks []struct {
		Type string `json:"type"`
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	_ = json.Unmarshal(l.Message.Content, &blocks) // a string or absent content has no blocks
	for _, b := range blocks {
		if b.Type == "tool_use" {
			a.ToolUses = append(a.ToolUses, b.ID)
			a.ToolNames = append(a.ToolNames, b.Name)
		}
	}
	return a, true
}

// User is the part of one Claude Code user line that token accounting needs (t-0abe): Prompt is true for something the person
// sent (string content, or a text block and no tool_result); a tool result, a meta line or a sidechain line is not a prompt.
type User struct {
	TS, CWD, UUID string // UUID: the line's own id, the same in a resumed session's copy of the line
	Prompt        bool
}

// ParseUser decodes one transcript line; ok is false for a line that is not JSON or not a user line.
func ParseUser(raw []byte) (User, bool) {
	var l struct {
		Type      string          `json:"type"`
		Timestamp string          `json:"timestamp"`
		UUID      string          `json:"uuid"`
		CWD       json.RawMessage `json:"cwd"`
		IsMeta    bool            `json:"isMeta"`
		Sidechain bool            `json:"isSidechain"`
		Message   struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(raw, &l) != nil || l.Type != "user" {
		return User{}, false
	}
	u := User{TS: l.Timestamp, UUID: l.UUID}
	if c := l.CWD; len(c) >= 2 && c[0] == '"' && c[len(c)-1] == '"' {
		u.CWD = string(c[1 : len(c)-1])
	}
	if l.IsMeta || l.Sidechain {
		return u, true
	}
	if c := bytes.TrimSpace(l.Message.Content); len(c) > 0 && c[0] == '"' {
		u.Prompt = true
		return u, true
	}
	var blocks []struct {
		Type string `json:"type"`
	}
	_ = json.Unmarshal(l.Message.Content, &blocks)
	text := false
	for _, b := range blocks {
		if b.Type == "tool_result" {
			return u, true
		}
		text = text || b.Type == "text"
	}
	u.Prompt = text
	return u, true
}
