// finish.go — t-607a: the board's view of the Finish step after a worktree ticket's Check & merge (tkt finish, t-e1a2).
package board

import (
	"strings"
	"sync"
)

// finishDone remembers a ticket whose push and reset are both done, so the tickets poll stops running tkt for it. It is only an
// optimisation: a fresh process asks once more and gets the same answer.
var finishDone sync.Map

// annotateWorktreeFinish marks a ticket that tkt merge merged (merged, merged_into and merged_branch set), that was not sent to
// GitHub and whose Finish step was not dismissed: finish {into, branch, push_done, reset_done}. The two answers are tkt's, read from
// `tkt finish <id> --check` (one owner of the git logic); a card with both done gets nothing. Only such tickets start a process.
func annotateWorktreeFinish(tickets []ticket, root string) {
	for _, t := range tickets {
		id, _ := t["id"].(string)
		merged, _ := t["merged"].(string)
		into, _ := t["merged_into"].(string)
		branch, _ := t["merged_branch"].(string)
		if id == "" || merged == "" || into == "" || branch == "" {
			continue
		}
		if d, _ := t["finish_dismissed"].(string); d != "" {
			continue
		}
		if r, _ := t["runs"].(string); r == "github" {
			continue
		}
		key := root + "|" + id + "|" + merged
		if _, done := finishDone.Load(key); done {
			continue
		}
		res := runTkt(root, []string{"finish", id, "--check"})
		if ok, _ := res["ok"].(bool); !ok {
			continue
		}
		out, _ := res["output"].(string)
		push, reset := parseFinishCheck(out)
		if push && reset {
			finishDone.Store(key, true)
			continue
		}
		t["finish"] = map[string]any{"into": into, "branch": branch, "push_done": push, "reset_done": reset}
	}
}

// parseFinishCheck reads tkt finish --check's two lines: "finish: push: ..." is done when origin already has the branch,
// "finish: reset: ..." when the worktree needs nothing (at origin's tip, moved on to new work, or gone).
func parseFinishCheck(out string) (push, reset bool) {
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "finish: push: "):
			push = strings.Contains(line, "already on origin")
		case strings.HasPrefix(line, "finish: reset: "):
			reset = strings.Contains(line, "nothing to reset")
		}
	}
	return
}
