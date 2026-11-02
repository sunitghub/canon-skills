// wtmerge.go — t-2906: the board's view of a worktree ticket waiting for Check & merge.
package board

import (
	"fmt"
	"os"
	"path/filepath"
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
			if fi, err := os.Stat(path); err == nil && fi.IsDir() && branch != "" && head != "" {
				if _, in := gitCtx(root, "merge-base", "--is-ancestor", head, "HEAD"); !in {
					t["wt_merge"] = map[string]any{"branch": branch, "path": path}
				}
			}
			break
		}
	}
}
