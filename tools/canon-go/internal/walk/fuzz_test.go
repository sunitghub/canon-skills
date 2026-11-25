package walk

// Protects `sprint next` / `sprint approve` against crash inputs on stdin and in ticket.md (t-2bfe, untrusted input): no
// panic, and an exit-2 input never prints a next line.

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func FuzzRun(f *testing.F) {
	f.Add([]byte(pipe("on")), []byte(ticketMD), []byte(specMD), false)
	f.Add([]byte(pipe("off")), []byte(strings.Replace(ticketMD, "priority: 1\n", "priority: 1\ndemo: true\n", 1)), []byte(""), true)
	f.Add([]byte("\x00\t\t\n\r\n"), []byte("---\n---\n"), []byte("## Verdict\n| x\n"), true)
	f.Fuzz(func(t *testing.T, stdin, tk, spec []byte, at bool) {
		dir := filepath.Join(t.TempDir(), "t-abcd")
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(dir, "ticket.md"), tk, 0o644)
		os.WriteFile(filepath.Join(dir, "spec-review.md"), spec, 0o644)
		args := []string{dir}
		if at {
			args = append(args, "--at", "approve-plan")
		}
		var out, errb bytes.Buffer
		code := Run(args, bytes.NewReader(stdin), &out, &errb)
		if code < 0 || code > 2 || (code == 2 && out.Len() != 0) || (code != 2 && errb.Len() != 0) {
			t.Fatalf("exit %d out %q err %q", code, out.String(), errb.String())
		}
	})
}
