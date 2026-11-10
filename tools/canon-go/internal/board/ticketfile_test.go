package board

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Protects the ticket loader (loadTickets, behind /api/tickets and /api/v1/tickets, t-ca73): it reads only a regular, non-link file of
// at most 4 MB from a ticket folder. A symlinked ticket.md is not listed and its target is never read, a symlinked or oversize
// acceptance.md or plan.md is treated as absent, and a regular ticket still parses as before.

func ticketIDs(root string) map[string]ticket {
	out := map[string]ticket{}
	for _, t := range loadTickets(root) {
		out[t["id"].(string)] = t
	}
	return out
}

func writeTicket(t *testing.T, root, id string) string {
	t.Helper()
	dir := filepath.Join(root, ".tickets", id)
	writeFile(t, filepath.Join(dir, "ticket.md"), "---\nid: "+id+"\nstatus: open\n---\n# Title "+id+"\n")
	return dir
}

func TestTicketFileRegularFilesParseAsBefore(t *testing.T) {
	root := setupTestProject(t)
	dir := writeTicket(t, root, "t-aaaa")
	writeFile(t, filepath.Join(dir, "acceptance.md"), "## Criteria\n- [ ] x\n## Test Plan\n- [ ] y\n")
	writeFile(t, filepath.Join(dir, "plan.md"), "## Sign-off\n- [x] Plan approved\n## Approach\nreal text here\n")
	got := ticketIDs(root)["t-aaaa"]
	if got == nil || got["title"] != "Title t-aaaa" || got["acceptance_has_items"] != true || got["plan_approved"] != true || got["plan_has_approach"] != true {
		t.Errorf("regular files: %v", got)
	}
}

func TestTicketFileSymlinkedTicketIsOmittedAndItsTargetNeverRead(t *testing.T) {
	root := setupTestProject(t)
	writeTicket(t, root, "t-good")
	outside := filepath.Join(t.TempDir(), "x.md")
	writeFile(t, outside, "---\nid: t-evil\nstatus: open\n---\n# Heading from outside\n")
	os.MkdirAll(filepath.Join(root, ".tickets", "t-evil"), 0o755)
	if err := os.Symlink(outside, filepath.Join(root, ".tickets", "t-evil", "ticket.md")); err != nil {
		t.Skip("cannot create a symlink here:", err)
	}
	got := ticketIDs(root)
	if got["t-good"] == nil {
		t.Errorf("the real ticket vanished: %v", got)
	}
	for id, tk := range got {
		if id == "t-evil" || strings.Contains(tk["title"].(string), "outside") {
			t.Errorf("a symlinked ticket.md was read: %v", tk)
		}
	}
}

func TestTicketFileSymlinkedAndOversizeDocsAreAbsent(t *testing.T) {
	root := setupTestProject(t)
	dir := writeTicket(t, root, "t-aaaa")
	outside := filepath.Join(t.TempDir(), "acc.md")
	writeFile(t, outside, "## Criteria\n- [ ] x\n## Test Plan\n- [ ] y\n")
	if err := os.Symlink(outside, filepath.Join(dir, "acceptance.md")); err != nil {
		t.Skip("cannot create a symlink here:", err)
	}
	writeFile(t, filepath.Join(dir, "plan.md"), "## Sign-off\n- [x] Plan approved\n## Approach\n"+strings.Repeat("x", ticketFileMax+10)+"\n")
	got := ticketIDs(root)["t-aaaa"]
	if got == nil {
		t.Fatal("the ticket should still be listed")
	}
	if got["acceptance_has_items"] != nil || got["plan_approved"] != nil || got["plan_has_approach"] != nil {
		t.Errorf("a symlinked acceptance.md or an oversize plan.md was read: %v", got)
	}
}

func TestTicketFileOversizeTicketIsOmitted(t *testing.T) {
	root := setupTestProject(t)
	writeFile(t, filepath.Join(root, ".tickets", "t-big", "ticket.md"), "---\nid: t-big\nstatus: open\n---\n# Big\n"+strings.Repeat("x", ticketFileMax+10)+"\n")
	writeTicket(t, root, "t-aaaa")
	got := ticketIDs(root)
	if got["t-big"] != nil || got["t-aaaa"] == nil {
		t.Errorf("an oversize ticket.md must be omitted and the rest kept: %v", got)
	}
	if _, err := readTicketFile(filepath.Join(root, ".tickets", "t-aaaa", "ticket.md")); err != nil {
		t.Errorf("a small regular file: %v", err)
	}
	exact := filepath.Join(t.TempDir(), "exact.md")
	writeFile(t, exact, strings.Repeat("y", ticketFileMax))
	if raw, err := readTicketFile(exact); err != nil || len(raw) != ticketFileMax {
		t.Errorf("a file of exactly the cap is read: %d %v", len(raw), err)
	}
}
