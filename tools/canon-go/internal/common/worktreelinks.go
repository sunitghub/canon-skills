// worktreelinks.go — t-74d8: the links a git worktree needs to reach canon, in Go. A worktree has none of its own: the
// skill mirrors and the gate agents are gitignored links, so `git worktree add` leaves them out. The rules are
// tools/skills/project.sh's link_worktree, upsert_gate_agents and _ensure_mirror_gitignored, in the same order, kept
// in step by tests/worktree-links-parity.sh: the board and the daemon run where bash may not be (Windows), so the rule
// lives in both languages. The board calls it when it creates a worktree, the daemon before it starts a session in one.
package common

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// LinkWorktree links wt's .claude/skills, .agents/skills and .claude/agents to canon's (canonRoot's skills/ and
// agents/) and keeps them gitignored. It is idempotent and never overwrites a folder or file the project owns. It
// returns one line per change, for a log.
func LinkWorktree(canonRoot, wt string) []string {
	var did []string
	skills := filepath.Clean(filepath.Join(canonRoot, "skills"))
	if isDir(skills) {
		for _, rel := range []string{".claude/skills", ".agents/skills"} {
			link := filepath.Join(wt, filepath.FromSlash(rel))
			if underLink(wt, link) {
				did = append(did, link+" is under a link: left as is")
				continue
			}
			switch {
			case isDirLink(link):
				if sameDir(readDirLink(link), skills) {
					continue
				}
				createDirLink(skills, link)
			case exists(link):
				// t-9e55: a git-tracked committed canon mirror (it carries sprint/SKILL.md) is replaced so the worktree
				// serves current canon; a genuine project-local skills folder is left alone.
				if tracked(wt, rel) && exists(filepath.Join(link, "sprint", "SKILL.md")) {
					_ = os.RemoveAll(link)
					createDirLink(skills, link)
					did = append(did, "replaced committed mirror: "+link)
				}
				continue
			default:
				_ = os.MkdirAll(filepath.Dir(link), 0o755)
				createDirLink(skills, link)
			}
			did = append(did, "linked "+link)
		}
	}
	did = append(did, linkGateAgents(canonRoot, wt)...)
	return append(did, ensureMirrorGitignored(wt)...)
}

// linkGateAgents is upsert_gate_agents: canon's close-gate agents (agents/canon-*.md) where Claude Code loads them.
func linkGateAgents(canonRoot, wt string) []string {
	target := filepath.Clean(filepath.Join(canonRoot, "agents"))
	if !isDir(target) {
		return nil
	}
	link := filepath.Join(wt, ".claude", "agents")
	if underLink(wt, link) {
		return []string{link + " is under a link: left as is"}
	}
	_ = os.MkdirAll(filepath.Join(wt, ".claude"), 0o755)
	switch {
	case isDirLink(link):
		cur := readDirLink(link)
		if sameDir(cur, target) {
			return ensureLine(wt, "/.claude/agents")
		}
		if !isDir(cur) || isCanonAgentsDir(cur) {
			createDirLink(target, link)
			return append([]string{"updated link: " + link}, ensureLine(wt, "/.claude/agents")...)
		}
		return []string{link + " links elsewhere (not canon): left as is"}
	case isDir(link):
		var did []string
		srcs, _ := filepath.Glob(filepath.Join(target, "canon-*.md"))
		for _, src := range srcs {
			dst := filepath.Join(link, filepath.Base(src))
			if notRegular(dst) {
				did = append(did, dst+" is not a regular file: left as is")
				continue
			}
			if b, err := os.ReadFile(dst); err == nil && !bytes.Contains(b, []byte("canon:agent")) {
				did = append(did, dst+" exists and is not canon-managed: left as is")
				continue
			}
			want, err := os.ReadFile(src)
			if err != nil {
				continue
			}
			if have, err := os.ReadFile(dst); err != nil || !bytes.Equal(have, want) {
				if writeFileNoFollow(dst, want) == nil {
					did = append(did, "copied: "+dst)
				}
			}
		}
		return did
	case exists(link) || isDirLink(link):
		return []string{link + " is not a directory: left as is"}
	default:
		createDirLink(target, link)
		return append([]string{"created link: " + link}, ensureLine(wt, "/.claude/agents")...)
	}
}

// isLinkedWorktree: git's own folder differs from the repository's common one only in a linked worktree. A submodule or a
// --separate-git-dir checkout also has a .git FILE, but is a main checkout (the reviewer's t-74d8 finding).
func isLinkedWorktree(dir string) bool {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir").Output()
	if err != nil {
		return false
	}
	f := strings.Split(strings.TrimSpace(string(out)), "\n")
	return len(f) == 2 && !sameDir(strings.TrimSpace(f[0]), strings.TrimSpace(f[1]))
}

// ignoreFile is where wt's ignore lines go (t-74d8, user's choice): in a linked worktree git's own
// info/exclude, which is untracked and shared by the repository's worktrees, so linking never leaves a .gitignore change on
// the sprint's branch (it blocked `tkt land --finish`); in a main checkout the project's .gitignore, as skills.sh add does.
func ignoreFile(wt string) string {
	if isLinkedWorktree(wt) {
		out, err := exec.Command("git", "-C", wt, "rev-parse", "--git-path", "info/exclude").Output()
		if p := strings.TrimSpace(string(out)); err == nil && p != "" {
			if !filepath.IsAbs(p) {
				p = filepath.Join(wt, p)
			}
			_ = os.MkdirAll(filepath.Dir(p), 0o755)
			return p
		}
	}
	return filepath.Join(wt, ".gitignore")
}

