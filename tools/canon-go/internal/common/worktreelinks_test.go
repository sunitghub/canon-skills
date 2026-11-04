package common

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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

// t-74d8 (mutation sweep): the edges the first tests left open.
func TestLinkWorktreeEdges(t *testing.T) {
	canon := fakeCanon(t)
	// a TRACKED project skills folder with no canon marker is the project's: kept (only a tracked canon mirror is replaced)
	wt := gitRepo(t)
	must(t, os.MkdirAll(filepath.Join(wt, ".claude", "skills", "mine"), 0o755))
	must(t, os.WriteFile(filepath.Join(wt, ".claude", "skills", "mine", "x.md"), []byte("LOCAL"), 0o644))
	must(t, exec.Command("git", "-C", wt, "add", "-A").Run())
	must(t, exec.Command("git", "-C", wt, "commit", "-qm", "c").Run())
	LinkWorktree(canon, wt)
	if isDirLink(filepath.Join(wt, ".claude", "skills")) {
		t.Error("a tracked project skills folder without canon's marker must be kept")
	}
	// a canon without agents/ links no agents
	noAgents := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(noAgents, "skills"), 0o755))
	wt = gitRepo(t)
	LinkWorktree(noAgents, wt)
	if exists(filepath.Join(wt, ".claude", "agents")) {
		t.Error("with no agents/ in canon, no .claude/agents may be made")
	}
	// a re-pointed agents link is ignored too (the line is added on that path, not only on a fresh link)
	wt = gitRepo(t)
	must(t, os.MkdirAll(filepath.Join(wt, ".claude"), 0o755))
	must(t, os.Symlink(filepath.Join(t.TempDir(), "gone"), filepath.Join(wt, ".claude", "agents")))
	LinkWorktree(canon, wt)
	if !hasLine(filepath.Join(wt, ".gitignore"), "/.claude/agents") {
		t.Error("a re-pointed .claude/agents must be ignored")
	}
	// the user's own canon-reviewer.md (no canon:agent marker) makes their linked folder theirs: not re-pointed
	wt = gitRepo(t)
	mine := filepath.Join(t.TempDir(), "my-agents")
	must(t, os.MkdirAll(mine, 0o755))
	must(t, os.WriteFile(filepath.Join(mine, "canon-reviewer.md"), []byte("my own"), 0o644))
	must(t, os.MkdirAll(filepath.Join(wt, ".claude"), 0o755))
	must(t, os.Symlink(mine, filepath.Join(wt, ".claude", "agents")))
	LinkWorktree(canon, wt)
	if got := linkTarget(t, filepath.Join(wt, ".claude", "agents")); got != real(mine) {
		t.Errorf("a folder whose canon-reviewer.md lacks the canon:agent marker is the user's: must stay, got %s", got)
	}
	// a project folder missing canon's files gets them copied in
	wt = gitRepo(t)
	must(t, os.MkdirAll(filepath.Join(wt, ".claude", "agents"), 0o755))
	LinkWorktree(canon, wt)
	if b, _ := os.ReadFile(filepath.Join(wt, ".claude", "agents", "canon-evaluator.md")); !strings.Contains(string(b), "canon:agent") {
		t.Error("an absent canon-evaluator.md must be copied into a project-owned agents folder")
	}
	// Windows line endings: lines are recognized, nothing is added twice; a last line without a newline gets one first
	wt = gitRepo(t)
	must(t, os.WriteFile(filepath.Join(wt, ".gitignore"), []byte("/.claude/agents\r\n/.claude/skills/\r\n/.claude/skills\r\nnode_modules"), 0o644))
	LinkWorktree(canon, wt)
	LinkWorktree(canon, wt)
	gi, _ := os.ReadFile(filepath.Join(wt, ".gitignore"))
	if c := strings.Count(string(gi), "/.claude/agents"); c != 1 {
		t.Errorf("a CRLF line must be recognized: /.claude/agents appears %d times in %q", c, gi)
	}
	if strings.Contains(string(gi), "/.claude/skills/") || strings.Count(string(gi), "/.claude/skills\r\n")+strings.Count(string(gi), "/.claude/skills\n") != 1 {
		t.Errorf("the directory-only line must go when the bare one exists, leaving one: %q", gi)
	}
	if !strings.Contains(string(gi), "node_modules\n/.agents/skills\n") {
		t.Errorf("a last line without a newline must get one before canon's lines: %q", gi)
	}
}

// t-74d8 (reviewer): a --separate-git-dir checkout (like a submodule) has a .git FILE but is a main checkout: its ignore
// lines go to the committed .gitignore, not git's exclude, so a teammate's clone gets them.
func TestLinkWorktreeSeparateGitDirIsMainCheckout(t *testing.T) {
	canon := fakeCanon(t)
	dir := filepath.Join(t.TempDir(), "proj")
	gd := filepath.Join(t.TempDir(), "proj.git")
	if out, err := exec.Command("git", "init", "-q", "--separate-git-dir", gd, dir).CombinedOutput(); err != nil {
		t.Skipf("git init --separate-git-dir: %v %s", err, out)
	}
	if fi, err := os.Lstat(filepath.Join(dir, ".git")); err != nil || fi.IsDir() {
		t.Fatal("the fixture must have a .git file")
	}
	if isLinkedWorktree(dir) {
		t.Fatal("a --separate-git-dir checkout is not a linked worktree")
	}
	LinkWorktree(canon, dir)
	if !hasLine(filepath.Join(dir, ".gitignore"), "/.claude/agents") {
		t.Error("a main checkout with a .git file must get its ignore lines in .gitignore")
	}
}

