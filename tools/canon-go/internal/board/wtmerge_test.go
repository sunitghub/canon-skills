package board

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// t-2906: protects the card's Check & merge button for a worktree ticket (GET /api/tickets' wt_merge): shown for a closed ticket
// bound to a live linked worktree whose branch is not in main; never once merged, sent to GitHub, unbound or still open.
func TestAnnotateWorktreeMerge(t *testing.T) {
	root := resolvedOrAbs(t.TempDir())
	git := func(dir string, args ...string) {
		t.Helper()
		if out, err := exec.Command("git", append([]string{"-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	git(root, "init", "-q", "-b", "main")
	git(root, "commit", "-q", "--allow-empty", "-m", "base")
	wt := filepath.Join(resolvedOrAbs(t.TempDir()), "wt")
	git(root, "worktree", "add", "-q", wt, "-b", "feat/x")
	git(wt, "commit", "-q", "--allow-empty", "-m", "work")
	td := filepath.Join(root, ".tickets", "t-aaaa")
	os.MkdirAll(td, 0o755)
	os.WriteFile(filepath.Join(td, ".cockpit-cwd"), []byte(wt+"\n"), 0o644)

	mark := func(fields ticket) map[string]any {
		t.Helper()
		tk := ticket{"id": "t-aaaa", "status": "closed"}
		for k, v := range fields {
			tk[k] = v
		}
		annotateWorktreeMerge([]ticket{tk}, root)
		m, _ := tk["wt_merge"].(map[string]any)
		return m
	}
	if m := mark(nil); m == nil || m["branch"] != "feat/x" || m["path"] != wt {
		t.Fatalf("a closed ticket with an unmerged worktree branch: wt_merge = %v, want feat/x at %s", m, wt)
	}
	for name, f := range map[string]ticket{
		"open":           {"status": "in_progress"},
		"merged":         {"merged": "abc1234"},
		"sent to GitHub": {"runs": "github"},
	} {
		if m := mark(f); m != nil {
			t.Fatalf("%s ticket got wt_merge %v", name, m)
		}
	}
	git(root, "merge", "-q", "--no-ff", "-m", "m", "feat/x")
	if m := mark(nil); m != nil {
		t.Fatalf("a branch already in main got wt_merge %v", m)
	}
	// Review of t-2906: the long-lived worktree branch moves on with the next ticket's commit; this ticket's graded work is in
	// main, so it is done and gets no button, although the branch head is not in main.
	out, _ := exec.Command("git", "-C", wt, "rev-parse", "HEAD").Output()
	os.WriteFile(filepath.Join(td, "eval-report.md"), []byte("graded-head: "+string(out)), 0o644)
	git(wt, "commit", "-q", "--allow-empty", "-m", "the next ticket")
	if m := mark(nil); m != nil {
		t.Fatalf("a ticket whose graded head is in main got wt_merge %v once the branch moved on", m)
	}
	os.Remove(filepath.Join(td, "eval-report.md"))
	if m := mark(nil); m == nil {
		t.Fatal("with no eval-report to read, a branch head outside main still shows the button (tkt merge then says why)")
	}
	os.Remove(filepath.Join(td, ".cockpit-cwd"))
	if m := mark(nil); m != nil {
		t.Fatalf("an unbound ticket got wt_merge %v", m)
	}
}
