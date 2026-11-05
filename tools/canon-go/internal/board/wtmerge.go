// wtmerge.go — t-2906: the board's view of a worktree ticket waiting for Check & merge.
package board

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// annotateWorktreeMerge marks a closed, unmerged ticket that was not sent to GitHub and is bound (.cockpit-cwd) to an existing
// linked worktree whose branch is not yet in the main checkout's branch: wt_merge {branch, path}. The card then offers Check &
// merge, which runs tkt merge; every check that decides a merge is tkt's, so this only decides whether the button shows.
// It runs on every GET /api/tickets, so the common case costs no git call: a ticket bound to the main checkout, to a folder
// that is gone, or to another repository's worktree is skipped by reading the folder's .git file (linkedWorktreeOf); `git worktree list` runs once, only when a candidate is left; the ancestry check runs once per live worktree
// (a branch already in main clears every ticket bound to it); the graded-head check only for a worktree with unmerged work.
func annotateWorktreeMerge(tickets []ticket, root string) {
	tdir := ticketsDirForRoot(root)
	wtDir := filepath.Join(rootOr(root), ".git", "worktrees") // where this repository keeps its linked worktrees
	type cand struct {
		t   ticket
		id  string
		key string
	}
	var cands []cand
	for _, t := range tickets {
		id, _ := t["id"].(string)
		if st, _ := t["status"].(string); st != "closed" || id == "" {
			continue
		}
		if m, _ := t["merged"].(string); m != "" {
			continue
		}
		if r, _ := t["runs"].(string); r == "github" {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(tdir, id, ".cockpit-cwd"))
		cwd := strings.TrimSpace(string(raw))
		if err != nil || cwd == "" {
			continue
		}
		if !linkedWorktreeOf(cwd, wtDir) {
			continue
		}
		cands = append(cands, cand{t, id, pathKey(cwd)})
	}
	if len(cands) == 0 {
		return
	}
	type wt struct{ path, branch, head string }
	var wts []wt
	for i, block := range strings.Split(runGitIn(root, "worktree", "list", "--porcelain"), "\n\n") {
		var w wt
		for _, line := range strings.Split(block, "\n") {
			switch {
			case strings.HasPrefix(line, "worktree "):
				w.path = strings.TrimPrefix(line, "worktree ")
			case strings.HasPrefix(line, "HEAD "):
				w.head = strings.TrimPrefix(line, "HEAD ")
			case strings.HasPrefix(line, "branch "):
				w.branch = strings.TrimPrefix(strings.TrimPrefix(line, "branch "), "refs/heads/")
			}
		}
		if i > 0 && w.path != "" && w.branch != "" && w.head != "" { // the first entry is the main checkout
			wts = append(wts, w)
		}
	}
	base := defaultBranchRef(root)
	waiting := map[string]*wt{} // pathKey -> a live linked worktree whose branch is not in main; nil: in main, or not one
	for _, c := range cands {
		w, seen := waiting[c.key]
		if !seen {
			for i := range wts {
				if pathKey(wts[i].path) == c.key {
					if _, in := gitCtx(root, "merge-base", "--is-ancestor", wts[i].head, base); !in {
						w = &wts[i]
					}
					break
				}
			}
			waiting[c.key] = w
		}
		if w == nil {
			continue
		}
		// The ticket's own work is the commit its evaluator graded: once that is in main, this ticket is done even when a
		// later ticket has moved the long-lived worktree branch on (review of t-2906).
		if g := gradedHead(filepath.Join(tdir, c.id, "eval-report.md")); g != "" {
			if _, in := gitCtx(root, "merge-base", "--is-ancestor", g, base); in {
				continue
			}
		}
		wm := map[string]any{"branch": w.branch, "path": w.path}
		if base != "HEAD" {
			wm["into"] = strings.TrimPrefix(base, "refs/heads/") // t-607a: the dialog and button name the target
		}
		c.t["wt_merge"] = wm
	}
}

var gradedHeadRe = regexp.MustCompile(`(?m)^graded-head: *([0-9a-f]{7,40})`)

// gradedHead is the commit an eval-report.md says its evaluator graded, or "" when there is none to read.
func gradedHead(report string) string {
	raw, err := os.ReadFile(report)
	if err != nil {
		return ""
	}
	if m := gradedHeadRe.FindSubmatch(raw); m != nil {
		return string(m[1])
	}
	return ""
}

// linkedWorktreeOf reports whether dir is a linked worktree whose .git file points into wtDir (<repo>/.git/worktrees), read
// from the file itself so the tickets poll runs no git for it. A main checkout (.git is a folder) or a gone folder is not one.
func linkedWorktreeOf(dir, wtDir string) bool {
	raw, err := os.ReadFile(filepath.Join(dir, ".git"))
	if err != nil {
		return false
	}
	gd := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(raw)), "gitdir:"))
	if !filepath.IsAbs(gd) {
		gd = filepath.Join(dir, gd)
	}
	return pathKey(filepath.Dir(filepath.Clean(gd))) == pathKey(wtDir)
}

// defaultBranchRef is the ref tkt merge merges into (t-e1a2): origin/HEAD's branch, else main, else master, as a local ref; HEAD when
// none exists (a project with no such branch: tkt merge itself refuses, and this keeps the old behaviour).
func defaultBranchRef(root string) string {
	if out, ok := gitCtx(root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"); ok {
		if b := strings.TrimPrefix(strings.TrimSpace(out), "origin/"); b != "" {
			if _, ok := gitCtx(root, "rev-parse", "-q", "--verify", "refs/heads/"+b); ok {
				return "refs/heads/" + b
			}
		}
	}
	for _, b := range []string{"main", "master"} {
		if _, ok := gitCtx(root, "rev-parse", "-q", "--verify", "refs/heads/"+b); ok {
			return "refs/heads/" + b
		}
	}
	return "HEAD"
}