// t-f5e4, prod path: the daemon's session start in a worktree, the board's create-worktree route and (through the bash twin)
// `tkt land` link a worktree whose content a branch or cloud PR controls. A symlink planted there must never make canon write,
// create or delete anything outside the worktree.
func listing(t *testing.T, dir string) string {
	t.Helper()
	var b strings.Builder
	must(t, filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		b.WriteString(rel + "|" + fi.Mode().String() + "|")
		if fi.Mode().IsRegular() {
			c, _ := os.ReadFile(p)
			b.Write(c)
		}
		b.WriteString("\n")
		return nil
	}))
	return b.String()
}

func plant(t *testing.T, target, link string) {
	t.Helper()
	must(t, os.MkdirAll(filepath.Dir(link), 0o755))
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
}

func TestLinkWorktreeNeverWritesThroughPlantedLinks(t *testing.T) {
	canon := fakeCanon(t)
	t.Run("agent file symlinked to an outside file that holds the canon marker", func(t *testing.T) {
		wt, out := gitRepo(t), t.TempDir()
		victim := filepath.Join(out, "zshrc")
		must(t, os.WriteFile(victim, []byte("<!-- canon:agent -->\nmine\n"), 0o644))
		must(t, os.MkdirAll(filepath.Join(wt, ".claude", "agents"), 0o755))
		plant(t, victim, filepath.Join(wt, ".claude", "agents", "canon-evaluator.md"))
		did := LinkWorktree(canon, wt)
		if b, _ := os.ReadFile(victim); string(b) != "<!-- canon:agent -->\nmine\n" {
			t.Errorf("the outside file was written through the link: %q", b)
		}
		if !strings.Contains(strings.Join(did, "\n"), "not a regular file: left as is") {
			t.Errorf("the refusal must be reported, got %q", did)
		}
	})
	t.Run("agent file symlinked to a path that does not exist", func(t *testing.T) {
		wt, out := gitRepo(t), t.TempDir()
		victim := filepath.Join(out, "new-file")
		must(t, os.MkdirAll(filepath.Join(wt, ".claude", "agents"), 0o755))
		plant(t, victim, filepath.Join(wt, ".claude", "agents", "canon-evaluator.md"))
		LinkWorktree(canon, wt)
		if exists(victim) {
			t.Error("a dangling link made canon create a file outside the worktree")
		}
	})
	for _, dir := range []string{".claude", ".agents"} {
		t.Run(dir+" symlinked to an outside folder", func(t *testing.T) {
			wt, out := gitRepo(t), t.TempDir()
			must(t, os.WriteFile(filepath.Join(out, "keep"), []byte("x"), 0o644))
			plant(t, out, filepath.Join(wt, dir))
			before := listing(t, out)
			did := LinkWorktree(canon, wt)
			if after := listing(t, out); after != before {
				t.Errorf("the outside folder changed:\nbefore %q\nafter  %q", before, after)
			}
			if !strings.Contains(strings.Join(did, "\n"), "under a link: left as is") {
				t.Errorf("the refusal must be reported, got %q", did)
			}
		})
	}
	t.Run(".gitignore symlinked to an outside file in a main checkout", func(t *testing.T) {
		wt, out := gitRepo(t), t.TempDir()
		victim := filepath.Join(out, "shared-ignore")
		must(t, os.WriteFile(victim, []byte("node_modules\n"), 0o644))
		plant(t, victim, filepath.Join(wt, ".gitignore"))
		did := LinkWorktree(canon, wt)
		if b, _ := os.ReadFile(victim); string(b) != "node_modules\n" {
			t.Errorf("the outside .gitignore was appended to: %q", b)
		}
		if !strings.Contains(strings.Join(did, "\n"), "is not a regular file: left as is") {
			t.Errorf("the refusal must be reported, got %q", did)
		}
	})
}

// t-f5e4, prod path: every file canon writes into a worktree (the agent copies, the ignore file) goes through writeFileNoFollow.
// notRegular refuses a link first, so this is the layer under it: a link swapped in between the check and the open must still not
// be followed. Windows has no O_NOFOLLOW (noFollow is 0 there).
func TestWriteFileNoFollowRefusesALink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no O_NOFOLLOW on Windows")
	}
	dir, out := t.TempDir(), t.TempDir()
	live := filepath.Join(out, "live")
	must(t, os.WriteFile(live, []byte("keep"), 0o644))
	plant(t, live, filepath.Join(dir, "to-live"))
	plant(t, filepath.Join(out, "gone"), filepath.Join(dir, "to-gone"))
	for _, l := range []string{"to-live", "to-gone"} {
		if writeFileNoFollow(filepath.Join(dir, l), []byte("canon")) == nil {
			t.Errorf("%s: a write through a link must fail", l)
		}
	}
	if b, _ := os.ReadFile(live); string(b) != "keep" {
		t.Errorf("the linked file was written: %q", b)
	}
	if exists(filepath.Join(out, "gone")) {
		t.Error("a dangling link made the write create its target")
	}
	plain := filepath.Join(dir, "plain")
	must(t, writeFileNoFollow(plain, []byte("canon")))
	if b, _ := os.ReadFile(plain); string(b) != "canon" {
		t.Errorf("a plain file must be written: %q", b)
	}
}
