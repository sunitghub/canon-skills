package board

import (
	"reflect"
	"strings"
	"testing"
)

// Protects the board's POST /api/ticket/<id>/github/commit-push (t-32f9): a payload becomes `tkt commit-push` arguments only when every
// path is a plain relative path; anything that could be read as an option, leave the checkout or break the argv is a bad request.
func TestCommitPushArgs(t *testing.T) {
	ok := []struct {
		name    string
		payload map[string]any
		want    []string
	}{
		{"push only", map[string]any{}, []string{"commit-push", "t-ab12"}},
		{"files and message", map[string]any{"files": []any{"a.txt", "dir/b c.txt"}, "message": "chore: t-ab12 work"},
			[]string{"commit-push", "t-ab12", "--file", "a.txt", "--file", "dir/b c.txt", "--message", "chore: t-ab12 work"}},
		{"a dotted name is not ..", map[string]any{"files": []any{"..x/a", "a..b"}}, []string{"commit-push", "t-ab12", "--file", "..x/a", "--file", "a..b"}},
		{"an empty message is tkt's to refuse", map[string]any{"files": []any{"a"}, "message": ""}, []string{"commit-push", "t-ab12", "--file", "a", "--message", ""}},
	}
	for _, c := range ok {
		got, good := commitPushArgs("t-ab12", c.payload)
		if !good || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %q, %v; want %q", c.name, got, good, c.want)
		}
	}
	many := make([]any, 501)
	for i := range many {
		many[i] = "f"
	}
	if got, good := commitPushArgs("t-ab12", map[string]any{"files": many[:500]}); !good || len(got) != 2+2*500 { // 500 is the limit, allowed
		t.Errorf("500 files: refused or wrong (%d args, %v)", len(got), good)
	}
	if _, good := commitPushArgs("t-ab12", map[string]any{"files": []any{strings.Repeat("a", 4096)}}); !good { // and so is a 4096-byte path
		t.Error("a 4096-byte path was refused")
	}
	bad := map[string]map[string]any{
		"files not a list":     {"files": "a.txt"},
		"a file not a string":  {"files": []any{1.0}},
		"empty path":           {"files": []any{""}},
		"an option":            {"files": []any{"-x"}},
		"absolute":             {"files": []any{"/etc/passwd"}},
		"a drive":              {"files": []any{`C:\x`}},
		"a UNC path":           {"files": []any{`\\host\share`}},
		"above the checkout":   {"files": []any{"a/../../x"}},
		"backslash ..":         {"files": []any{`a\..\x`}},
		"a NUL":                {"files": []any{"a\x00b"}},
		"a newline":            {"files": []any{"a\nb"}},
		"a carriage return":    {"files": []any{"a\rb"}},
		"too long":             {"files": []any{strings.Repeat("a", 4097)}},
		"over 500 files":       {"files": many},
		"message not a string": {"message": 3.0},
		"message with a NUL":   {"message": "a\x00b"},
	}
	for name, p := range bad {
		if got, good := commitPushArgs("t-ab12", p); good {
			t.Errorf("%s: accepted, args %q", name, got)
		}
	}
}
