package common

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// t-74d8, prod path: the board's worktree route (POST /api/worktrees) and the daemon's session start both link a worktree
// with LinkWorktree. One case per rule of skills.sh's link_worktree / upsert_gate_agents / _ensure_mirror_gitignored.
func fakeCanon(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "skills", "sprint"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "skills", "sprint", "SKILL.md"), []byte("CURRENT"), 0o644))
	must(t, os.MkdirAll(filepath.Join(root, "agents"), 0o755))
	for _, n := range []string{"canon-reviewer.md", "canon-evaluator.md"} {
		must(t, os.WriteFile(filepath.Join(root, "agents", n), []byte("<!-- canon:agent -->\n"+n+"\n"), 0o644))
	}
	return root
}

func gitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, a := range [][]string{{"init", "-q"}, {"config", "user.email", "t@t"}, {"config", "user.name", "t"}} {
		if err := exec.Command("git", append([]string{"-C", dir}, a...)...).Run(); err != nil {
			t.Skipf("git unavailable: %v", err)
		}
	}
	return dir
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func linkTarget(t *testing.T, p string) string {
	t.Helper()
	if !isDirLink(p) {
		t.Fatalf("%s is not a link", p)
	}
	r, _ := filepath.EvalSymlinks(p)
	return r
}

func real(p string) string { r, _ := filepath.EvalSymlinks(p); return r }

func TestLinkWorktreeFresh(t *testing.T) {
	canon, wt := fakeCanon(t), gitRepo(t)
	did := LinkWorktree(canon, wt)
	for rel, want := range map[string]string{".claude/skills": "skills", ".agents/skills": "skills", ".claude/agents": "agents"} {
		if got := linkTarget(t, filepath.Join(wt, rel)); got != real(filepath.Join(canon, want)) {
			t.Errorf("%s -> %s, want canon's %s", rel, got, want)
		}
	}
	gi, _ := os.ReadFile(filepath.Join(wt, ".gitignore"))
	want := "/.claude/agents\n/.claude/skills\n/.agents/skills\n/.claude/subagent-runs.jsonl\n/.tickets/*/gate-snapshot.txt*\n"
	if string(gi) != want {
		t.Errorf(".gitignore = %q, want %q (skills.sh's order)", gi, want)
	}
	if len(did) == 0 {
		t.Error("a fresh worktree must report what was linked")
	}
	if again := LinkWorktree(canon, wt); len(again) != 0 {
		t.Errorf("a second run must change nothing, did %v", again)
	}
	gi2, _ := os.ReadFile(filepath.Join(wt, ".gitignore"))
	if string(gi2) != want {
		t.Errorf("a second run changed .gitignore: %q", gi2)
	}
}

