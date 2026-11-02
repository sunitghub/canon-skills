// wtmerge.go — t-2906: the board's view of a worktree ticket waiting for Check & merge.
package board

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// annotateWorktreeMerge marks a closed, unmerged ticket that was not sent to GitHub and is bound (.cockpit-cwd) to an existing
// linked worktree whose branch is not yet in the main checkout's branch: wt_merge {branch, path}. The card then offers Check &
// merge, which runs tkt merge; every check that decides a merge is tkt's, so this only decides whether the button shows.
// `git worktree list` runs once per request, and only when some ticket could need it.
func annotateWorktreeMerge(tickets []ticket, root string) {
	tdir := ticketsDirForRoot(root)
	var wts []map[string]any
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
		if wts == nil {
			wts = listWorktreesBase("", root)
		}
		for _, e := range wts {
			path := fmt.Sprint(e["path"])
			if isMain, _ := e["is_main"].(bool); isMain || pathKey(path) != pathKey(cwd) {
				continue
			}
			branch, _ := e["branch"].(string)
			head, _ := e["head"].(string)
			// The ticket's own work is the commit its evaluator graded: once that is in main, this ticket is done even when a
			// later ticket has moved the long-lived worktree branch on (review of t-2906).
			if g := gradedHead(filepath.Join(tdir, id, "eval-report.md")); g != "" {
				if _, in := gitCtx(root, "merge-base", "--is-ancestor", g, "HEAD"); in {
					break
				}
			}
			if fi, err := os.Stat(path); err == nil && fi.IsDir() && branch != "" && head != "" {
				if _, in := gitCtx(root, "merge-base", "--is-ancestor", head, "HEAD"); !in {
					t["wt_merge"] = map[string]any{"branch": branch, "path": path}
				}
			}
			break
		}
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