// ensureMirrorGitignored is _ensure_mirror_gitignored: the mirror links and the close's run records are never committed.
func ensureMirrorGitignored(wt string) []string {
	if !insideWorkTree(wt) {
		return nil
	}
	var did []string
	gi := ignoreFile(wt)
	if notRegular(gi) {
		return []string{gi + " is not a regular file: left as is"}
	}
	for _, entry := range []string{"/.claude/skills", "/.agents/skills"} {
		if hasLine(gi, entry+"/") { // the directory-only line an earlier canon wrote: replace it, or drop it if the bare line exists
			have := hasLine(gi, entry)
			raw, _ := os.ReadFile(gi)
			var out []string
			for _, l := range strings.SplitAfter(string(raw), "\n") {
				if strings.TrimRight(strings.TrimRight(l, "\n"), "\r") == entry+"/" {
					if !have {
						out = append(out, entry+"\n")
					}
					continue
				}
				out = append(out, l)
			}
			_ = writeFileNoFollow(gi, []byte(strings.Join(out, "")))
			did = append(did, "gitignore: "+entry+" (replaced "+entry+"/)")
		}
		did = append(did, ensureLine(wt, entry)...)
		rel := strings.TrimPrefix(entry, "/")
		if tracked(wt, rel) {
			_ = exec.Command("git", "-C", wt, "rm", "-r", "--cached", "--quiet", "--", rel).Run()
			did = append(did, "gitignore: untracked previously-committed mirror: "+rel)
		}
	}
	// t-5988: saved approvals (with any password in them) are never committed; the same entry skills.sh's _ensure_mirror_gitignored writes
	for _, entry := range []string{"/.claude/subagent-runs.jsonl", "/.tickets/*/gate-snapshot.txt*", "/.claude/settings.local.json"} {
		did = append(did, ensureLine(wt, entry)...)
	}
	return did
}

// ensureLine adds entry to wt's ignore file (ignoreFile) when it is missing, after a newline if the file does not end in one.
func ensureLine(wt, entry string) []string {
	if !insideWorkTree(wt) {
		return nil
	}
	gi := ignoreFile(wt)
	if notRegular(gi) || hasLine(gi, entry) {
		return nil
	}
	raw, _ := os.ReadFile(gi)
	if len(raw) > 0 && raw[len(raw)-1] != '\n' {
		raw = append(raw, '\n')
	}
	if writeFileNoFollow(gi, append(raw, []byte(entry+"\n")...)) != nil {
		return nil
	}
	return []string{"gitignore: " + entry}
}

func hasLine(file, line string) bool {
	raw, err := os.ReadFile(file)
	if err != nil {
		return false
	}
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.TrimSuffix(l, "\r") == line {
			return true
		}
	}
	return false
}

func isCanonAgentsDir(dir string) bool {
	b, err := os.ReadFile(filepath.Join(dir, "canon-reviewer.md"))
	return err == nil && bytes.Contains(b, []byte("canon:agent"))
}

func insideWorkTree(dir string) bool {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--is-inside-work-tree").Output()
	return err == nil && strings.TrimSpace(string(out)) == "true"
}

func tracked(dir, rel string) bool {
	out, err := exec.Command("git", "-C", dir, "ls-files", "--", rel).Output()
	return err == nil && strings.TrimSpace(string(out)) != ""
}

// underLink (t-f5e4): a branch or cloud PR controls what is in a worktree, so a link planted at .claude, .agents or deeper must not
// carry a write out of it. True when any folder from wt down to p's parent is a symlink or junction, or is not a folder: canon then
// writes nothing below it. Stricter than resolving the path and checking it is inside wt: a link that points back inside is refused too.
func underLink(wt, p string) bool {
	rel, err := filepath.Rel(wt, filepath.Dir(p))
	if err != nil || strings.HasPrefix(rel, "..") {
		return true
	}
	cur := wt
	if rel == "." {
		return false
	}
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if err != nil {
			return false // not there yet: MkdirAll makes a real folder
		}
		if isDirLink(cur) || !fi.IsDir() {
			return true
		}
	}
	return false
}

// notRegular (t-f5e4): true when p exists and is not a plain file (a symlink, even a dangling one, a junction, a folder).
func notRegular(p string) bool {
	fi, err := os.Lstat(p)
	return err == nil && !fi.Mode().IsRegular()
}

// writeFileNoFollow writes p without following a link at its last component (O_NOFOLLOW where the OS has it, noFollow): the
// check in notRegular and this open cannot be raced into a write through a link swapped in between.
func writeFileNoFollow(p string, data []byte) error {
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|noFollow, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func isDir(p string) bool { fi, err := os.Stat(p); return err == nil && fi.IsDir() }

// isDirLink: a symlink, or on Windows a junction (Go reports one as irregular, not as a symlink).
func isDirLink(p string) bool {
	fi, err := os.Lstat(p)
	if err != nil {
		return false
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return true
	}
	if runtime.GOOS == "windows" && fi.Mode()&os.ModeIrregular != 0 {
		_, err := os.Readlink(p)
		return err == nil
	}
	return false
}

func readDirLink(p string) string { t, _ := os.Readlink(p); return t }

// sameDir compares two folders by where they really are (a symlinked temp folder, a case-insensitive Windows path).
func sameDir(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	if ra, err := filepath.EvalSymlinks(a); err == nil {
		a = ra
	}
	if rb, err := filepath.EvalSymlinks(b); err == nil {
		b = rb
	}
	a, b = filepath.Clean(a), filepath.Clean(b)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// createDirLink points link at target, replacing a link already there: a junction on Windows (no elevated rights; mklink
// needs cmd), a symlink elsewhere.
func createDirLink(target, link string) {
	if isDirLink(link) {
		_ = os.Remove(link)
	}
	if runtime.GOOS == "windows" {
		_ = exec.Command("cmd", "/c", "mklink", "/J", link, target).Run()
		return
	}
	_ = os.Symlink(target, link)
}
