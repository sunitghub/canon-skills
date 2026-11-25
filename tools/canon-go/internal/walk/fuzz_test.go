package walk

// Protects `sprint next` / `sprint approve` / `sprint gate-prompt` against crash inputs on stdin, in ticket.md and acceptance.md and
// in --evidence (t-2bfe, t-a4e8, untrusted input): no panic, and an exit-2 input never prints a next line.

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func FuzzRun(f *testing.F) {
	f.Add([]byte(pipe("on")), []byte(ticketMD), []byte(specMD), []byte(acc("code-simplifier")), false, "")
	f.Add([]byte(pipe("off")), []byte(strings.Replace(ticketMD, "priority: 1\n", "priority: 1\ndemo: true\n", 1)), []byte(""), []byte(""), true, "test-sh")
	f.Add([]byte("\x00\t\t\n\r\n"), []byte("---\n---\n"), []byte("## Verdict\n| x\n"), []byte("## Wrapup Gates\n| | |\n|"), true, ",")
	f.Fuzz(func(t *testing.T, stdin, tk, spec, accept []byte, at bool, ev string) {
		dir := filepath.Join(t.TempDir(), "t-abcd")
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(dir, "ticket.md"), tk, 0o644)
		os.WriteFile(filepath.Join(dir, "spec-review.md"), spec, 0o644)
		os.WriteFile(filepath.Join(dir, "acceptance.md"), accept, 0o644)
		os.WriteFile(filepath.Join(dir, "plan.md"), []byte(planMD), 0o644)
		args := []string{dir}
		if at {
			args = append(args, "--at", "eval")
		}
		if ev != "" {
			args = append(args, "--evidence", ev)
		}
		var out, errb bytes.Buffer
		code := Run(args, bytes.NewReader(stdin), &out, &errb)
		if code < 0 || code > 2 || (code == 2 && out.Len() != 0) || (code != 2 && errb.Len() != 0) {
			t.Fatalf("exit %d out %q err %q", code, out.String(), errb.String())
		}
	})
}
