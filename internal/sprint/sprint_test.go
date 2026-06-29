package sprint

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sunitghub/canon-skills/internal/parsers"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0755)
	os.WriteFile(path, []byte(content), 0644)
}

func makeClosableTicket(t *testing.T, ticketsDir, tid string, runEpoch int64) {
	t.Helper()
	writeFile(t, filepath.Join(ticketsDir, tid, "ticket.md"),
		"---\nid: "+tid+"\ntitle: "+tid+"\nstatus: closed\n---\n\nDone.\n")
	writeFile(t, filepath.Join(ticketsDir, tid, "acceptance.md"),
		"## Acceptance Criteria\n- [x] Done\n")
	writeFile(t, filepath.Join(ticketsDir, tid, "plan.md"),
		"---\n---\n\n# Plan\n\n## Sign-off\n\n- [x] Approved\n\n## Decisions\n\n### Some decision\n")
	writeFile(t, filepath.Join(ticketsDir, tid, "eval-report.md"),
		fmtEvalReport(runEpoch))
}

func fmtEvalReport(epoch int64) string {
	return "evaluator-run-id: " + itoa(epoch) + "-0001\npass: all checks ok\n"
}

func seedSubagentLog(t *testing.T, root string, runEpoch int64) {
	t.Helper()
	ts := time.Unix(runEpoch, 0).UTC().Format("2006-01-02T15:04:05Z")
	entry := `{"ts":"` + ts + `","agent_id":"` + itoa(runEpoch) + `-0001"}`
	for _, rel := range parsers.AgentRunLogPaths {
		p := filepath.Join(root, rel)
		os.MkdirAll(filepath.Dir(p), 0755)
		os.WriteFile(p, []byte(entry+"\n"), 0644)
	}
}

func itoa(i int64) string {
	return fmt.Sprintf("%d", i)
}

// ── GetSprintBoard ──

func TestGetSprintBoardEmpty(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".tickets"), 0755)
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	result := GetSprintBoard(dir)
	tickets, ok := result["tickets"].([]any)
	if !ok {
		t.Fatal("expected tickets to be a []any")
	}
	if len(tickets) != 0 {
		t.Fatalf("expected 0 tickets, got %d", len(tickets))
	}
}

func TestGetSprintBoardWithTickets(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	os.MkdirAll(ticketsDir, 0755)
	writeFile(t, filepath.Join(ticketsDir, "TKT-0001", "ticket.md"),
		"---\nid: TKT-0001\ntitle: Test ticket\nstatus: open\npriority: high\n---\n\n## Description\nA test.\n")
	writeFile(t, filepath.Join(dir, "HANDOFF.md"),
		"# Handoff\n\n## Active Tasks\n- Task one\n- Task two\n")
	writeFile(t, filepath.Join(dir, "DECISIONS.md"),
		"# Decisions\n\n| Date | Decision | Reason |\n|---|---|---|\n")

	result := GetSprintBoard(dir)
	tickets := result["tickets"].([]any)
	if len(tickets) != 1 {
		t.Fatalf("expected 1 ticket, got %d", len(tickets))
	}
	if tickets[0].(map[string]any)["id"] != "TKT-0001" {
		t.Fatalf("expected TKT-0001, got %s", tickets[0].(map[string]any)["id"])
	}
}

// ── StartSprint ──

func TestStartSprintNewTicket(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	result := StartSprint(dir, "Sprint task", "", "high")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	tid := result["ticket_id"].(string)
	ticketsDir := filepath.Join(dir, ".tickets")
	for _, p := range []string{
		filepath.Join(ticketsDir, tid, "plan.md"),
		filepath.Join(dir, "DECISIONS.md"),
		filepath.Join(dir, "HANDOFF.md"),
	} {
		if _, err := os.Stat(p); os.IsNotExist(err) {
			t.Fatalf("missing: %s", p)
		}
	}
	active, _ := os.ReadFile(filepath.Join(ticketsDir, "ACTIVE"))
	if strings.TrimSpace(string(active)) != tid {
		t.Fatalf("expected %s in ACTIVE, got %s", tid, string(active))
	}
}

