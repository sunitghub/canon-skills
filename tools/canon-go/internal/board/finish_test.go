package board

import (
	"os"
	"path/filepath"
	"testing"
)

// t-607a: protects the card's Finish step (GET /api/tickets' finish): shown for a ticket tkt merge merged while its push or its
// reset is still to do, read from `tkt finish <id> --check`; never once both are done, dismissed, sent to GitHub or not merged by tkt.
func TestAnnotateWorktreeFinish(t *testing.T) {
	dir := t.TempDir()
	stub := filepath.Join(dir, "tkt")
	// The stub prints what the case file says and records that it ran.
	script := "#!/bin/sh\necho ran >> \"" + dir + "/ran\"\ncat \"" + dir + "/answer\"\n"
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TKT_BIN", stub)
	answer := func(s string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, "answer"), []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	const (
		pushTodo  = "finish: push: git push origin main sends 2 commit(s) (as last fetched):\n  abc1234 x\n"
		pushDone  = "finish: push: main is already on origin\n"
		resetTodo = "finish: reset: /w is still on feat/x; tkt worktree-reset there starts the next ticket\n"
		resetDone = "finish: reset: /w is already at origin's main; nothing to reset\n"
	)
	mark := func(root string, fields ticket) map[string]any {
		t.Helper()
		tk := ticket{"id": "t-aaaa", "status": "closed", "merged": "abc1234", "merged_into": "main", "merged_branch": "feat/x"}
		for k, v := range fields {
			if v == nil {
				delete(tk, k)
			} else {
				tk[k] = v
			}
		}
		annotateWorktreeFinish([]ticket{tk}, root)
		f, _ := tk["finish"].(map[string]any)
		return f
	}
	root := filepath.Join(dir, "p1")
	os.MkdirAll(root, 0o755)
	os.MkdirAll(filepath.Join(dir, "p2"), 0o755)
	answer(pushTodo + resetTodo)
	if f := mark(root, nil); f == nil || f["into"] != "main" || f["branch"] != "feat/x" || f["push_done"] != false || f["reset_done"] != false {
		t.Fatalf("nothing done: finish = %v", f)
	}
	answer(pushDone + resetTodo)
	if f := mark(root, nil); f == nil || f["push_done"] != true || f["reset_done"] != false {
		t.Fatalf("push done, reset to do: finish = %v", f)
	}
	for name, f := range map[string]ticket{
		"dismissed":      {"finish_dismissed": "2026-11-05T00:00:00Z"},
		"sent to GitHub": {"runs": "github"},
		"not merged":     {"merged": nil},
		"no merged_into": {"merged_into": nil},
		"no branch":      {"merged_branch": nil},
	} {
		os.Remove(filepath.Join(dir, "ran"))
		if m := mark(root, f); m != nil {
			t.Fatalf("%s ticket got finish %v", name, m)
		}
		if _, err := os.Stat(filepath.Join(dir, "ran")); err == nil {
			t.Fatalf("%s ticket started a tkt process", name)
		}
	}
	// Both done: no card, and the next poll asks no one.
	answer(pushDone + resetDone)
	if m := mark(root, nil); m != nil {
		t.Fatalf("push and reset done: finish = %v", m)
	}
	os.Remove(filepath.Join(dir, "ran"))
	answer(pushTodo + resetTodo)
	if m := mark(root, nil); m != nil {
		t.Fatalf("a finished ticket came back: %v", m)
	}
	if _, err := os.Stat(filepath.Join(dir, "ran")); err == nil {
		t.Fatal("a finished ticket started a tkt process again")
	}
	// A failing tkt shows no card rather than a wrong one.
	os.WriteFile(stub, []byte("#!/bin/sh\necho boom\nexit 1\n"), 0o755)
	if m := mark(filepath.Join(dir, "p2"), nil); m != nil {
		t.Fatalf("a failing tkt finish --check gave finish %v", m)
	}
}
