//go:build !windows

package board

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// t-f172: the board reads HANDOFF.md, .worktreeinclude and AGENTS.md at a project root, and ticket.md and .cockpit-cwd in a
// ticket folder; a PR or clone controls all five. A FIFO there must not block the request, and a link out of the project must
// never be followed (HANDOFF.md's text is served). Protects /api/handoff, worktree create, Admin skills, the ticket card's
// gate mode, the interrupted-session list and the worktree lock badge.

// within runs fn and fails when it has not returned in 2 s (a blocking read on a FIFO).
func within(t *testing.T, what string, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { fn(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("%s blocked", what)
	}
}

func mkfifo(t *testing.T, path string) {
	t.Helper()
	os.Remove(path)
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Skip("no mkfifo:", err)
	}
}

// outsideLink makes path a symlink to a file outside the project that holds secret.
func outsideLink(t *testing.T, path, secret string) {
	t.Helper()
	target := filepath.Join(t.TempDir(), "outside.md")
	writeFile(t, target, secret)
	os.Remove(path)
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
}

const skillsBlock = "<!-- AI-SKILLS:BEGIN -->\n| sprint | dev | skills/sprint/SKILL.md |\n<!-- AI-SKILLS:END -->\n"

func checkRootReads(t *testing.T, root, how string) {
	t.Helper()
	within(t, how+" HANDOFF.md", func() {
		if h := loadHandoff(root); h["raw"] != "" {
			t.Errorf("%s HANDOFF.md: raw = %q", how, h["raw"])
		}
	})
	within(t, how+" HANDOFF.md (block-only check)", func() {
		if handoffBlockOnly(root, " M") {
			t.Errorf("%s HANDOFF.md: handoffBlockOnly true", how)
		}
	})
	within(t, how+" .worktreeinclude", func() {
		if p := worktreeIncludePatterns(root); p != nil {
			t.Errorf("%s .worktreeinclude: patterns %v", how, p)
		}
	})
	within(t, how+" AGENTS.md", func() {
		if s := registeredSkills(root); len(s) != 0 {
			t.Errorf("%s AGENTS.md: skills %v", how, s)
		}
	})
}

func TestRootFilesFIFODoesNotBlock(t *testing.T) {
	root := setupTestProject(t)
	for _, n := range []string{"HANDOFF.md", ".worktreeinclude", "AGENTS.md"} {
		mkfifo(t, filepath.Join(root, n))
	}
	checkRootReads(t, root, "FIFO")
}

func TestRootFilesLinkOutIsNotFollowed(t *testing.T) {
	root := setupTestProject(t)
	outsideLink(t, filepath.Join(root, "HANDOFF.md"), "## Current Focus\nSECRET\n")
	outsideLink(t, filepath.Join(root, ".worktreeinclude"), ".env\n")
	outsideLink(t, filepath.Join(root, "AGENTS.md"), skillsBlock)
	checkRootReads(t, root, "link out")
}

func TestRootFilesLinkInsideStillReads(t *testing.T) {
	root := setupTestProject(t)
	writeFile(t, filepath.Join(root, "CLAUDE.md"), skillsBlock)
	if err := os.Symlink("CLAUDE.md", filepath.Join(root, "AGENTS.md")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "docs", "handoff.md"), "## Current Focus\nshared\n")
	if err := os.Symlink(filepath.Join("docs", "handoff.md"), filepath.Join(root, "HANDOFF.md")); err != nil {
		t.Fatal(err)
	}
	if s := registeredSkills(root); len(s) != 1 || s[0] != "sprint" {
		t.Errorf("AGENTS.md -> CLAUDE.md: skills %v", s)
	}
	if h := loadHandoff(root); !strings.Contains(h["raw"].(string), "shared") {
		t.Errorf("HANDOFF.md -> docs/handoff.md: raw %q", h["raw"])
	}
}

func TestTicketFolderFilesFIFOAndLinkOut(t *testing.T) {
	for _, how := range []string{"FIFO", "link out"} {
		root := setupTestProject(t)
		dir := writeTicket(t, root, "t-f172")
		for _, n := range []string{"ticket.md", ".cockpit-cwd"} {
			p := filepath.Join(dir, n)
			if how == "FIFO" {
				mkfifo(t, p)
			} else {
				outsideLink(t, p, "---\nid: t-f172\nstatus: closed\ngate: eval\n---\n"+root+"\n")
			}
		}
		within(t, how+" ticketFM", func() {
			if st, ok := ticketFM(filepath.Join(dir, "ticket.md")); st != "" || ok {
				t.Errorf("%s ticketFM = %q, %v", how, st, ok)
			}
		})
		within(t, how+" ticketGate", func() {
			if g := ticketGate("t-f172"); g != "full" {
				t.Errorf("%s ticketGate = %q", how, g)
			}
		})
		within(t, how+" interruptedReason", func() {
			if r := interruptedReason("t-f172", root, root, "claude"); r != "ticket no longer exists in "+root {
				t.Errorf("%s interruptedReason = %q", how, r)
			}
		})
		within(t, how+" worktreeLockStatus", func() {
			if s := worktreeLockStatus("t-f172", root); s["locked"] != false || s["cwd"] != nil {
				t.Errorf("%s worktreeLockStatus = %v", how, s)
			}
		})
	}
}

// gcoRead and readLogbookFile Lstat first; a FIFO at the path (or swapped in after the Lstat: common's own swap test) must
// read as not a regular file, without blocking.
func TestGcoReadAndLogbookFIFO(t *testing.T) {
	root := setupTestProject(t)
	p := filepath.Join(root, "LEARNINGS.md")
	mkfifo(t, p)
	within(t, "gcoRead FIFO", func() {
		if _, why := gcoRead(p); why != "not a regular file" {
			t.Errorf("gcoRead FIFO: %q", why)
		}
	})
	within(t, "readLogbookFile FIFO", func() {
		if r := readLogbookFile(root, "LEARNINGS.md"); r["error"] != "LEARNINGS.md is not a regular file" {
			t.Errorf("readLogbookFile FIFO: %v", r)
		}
	})
	big := filepath.Join(root, "big.md")
	writeFile(t, big, strings.Repeat("x", gcoMaxFile+1))
	if _, why := gcoRead(big); why != "larger than 256 KB" {
		t.Errorf("gcoRead over cap: %q", why)
	}
}