func TestLinkWorktreeAgentsRules(t *testing.T) {
	canon := fakeCanon(t)
	// a link to a folder that is gone, or to another canon's agents: re-pointed
	for name, prep := range map[string]func(link string){
		"dangling": func(link string) { must(t, os.Symlink(filepath.Join(t.TempDir(), "gone"), link)) },
		"old canon": func(link string) {
			old := filepath.Join(t.TempDir(), "agents")
			must(t, os.MkdirAll(old, 0o755))
			must(t, os.WriteFile(filepath.Join(old, "canon-reviewer.md"), []byte("<!-- canon:agent -->"), 0o644))
			must(t, os.Symlink(old, link))
		},
	} {
		wt := gitRepo(t)
		must(t, os.MkdirAll(filepath.Join(wt, ".claude"), 0o755))
		link := filepath.Join(wt, ".claude", "agents")
		prep(link)
		LinkWorktree(canon, wt)
		if got := linkTarget(t, link); got != real(filepath.Join(canon, "agents")) {
			t.Errorf("%s: agents -> %s, want re-pointed to canon's", name, got)
		}
	}
	// a link to the user's own (non-canon) agents folder: left as is
	wt := gitRepo(t)
	mine := filepath.Join(t.TempDir(), "my-agents")
	must(t, os.MkdirAll(mine, 0o755))
	must(t, os.WriteFile(filepath.Join(mine, "helper.md"), []byte("mine"), 0o644))
	must(t, os.MkdirAll(filepath.Join(wt, ".claude"), 0o755))
	must(t, os.Symlink(mine, filepath.Join(wt, ".claude", "agents")))
	LinkWorktree(canon, wt)
	if got := linkTarget(t, filepath.Join(wt, ".claude", "agents")); got != real(mine) {
		t.Errorf("a link to the user's own agents folder must stay, got %s", got)
	}
	// a real folder the project owns: canon's files copied in only where absent or canon-managed; the user's own kept
	wt = gitRepo(t)
	dir := filepath.Join(wt, ".claude", "agents")
	must(t, os.MkdirAll(dir, 0o755))
	must(t, os.WriteFile(filepath.Join(dir, "canon-reviewer.md"), []byte("my own reviewer"), 0o644))
	must(t, os.WriteFile(filepath.Join(dir, "canon-evaluator.md"), []byte("<!-- canon:agent -->\nold"), 0o644))
	LinkWorktree(canon, wt)
	if b, _ := os.ReadFile(filepath.Join(dir, "canon-reviewer.md")); string(b) != "my own reviewer" {
		t.Errorf("a canon-named file the user wrote must be kept, got %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "canon-evaluator.md")); !strings.Contains(string(b), "canon-evaluator.md") {
		t.Errorf("a canon-managed file must be refreshed from canon, got %q", b)
	}
	if isDirLink(dir) {
		t.Error("a folder the project owns must not be replaced by a link")
	}
	// a file where the folder would be: left as is
	wt = gitRepo(t)
	must(t, os.MkdirAll(filepath.Join(wt, ".claude"), 0o755))
	must(t, os.WriteFile(filepath.Join(wt, ".claude", "agents"), []byte("x"), 0o644))
	LinkWorktree(canon, wt)
	if b, _ := os.ReadFile(filepath.Join(wt, ".claude", "agents")); string(b) != "x" {
		t.Error("a file named .claude/agents must be left as is")
	}
}

func TestLinkWorktreeSkillsAndGitignore(t *testing.T) {
	canon := fakeCanon(t)
	// t-9e55: a committed canon mirror is replaced and untracked; a project-local skills folder is kept
	wt := gitRepo(t)
	must(t, os.MkdirAll(filepath.Join(wt, ".agents", "skills", "sprint"), 0o755))
	must(t, os.WriteFile(filepath.Join(wt, ".agents", "skills", "sprint", "SKILL.md"), []byte("STALE"), 0o644))
	must(t, os.MkdirAll(filepath.Join(wt, ".claude", "skills", "mine"), 0o755))
	must(t, os.WriteFile(filepath.Join(wt, ".claude", "skills", "mine", "x.md"), []byte("LOCAL"), 0o644))
	must(t, os.WriteFile(filepath.Join(wt, ".gitignore"), []byte("node_modules\n/.claude/skills/"), 0o644))
	must(t, exec.Command("git", "-C", wt, "add", "-A").Run())
	must(t, exec.Command("git", "-C", wt, "commit", "-qm", "c").Run())
	LinkWorktree(canon, wt)
	if b, _ := os.ReadFile(filepath.Join(wt, ".agents", "skills", "sprint", "SKILL.md")); string(b) != "CURRENT" {
		t.Errorf("the committed mirror must now resolve to current canon, got %q", b)
	}
	if out, _ := exec.Command("git", "-C", wt, "ls-files", "--", ".agents/skills").Output(); strings.TrimSpace(string(out)) != "" {
		t.Errorf("the replaced mirror must be untracked: %q", out)
	}
	if isDirLink(filepath.Join(wt, ".claude", "skills")) {
		t.Error("a project-local .claude/skills (no canon marker) must be kept")
	}
	gi, _ := os.ReadFile(filepath.Join(wt, ".gitignore"))
	if strings.Contains(string(gi), "/.claude/skills/\n") || strings.Count(string(gi), "/.claude/skills\n") != 1 || !strings.HasPrefix(string(gi), "node_modules\n") {
		t.Errorf("the directory-only line must become the bare one, once, keeping the rest: %q", gi)
	}
	// a stale skills link is re-pointed
	wt = gitRepo(t)
	must(t, os.MkdirAll(filepath.Join(wt, ".claude"), 0o755))
	must(t, os.Symlink(t.TempDir(), filepath.Join(wt, ".claude", "skills")))
	LinkWorktree(canon, wt)
	if got := linkTarget(t, filepath.Join(wt, ".claude", "skills")); got != real(filepath.Join(canon, "skills")) {
		t.Errorf("a stale skills link must be re-pointed, got %s", got)
	}
	// outside git: links, no .gitignore
	plain := t.TempDir()
	LinkWorktree(canon, plain)
	if !isDirLink(filepath.Join(plain, ".claude", "agents")) || exists(filepath.Join(plain, ".gitignore")) {
		t.Error("a folder without git gets the links and no .gitignore")
	}
}

// t-74d8 (user's choice): in a linked worktree the ignore lines go to git's untracked info/exclude, so linking leaves no
// .gitignore change on the sprint's branch (one blocked `tkt land --finish`); git still ignores the links.
func TestLinkWorktreeLinkedWorktreeUsesExclude(t *testing.T) {
	canon, main := fakeCanon(t), gitRepo(t)
	must(t, os.WriteFile(filepath.Join(main, ".gitignore"), []byte("node_modules\n"), 0o644))
	must(t, exec.Command("git", "-C", main, "add", "-A").Run())
	must(t, exec.Command("git", "-C", main, "commit", "-qm", "c").Run())
	wt := filepath.Join(t.TempDir(), "wt")
	if out, err := exec.Command("git", "-C", main, "worktree", "add", "-q", "-b", "w", wt).CombinedOutput(); err != nil {
		t.Fatalf("worktree add: %v %s", err, out)
	}
	LinkWorktree(canon, wt)
	if gi, _ := os.ReadFile(filepath.Join(wt, ".gitignore")); string(gi) != "node_modules\n" {
		t.Errorf("a linked worktree's tracked .gitignore must stay as committed, got %q", gi)
	}
	if st, _ := exec.Command("git", "-C", wt, "status", "--porcelain").Output(); strings.TrimSpace(string(st)) != "" {
		t.Errorf("linking must leave the worktree clean (links ignored, no tracked change), status: %q", st)
	}
	ex, _ := exec.Command("git", "-C", wt, "rev-parse", "--git-path", "info/exclude").Output()
	p := strings.TrimSpace(string(ex))
	if !filepath.IsAbs(p) {
		p = filepath.Join(wt, p)
	}
	if b, _ := os.ReadFile(p); !strings.Contains(string(b), "/.claude/agents\n") || !strings.Contains(string(b), "/.claude/skills\n") {
		t.Errorf("info/exclude must carry the link lines, got %q", b)
	}
}
