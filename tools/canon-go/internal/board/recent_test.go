package board

import (
	"bytes"
	"compress/gzip"
	"os"
	"os/exec"
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

// t-2db7 (sweep): every stage kind's words, a ticket-less event, a day with a .gz twin read once, and a live worktree outside
// <root>-worktrees/ counted through git's own list.
func TestRecentKindsTwinsAndLiveWorktree(t *testing.T) {
	root := resolvedOrAbs(t.TempDir())
	for _, c := range [][]string{{"init", "-q", "-b", "main"}, {"-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"}} {
		if out, err := exec.Command("git", append([]string{"-C", root}, c...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", c, err, out)
		}
	}
	far := filepath.Join(t.TempDir(), "elsewhere")
	if out, err := exec.Command("git", "-C", root, "worktree", "add", "-q", far, "-b", "far").CombinedOutput(); err != nil {
		t.Fatalf("worktree add: %v %s", err, out)
	}
	far = resolvedOrAbs(far)
	home := t.TempDir()
	emit := func(kind, project string, d map[string]string) {
		if err := events.Emit(home, kind, "tkt", project, d); err != nil {
			t.Fatal(err)
		}
	}
	emit("github.sent", root, map[string]string{"ticket": "t-aaaa", "issue": "3"})
	emit("github.results_imported", far, map[string]string{"ticket": "t-aaaa", "pr": "4"})
	emit("sprint.completed", root, map[string]string{"ticket": "t-aaaa"})
	emit("github.merged", root, map[string]string{"pr": "5"})
	got := recentLines(home, root, 10)
	want := []string{"· - · merged (PR #5)", "· t-aaaa · sprint completed", "· t-aaaa · cloud results imported (PR #4)", "· t-aaaa · sent to GitHub (issue #3)"}
	if len(got) != len(want) {
		t.Fatalf("recentLines = %q, want %d lines (the far worktree's event included)", got, len(want))
	}
	for i := range want {
		if !strings.HasSuffix(got[i], want[i]) {
			t.Fatalf("line %d = %q, want suffix %q", i, got[i], want[i])
		}
	}
	day := events.DayFiles(home)[0]
	b, _ := os.ReadFile(day)
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write(b)
	zw.Close()
	os.WriteFile(day+".gz", gz.Bytes(), 0o600)
	if again := recentLines(home, root, 10); len(again) != len(want) {
		t.Fatalf("a day with a .gz twin was read twice: %q", again)
	}
}

// t-2db7 (sweep): the block's exact text, CRLF on every line, a file that starts with the block, a BEGIN with no END left alone.
func TestRecentBlockExact(t *testing.T) {
	want := recentBegin + "\n## Recent activity\n\n_Written by canon from the activity log at plan approval, sprint close and merge; edits here are replaced._\n\n- one\n" + recentEnd + "\n"
	if got := recentBlock([]string{"one"}, "\n"); got != want {
		t.Fatalf("block =\n%q\nwant\n%q", got, want)
	}
	c := setRecent("# H\r\nx\r\n", []string{"one"})
	if strings.Count(c, "\n") != strings.Count(c, "\r\n") {
		t.Fatalf("a CRLF file got a bare LF: %q", c)
	}
	start := setRecent("", []string{"one"})
	if again := setRecent(start, []string{"two"}); strings.Count(again, recentBegin) != 1 || !strings.Contains(again, "- two") {
		t.Fatalf("a file that starts with the block got a second one: %q", again)
	}
	open := "# H\n" + recentBegin + "\nno end\n"
	if stripRecent(open) != open {
		t.Fatal("a BEGIN with no END must be left alone by strip")
	}
}
