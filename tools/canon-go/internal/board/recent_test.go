package board

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"canon/internal/events"
)

// t-2db7: `canon-go recent` is what sprint approve/complete and tkt merge-pr write into the main checkout's HANDOFF.md, and what
// `sprint recent` prints. Prod path: those commands (through tools/platform-lib.sh handoff_recent) and merge-pr's --strip check.
func TestRecentLines(t *testing.T) {
	root := resolvedOrAbs(t.TempDir())
	home := t.TempDir()
	wt := filepath.Join(filepath.Dir(root), filepath.Base(root)+"-worktrees", "feat-x")
	emit := func(kind, project string, d map[string]string) {
		if err := events.Emit(home, kind, "sprint", project, d); err != nil {
			t.Fatal(err)
		}
	}
	emit("plan.approved", root, map[string]string{"ticket": "t-aaaa", "tier": "normal"})
	emit("gate.finished", wt, map[string]string{"ticket": "t-aaaa", "role": "evaluator", "verdict": "pass", "model": "claude-sonnet-5-5"})
	emit("ticket.status_changed", root, map[string]string{"ticket": "t-aaaa", "from": "open", "to": "in_progress"}) // not a stage
	emit("sprint.completed", "/elsewhere", map[string]string{"ticket": "t-bbbb"})                                   // another project
	emit("github.merged", root, map[string]string{"ticket": "t-aaaa", "pr": "12"})
	got := recentLines(home, root, 10)
	if len(got) != 3 {
		t.Fatalf("recentLines = %q, want 3 stage lines of this project, newest first", got)
	}
	for i, want := range []string{"· t-aaaa · merged (PR #12)", "· t-aaaa · evaluator pass (claude-sonnet-5-5)", "· t-aaaa · plan approved (normal)"} {
		if !strings.HasSuffix(got[i], want) {
			t.Fatalf("line %d = %q, want it to end %q (newest first)", i, got[i], want)
		}
	}
	if two := recentLines(home, root, 2); len(two) != 2 || two[0] != got[0] {
		t.Fatalf("--n 2 = %q", two)
	}
}

func TestRecentHandoffBlock(t *testing.T) {
	lines := []string{"11-02 16:17 · t-aaaa · plan approved (normal)"}
	tmpl := "# Handoff\n\nintro\n\n<!-- canon:handoff:BEGIN -->\n## Current Focus\nmine\n<!-- canon:handoff:END -->\n"
	once := setRecent(tmpl, lines)
	if !strings.Contains(once, recentBegin+"\n## Recent activity\n") || strings.Index(once, recentBegin) > strings.Index(once, "<!-- canon:handoff:BEGIN -->") {
		t.Fatalf("the block goes above the narrative's markers:\n%s", once)
	}
	if stripRecent(once) != tmpl {
		t.Fatalf("strip(set(x)) != x:\n%q", stripRecent(once))
	}
	twice := setRecent(once, []string{"11-02 17:00 · t-aaaa · sprint completed"})
	if strings.Count(twice, recentBegin) != 1 || !strings.Contains(twice, "sprint completed") || strings.Contains(twice, "plan approved") {
		t.Fatalf("a second write replaces the block, never adds one:\n%s", twice)
	}
	if stripRecent(twice) != tmpl {
		t.Fatal("the narrative changed across two writes")
	}
	crlf := strings.ReplaceAll(tmpl, "\n", "\r\n")
	c := setRecent(crlf, lines)
	if strings.Contains(strings.ReplaceAll(c, "\r\n", ""), "\n") || stripRecent(c) != crlf {
		t.Fatalf("a CRLF file gets CRLF lines and strips back:\n%q", c)
	}
	plain := "# Notes\nno markers"
	p := setRecent(plain, lines)
	if !strings.HasPrefix(p, plain+"\n"+recentBegin) || stripRecent(p) != plain+"\n" {
		t.Fatalf("no narrative markers: appended at the end:\n%q", p)
	}
	if empty := recentBlock(nil, "\n"); !strings.Contains(empty, "- No stage recorded yet.") {
		t.Fatalf("an empty log says so: %q", empty)
	}
}

func TestRecentCLI(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "HANDOFF.md")
	var out, errb bytes.Buffer
	if code := recentCLI([]string{"--project", dir, "--handoff", f}, nil, &out, &errb); code != 0 {
		t.Fatalf("missing file = %d %s", code, errb.String())
	}
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Fatal("a missing HANDOFF.md was created")
	}
	os.WriteFile(f, []byte("# Handoff\n<!-- canon:handoff:BEGIN -->\nx\n<!-- canon:handoff:END -->\n"), 0o640)
	if code := recentCLI([]string{"--project", dir, "--handoff", f}, nil, &out, &errb); code != 0 {
		t.Fatalf("--handoff = %d %s", code, errb.String())
	}
	b, _ := os.ReadFile(f)
	fi, _ := os.Stat(f)
	if !strings.Contains(string(b), recentBegin) || fi.Mode().Perm() != 0o640 {
		t.Fatalf("written %q mode %v", b, fi.Mode())
	}
	out.Reset()
	if code := recentCLI([]string{"--strip"}, bytes.NewReader(b), &out, &errb); code != 0 || strings.Contains(out.String(), recentBegin) {
		t.Fatalf("--strip = %d %q", code, out.String())
	}
	os.Remove(f)
	os.Symlink(filepath.Join(dir, "elsewhere.md"), f)
	os.WriteFile(filepath.Join(dir, "elsewhere.md"), []byte("x"), 0o644)
	if code := recentCLI([]string{"--project", dir, "--handoff", f}, nil, &out, &errb); code != 1 {
		t.Fatalf("a symlinked HANDOFF.md = %d, want refused (1)", code)
	}
	for _, bad := range [][]string{{}, {"--project", dir, "--n", "0"}, {"--project", dir, "--n", "x"}, {"extra"}} {
		if code := recentCLI(bad, nil, &out, &errb); code != 2 {
			t.Fatalf("%q = %d, want 2", bad, code)
		}
	}
}
