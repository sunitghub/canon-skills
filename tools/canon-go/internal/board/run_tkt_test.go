package board

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRunTktMax protects runTkt's one output contract: a log keeps its last tktTail bytes, a document someone parses
// (GitHub Sync's intake) is returned whole or refused as too large, and a failing run still shows only its tail.
func TestRunTktMax(t *testing.T) {
	dir := t.TempDir()
	stub := filepath.Join(dir, "tkt")
	script := "#!/bin/sh\nhead -c \"$SIZE\" /dev/zero | tr '\\0' x\n[ -n \"$FAIL\" ] && exit 3\nexit 0\n"
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TKT_BIN", stub)
	run := func(size string, fail bool, max int) map[string]any {
		t.Setenv("SIZE", size)
		if fail {
			t.Setenv("FAIL", "1")
		} else {
			t.Setenv("FAIL", "")
		}
		return runTktMax(dir, []string{"x"}, max)
	}
	out := func(r map[string]any) string { return r["output"].(string) }

	if r := run("50000", false, 0); r["ok"] != true || len(out(r)) != tktTail {
		t.Errorf("max 0 must keep the last %d bytes, got ok=%v len=%d", tktTail, r["ok"], len(out(r)))
	}
	if r := run("50000", false, 100000); r["ok"] != true || len(out(r)) != 50000 {
		t.Errorf("under the cap must return the whole output, got ok=%v len=%d", r["ok"], len(out(r)))
	}
	r := run("50000", false, 40000)
	if r["ok"] != false || !strings.Contains(out(r), "too large to show (50000 bytes; the limit is 40000)") {
		t.Errorf("over the cap must refuse with the size, got %v %q", r["ok"], out(r))
	}
	if r := run("50000", true, 100000); r["ok"] != false || r["exit_code"] != 3 || len(out(r)) != tktTail {
		t.Errorf("a failing run keeps its tail, got ok=%v code=%v len=%d", r["ok"], r["exit_code"], len(out(r)))
	}
}