func TestStartSprintExistingTicket(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-0001", "ticket.md"),
		"---\nid: TKT-0001\ntitle: Existing\nstatus: open\n---\n")
	result := StartSprint(dir, "", "TKT-0001", "medium")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	if result["ticket_id"] != "TKT-0001" {
		t.Fatalf("expected TKT-0001, got %s", result["ticket_id"])
	}
}

func TestStartSprintExistingTicketNotFound(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	result := StartSprint(dir, "", "NONEXIST", "medium")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

// ── CloseSprint ──

func TestCloseSprintNoTickets(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".tickets"), 0755)
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error, got %v", result["status"])
	}
}

func TestCloseSprintIncompleteTickets(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "ticket.md"),
		"---\nid: TKT-1\ntitle: TKT-1\nstatus: open\n---\n")
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error, got %v", result["status"])
	}
}

func TestCloseSprintMissingEvalReport(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	makeClosableTicket(t, ticketsDir, "TKT-1", 1705314600)
	os.Remove(filepath.Join(ticketsDir, "TKT-1", "eval-report.md"))
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error, got %v", result["status"])
	}
}

func TestCloseSprintMissingEvalReportSet(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "ticket.md"),
		"---\nid: TKT-1\ntitle: TKT-1\nstatus: closed\n---\n")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "eval-report.md"), "pass: ok\n")
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error, got %v", result["status"])
	}
}

func TestCloseSprintVerdictNotPass(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "ticket.md"),
		"---\nid: TKT-1\ntitle: TKT-1\nstatus: closed\n---\n")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "eval-report.md"),
		"evaluator-run-id: 1705314600-0001\nfail: broke everything\n")
	seedSubagentLog(t, dir, 1705314600)
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error, got %v", result["status"])
	}
}

func TestCloseSprintSubagentRunNotFound(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	makeClosableTicket(t, ticketsDir, "TKT-1", 1705314600)
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error, got %v", result["status"])
	}
}

func TestCloseSprintSuccessful(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	makeClosableTicket(t, ticketsDir, "TKT-1", 1705314600)
	seedSubagentLog(t, dir, 1705314600)
	handoffPath := filepath.Join(dir, "HANDOFF.md")
	writeFile(t, handoffPath, "# Handoff\n\n## Active Tasks\n- Something\n")

	result := CloseSprint(dir)
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	receipt, ok := result["receipt"].(string)
	if !ok {
		t.Fatal("expected receipt string")
	}
	if !strings.Contains(receipt, "Delivery Receipt") {
		t.Fatal("receipt missing Delivery Receipt")
	}
	if !strings.Contains(receipt, "TKT-1") {
		t.Fatal("receipt missing ticket ID")
	}
	handoff, _ := os.ReadFile(handoffPath)
	if !strings.Contains(string(handoff), "Sprint Summary") {
		t.Fatal("HANDOFF.md missing Sprint Summary")
	}
}

func TestCloseSprintDuplicateSummaryGuard(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	makeClosableTicket(t, ticketsDir, "TKT-1", 1705314600)
	seedSubagentLog(t, dir, 1705314600)
	writeFile(t, filepath.Join(dir, "HANDOFF.md"),
		"# Handoff\n\n## Sprint Summary (TKT-1)\nAlready closed.\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error, got %v", result["status"])
	}
}

// ── Trivial tier (S2): frontmatter only ──

func TestCloseSprintTrivialTierInFrontmatterAllowed(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "ticket.md"),
		"---\nid: TKT-1\ntitle: TKT-1\nstatus: closed\n---\n")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "plan.md"),
		"---\ntier: trivial\n---\n\n# Plan\n\nNo eval needed.\n")
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "ok" {
		t.Fatalf("expected ok for trivial-tier ticket, got %v", result)
	}
}

