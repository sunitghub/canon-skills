package board

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// t-6541: the Projects card's skill problems come from skills.sh's own check (status --json), cached until AGENTS.md or a skills
// folder changes; a failed check is an error, never "healthy"; Refresh runs `skills.sh refresh <root>` with fixed arguments.
// Prod path: GET /api/skills-health and POST /api/skills-refresh (the card's Skills row and its Refresh button).
func TestSkillsHealthAndRefresh(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the stub is a bash script")
	}
	dir := t.TempDir()
	root := filepath.Join(dir, "proj")
	os.MkdirAll(root, 0o755)
	os.WriteFile(filepath.Join(root, "AGENTS.md"), []byte("x"), 0o644)
	log := filepath.Join(dir, "calls")
	stub := filepath.Join(dir, "skills.sh")
	os.WriteFile(stub, []byte(`#!/usr/bin/env bash
printf '%s|%s\n' "$*" "${SKILLS_SH_ASSUME_YES:-}" >> "`+log+`"
case "$1" in
  status) [ -n "${STUB_FAIL:-}" ] && { echo boom >&2; exit 3; }
          echo '{"skills":[{"name":"sprint","problems":["missing link .claude/skills"]}],"issues":1}' ;;
  refresh) echo "  [skill-dir]  created: x"; echo Done. ;;
esac
`), 0o755)
	t.Setenv("SKILLS_SH_BIN", stub)
	calls := func() int { b, _ := os.ReadFile(log); return strings.Count(string(b), "\n") }

	res := skillsHealth(root)
	if res["ok"] != true || res["issues"] != 1 {
		t.Fatalf("health = %v", res)
	}
	if skillsHealth(root); calls() != 1 {
		t.Fatalf("an unchanged project ran the check again (%d calls): the answer is cached", calls())
	}
	later := time.Now().Add(2 * time.Second)
	os.Chtimes(filepath.Join(root, "AGENTS.md"), later, later)
	if skillsHealth(root); calls() != 2 {
		t.Fatalf("a changed AGENTS.md did not re-run the check (%d calls)", calls())
	}
	os.MkdirAll(filepath.Join(root, ".claude", "skills"), 0o755)
	if skillsHealth(root); calls() != 3 {
		t.Fatalf("a new .claude/skills did not re-run the check (%d calls)", calls())
	}

	t.Setenv("STUB_FAIL", "1")
	os.Chtimes(filepath.Join(root, "AGENTS.md"), later.Add(time.Second), later.Add(time.Second))
	if r := skillsHealth(root); r["ok"] != false || !strings.Contains(r["error"].(string), "could not check") {
		t.Fatalf("a failed check = %v, want an error", r)
	}
	t.Setenv("STUB_FAIL", "")

	r := skillsRefresh(root)
	if r["ok"] != true || !strings.Contains(r["output"].(string), "Done.") {
		t.Fatalf("refresh = %v", r)
	}
	b, _ := os.ReadFile(log)
	last := strings.Split(strings.TrimSpace(string(b)), "\n")
	if got := last[len(last)-1]; got != "refresh "+root+"|1" {
		t.Fatalf("refresh ran %q, want the fixed `refresh <root>` with SKILLS_SH_ASSUME_YES=1", got)
	}
	n := calls()
	if skillsHealth(root); calls() != n+1 {
		t.Fatal("a refresh did not drop the cached answer")
	}

	t.Setenv("SKILLS_SH_BIN", filepath.Join(dir, "missing.sh"))
	if r := skillsRefresh(root); r["ok"] != false || r["unsupported"] != true {
		t.Fatalf("no skills.sh = %v, want unsupported", r)
	}
}
