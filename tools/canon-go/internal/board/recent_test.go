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
	for _, id := range []string{"t-aaaa", "t-cccc"} { // t-154b: a line needs its ticket folder in this project (t-bbbb is another project's)
		os.MkdirAll(filepath.Join(root, ".tickets", id), 0o755)
	}
	emit("plan.approved", root, map[string]string{"ticket": "t-aaaa", "tier": "normal"})
	emit("gate.finished", wt, map[string]string{"ticket": "t-aaaa", "role": "evaluator", "verdict": "pass", "model": "claude-sonnet-5-5"})
	emit("ticket.status_changed", root, map[string]string{"ticket": "t-aaaa", "from": "open", "to": "in_progress"}) // not a stage
	emit("sprint.completed", "/elsewhere", map[string]string{"ticket": "t-bbbb"})                                   // another project
	emit("github.merged", root, map[string]string{"ticket": "t-aaaa", "pr": "12"})
	emit("branch.merged", root, map[string]string{"ticket": "t-cccc", "branch": "feat/t-cccc"}) // t-2906: tkt merge of a worktree branch
	got := recentLines(home, root, 10)
	if len(got) != 4 {
		t.Fatalf("recentLines = %q, want 4 stage lines of this project, newest first", got)
	}
	for i, want := range []string{"· t-cccc · merged here (feat/t-cccc)", "· t-aaaa · merged (PR #12)", "· t-aaaa · evaluator pass (claude-sonnet-5-5)", "· t-aaaa · plan approved (normal)"} {
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
	os.MkdirAll(filepath.Join(root, ".tickets", "t-aaaa"), 0o755)
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

// t-2db7 review: main's HANDOFF.md with only canon's block changed (CRLF on disk or not) is not "uncommitted work" for the board's
// worktree picker; a narrative edit still is. Prod path: worktreeDirty (the picker's carry-over warning).
func TestWorktreeDirtyIgnoresTheBlock(t *testing.T) {
	dir := t.TempDir()
	git := func(args ...string) {
		if out, err := exec.Command("git", append([]string{"-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	git("init", "-q")
	narrative := "# Handoff\n\n<!-- canon:handoff:BEGIN -->\n## Current Focus\nx\n<!-- canon:handoff:END -->\n"
	os.WriteFile(filepath.Join(dir, "HANDOFF.md"), []byte(narrative), 0o644)
	git("add", "HANDOFF.md")
	git("commit", "-qm", "base")
	os.WriteFile(filepath.Join(dir, "HANDOFF.md"), []byte(setRecent(narrative, []string{"a"})), 0o644)
	if worktreeDirty(dir) {
		t.Fatal("a block-only HANDOFF.md counted as uncommitted work")
	}
	crlf := strings.ReplaceAll(narrative, "\n", "\r\n")
	os.WriteFile(filepath.Join(dir, "HANDOFF.md"), []byte(setRecent(crlf, []string{"a"})), 0o644)
	if worktreeDirty(dir) {
		t.Fatal("a CRLF block-only HANDOFF.md counted as uncommitted work")
	}
	os.WriteFile(filepath.Join(dir, "HANDOFF.md"), []byte(setRecent(strings.Replace(narrative, "x\n", "mine\n", 1), []string{"a"})), 0o644)
	if !worktreeDirty(dir) {
		t.Fatal("a narrative edit must still count")
	}
}

// t-154b: the activity log is keyed by project path, so a folder recreated at the same path inherits the old project's events (the user's
// ToDo-Demo showed t-4zbo, t-aep3 and t-rjsx next to its own t-32ah). A line needs its ticket's folder in this project's .tickets/. Prod path:
// `sprint recent` and the HANDOFF.md block written at plan approval, close and merge.
func TestRecentLinesNeedTheirTicketHere(t *testing.T) {
	root := resolvedOrAbs(t.TempDir())
	home := t.TempDir()
	wt := filepath.Join(filepath.Dir(root), filepath.Base(root)+"-worktrees", "feat-x")
	emit := func(kind, project string, d map[string]string) {
		if err := events.Emit(home, kind, "sprint", project, d); err != nil {
			t.Fatal(err)
		}
	}
	os.MkdirAll(filepath.Join(root, ".tickets", "t-here"), 0o755)
	os.MkdirAll(filepath.Join(root, ".tickets", "t-closed"), 0o755) // closed, archived and compacted tickets keep their folder
	other := t.TempDir()
	os.MkdirAll(filepath.Join(other, "elsewhere"), 0o755)
	os.Symlink(filepath.Join(other, "elsewhere"), filepath.Join(root, ".tickets", "t-link")) // a link is not a ticket folder
	os.WriteFile(filepath.Join(root, ".tickets", "t-file"), []byte("x"), 0o644)              // nor is a file
	os.MkdirAll(filepath.Join(root, "outside"), 0o755)                                       // "../outside" would resolve to a real folder if the id reached the filesystem unchecked
	os.MkdirAll(filepath.Join(root, ".tickets", "a", "b"), 0o755)
	emit("plan.approved", root, map[string]string{"ticket": "t-gone", "tier": "normal"}) // the old incarnation's ticket
	emit("sprint.completed", root, map[string]string{"ticket": "t-gone"})
	emit("plan.approved", root, map[string]string{"ticket": "t-here", "tier": "normal"})
	emit("sprint.completed", wt, map[string]string{"ticket": "t-here"}) // a worktree sprint: checked against the MAIN checkout's .tickets/
	emit("sprint.completed", root, map[string]string{"ticket": "t-closed"})
	emit("sprint.completed", root, map[string]string{"ticket": "t-link"})
	emit("sprint.completed", root, map[string]string{"ticket": "t-file"})
	emit("sprint.completed", root, map[string]string{"ticket": "../outside"})
	emit("sprint.completed", root, map[string]string{"ticket": "a/b"})
	emit("github.merged", root, map[string]string{"pr": "5"}) // a PR merged outside canon names no ticket: shown as before
	// a project that tracks .tickets/ in git: a ticket created in a worktree has its folder THERE until the branch merges; another ticket is in neither
	os.MkdirAll(filepath.Join(wt, ".tickets", "t-inwt"), 0o755)
	emit("plan.approved", wt, map[string]string{"ticket": "t-inwt", "tier": "normal"})
	emit("plan.approved", wt, map[string]string{"ticket": "t-nowhere", "tier": "normal"})
	got := recentLines(home, root, 20)
	joined := strings.Join(got, "\n")
	for _, bad := range []string{"t-gone", "t-link", "t-file", "outside", "a/b"} {
		if strings.Contains(joined, bad) {
			t.Fatalf("a line for %q was shown: %q", bad, got)
		}
	}
	if strings.Contains(joined, "t-nowhere") || !strings.Contains(joined, "t-inwt · plan approved") {
		t.Fatalf("a worktree's own ticket folder: %q", got)
	}
	if len(got) != 5 || !strings.Contains(joined, "t-here · sprint completed") || !strings.Contains(joined, "t-here · plan approved") ||
		!strings.Contains(joined, "t-closed · sprint completed") || !strings.Contains(joined, "· - · merged (PR #5)") {
		t.Fatalf("recentLines = %q, want the existing tickets' lines and the ticketless merge", got)
	}
	// the HANDOFF block holds the same lines
	hf := filepath.Join(t.TempDir(), "HANDOFF.md")
	os.WriteFile(hf, []byte("# Handoff\n\n"+recentBegin+"\n"+recentEnd+"\n"), 0o644)
	t.Setenv("CANON_HOME", home) // recentCLI reads the machine's log
	var out, errb bytes.Buffer
	if code := recentCLI([]string{"--project", root, "--handoff", hf}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("recent --handoff = %d %s", code, errb.String())
	}
	if b, _ := os.ReadFile(hf); strings.Contains(string(b), "t-gone") || !strings.Contains(string(b), "t-here") {
		t.Fatalf("the HANDOFF block = %q", b)
	}
	// a project recreated at a path with old events and no tickets yet: nothing but a ticketless line
	fresh := resolvedOrAbs(t.TempDir())
	emit("plan.approved", fresh, map[string]string{"ticket": "t-old1", "tier": "normal"})
	if l := recentLines(home, fresh, 10); len(l) != 0 {
		t.Fatalf("a recreated project shows the old history: %q", l)
	}
}

// An unreadable .tickets/ must not hide the user's history: the answer on an error other than "does not exist" is yes.
func TestRecentLinesFailOpenOnAnUnreadableTicketsFolder(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads a folder with no permissions")
	}
	root := resolvedOrAbs(t.TempDir())
	home := t.TempDir()
	os.MkdirAll(filepath.Join(root, ".tickets", "t-here"), 0o755)
	if err := events.Emit(home, "sprint.completed", "sprint", root, map[string]string{"ticket": "t-here"}); err != nil {
		t.Fatal(err)
	}
	os.Chmod(filepath.Join(root, ".tickets"), 0)
	t.Cleanup(func() { os.Chmod(filepath.Join(root, ".tickets"), 0o755) })
	if l := recentLines(home, root, 10); len(l) != 1 {
		t.Fatalf("an unreadable .tickets/ hid the line: %q", l)
	}
}