func TestCloseSprintTrivialTierInBodyRejected(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "ticket.md"),
		"---\nid: TKT-1\ntitle: TKT-1\nstatus: closed\n---\n")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "plan.md"),
		"---\n---\n\n# Plan\n\nThis is tier: trivial mentioned casually.\n")
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error when tier only in body, got %v", result)
	}
}

// ── Cancelled/archived gate (S1) ──

func TestCloseSprintCancelledNonTrivialRequiresEvalReport(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "ticket.md"),
		"---\nid: TKT-1\ntitle: TKT-1\nstatus: cancelled\n---\n")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "plan.md"),
		"---\n---\n\n# Plan\n")
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "error" {
		t.Fatalf("expected error for cancelled non-trivial ticket without eval-report, got %v", result)
	}
}

func TestCloseSprintArchivedTrivialTierAllowed(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "ticket.md"),
		"---\nid: TKT-1\ntitle: TKT-1\nstatus: archived\n---\n")
	writeFile(t, filepath.Join(ticketsDir, "TKT-1", "plan.md"),
		"---\ntier: trivial\n---\n\n# Plan\n")
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "ok" {
		t.Fatalf("expected ok for archived trivial-tier ticket, got %v", result)
	}
}

// ── Deterministic sprint ID fallback (B4) ──

func TestCloseSprintDeterministicFallbackNoActive(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0755)
	ticketsDir := filepath.Join(dir, ".tickets")
	os.MkdirAll(ticketsDir, 0755)
	// Seed three cancellable-trivial tickets in a non-sorted entry order.
	for _, id := range []string{"TKT-0010", "TKT-0003", "TKT-0007"} {
		writeFile(t, filepath.Join(ticketsDir, id, "ticket.md"),
			fmt.Sprintf("---\nid: %s\ntitle: %s\nstatus: closed\n---\n", id, id))
		writeFile(t, filepath.Join(ticketsDir, id, "plan.md"),
			"---\ntier: trivial\n---\n\n# Plan\n")
		writeFile(t, filepath.Join(ticketsDir, id, "eval-report.md"),
			"pass: ok\n")
		os.Remove(filepath.Join(ticketsDir, "ACTIVE"))
	}
	writeFile(t, filepath.Join(dir, "HANDOFF.md"), "# Handoff\n")
	result := CloseSprint(dir)
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	handoff, _ := os.ReadFile(filepath.Join(dir, "HANDOFF.md"))
	body := string(handoff)
	if !strings.Contains(body, "Sprint Summary (TKT-0003)") {
		t.Fatalf("expected deterministic fallback ID TKT-0003, got: %s", body)
	}
}

// ── LogSubagentRun ──

func TestLogSubagentRunWritesToSinglePath(t *testing.T) {
	dir := t.TempDir()
	result := LogSubagentRun(dir, "eval-run-1", "evaluator", "sess-1")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	rel := parsers.AgentRunLogPaths[0]
	p := filepath.Join(dir, rel)
	content, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("missing: %s", rel)
	}
	var entry map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(content))), &entry); err != nil {
		t.Fatalf("invalid JSON in %s: %v", rel, err)
	}
	if entry["agent_id"] != "eval-run-1" {
		t.Fatalf("expected eval-run-1, got %s", entry["agent_id"])
	}
	if entry["agent_type"] != "evaluator" {
		t.Fatalf("expected evaluator, got %s", entry["agent_type"])
	}
	if entry["session_id"] != "sess-1" {
		t.Fatalf("expected sess-1, got %s", entry["session_id"])
	}
	for _, rel := range parsers.AgentRunLogPaths[1:] {
		p := filepath.Join(dir, rel)
		if _, err := os.Stat(p); err == nil {
			t.Fatalf("unexpected file at: %s", rel)
		}
	}
}
