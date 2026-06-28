package parsers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0755)
	os.WriteFile(path, []byte(content), 0644)
}

// ── parseTimestamp ──

func TestParseTimestampZ(t *testing.T) {
	ts, err := parseTimestamp("2024-01-15T10:30:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if ts != 1705314600 {
		t.Fatalf("expected 1705314600, got %d", ts)
	}
}

func TestParseTimestampUTCOffset(t *testing.T) {
	ts, err := parseTimestamp("2024-01-15T10:30:00+00:00")
	if err != nil {
		t.Fatal(err)
	}
	if ts != 1705314600 {
		t.Fatalf("expected 1705314600, got %d", ts)
	}
}

func TestParseTimestampFractional(t *testing.T) {
	ts, err := parseTimestamp("2024-01-15T10:30:00.123456Z")
	if err != nil {
		t.Fatal(err)
	}
	if ts != 1705314600 {
		t.Fatalf("expected 1705314600, got %d", ts)
	}
}

// ── ParseTickets ──

func TestParseTicketsEmptyDir(t *testing.T) {
	dir := t.TempDir()
	d := filepath.Join(dir, ".tickets")
	os.MkdirAll(d, 0755)
	tickets := ParseTickets(d)
	if len(tickets) != 0 {
		t.Fatalf("expected 0, got %d", len(tickets))
	}
}

func TestParseTicketsNonexistentDir(t *testing.T) {
	tickets := ParseTickets(filepath.Join(t.TempDir(), "nope"))
	if len(tickets) != 0 {
		t.Fatalf("expected 0, got %d", len(tickets))
	}
}

func TestParseTicketsParses(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "TKT-0001", "ticket.md"),
		"---\nid: TKT-0001\ntitle: Setup CI\nstatus: open\npriority: high\n---\n\n## Description\nSet up CI.\n\n## Acceptance Criteria\n- [ ] Green build\n")
	writeFile(t, filepath.Join(dir, "TKT-0002", "ticket.md"),
		"---\nid: TKT-0002\ntitle: Add tests\nstatus: closed\npriority: medium\n---\n\n## Description\nWrite unit tests.\n")

	tickets := ParseTickets(dir)
	if len(tickets) != 2 {
		t.Fatalf("expected 2, got %d", len(tickets))
	}

	var t1, t2 bool
	for _, tr := range tickets {
		switch tr.ID {
		case "TKT-0001":
			t1 = true
			if tr.Status != "open" {
				t.Fatalf("expected open, got %s", tr.Status)
			}
			if tr.Title != "Setup CI" {
				t.Fatalf("expected Setup CI, got %s", tr.Title)
			}
			if tr.Priority != "high" {
				t.Fatalf("expected high, got %s", tr.Priority)
			}
		case "TKT-0002":
			t2 = true
			if tr.Status != "closed" {
				t.Fatalf("expected closed, got %s", tr.Status)
			}
			if tr.Description != "Write unit tests." {
				t.Fatalf("expected Write unit tests., got %s", tr.Description)
			}
		}
	}
	if !t1 || !t2 {
		t.Fatal("missing expected tickets")
	}
}

func TestParseTicketsNoFrontmatter(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "TKT-X", "ticket.md"),
		"TKT-X\n## Description\nSomething\n")
	tickets := ParseTickets(dir)
	if len(tickets) != 1 {
		t.Fatalf("expected 1, got %d", len(tickets))
	}
	if tickets[0].ID != "TKT-X" {
		t.Fatalf("expected TKT-X, got %s", tickets[0].ID)
	}
}

// ── ParseHandoff ──

func TestParseHandoffMissingFile(t *testing.T) {
	h := ParseHandoff(filepath.Join(t.TempDir(), "HANDOFF.md"))
	if len(h.ActiveTasks) != 0 {
		t.Fatalf("expected 0 tasks, got %d", len(h.ActiveTasks))
	}
}

func TestParseHandoffWithTasks(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "HANDOFF.md")
	os.WriteFile(p, []byte("# Handoff\n\n## Active Tasks\n- Task one\n- Task two\n\n## Next\n"), 0644)
	h := ParseHandoff(p)
	if len(h.ActiveTasks) != 2 {
		t.Fatalf("expected 2 tasks, got %d", len(h.ActiveTasks))
	}
	if h.ActiveTasks[0] != "Task one" {
		t.Fatalf("expected Task one, got %s", h.ActiveTasks[0])
	}
}

func TestParseHandoffBoldMarkupStripped(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "HANDOFF.md")
	os.WriteFile(p, []byte("# Handoff\n\n## Active Tasks\n- **bold** task\n- *italic* task\n"), 0644)
	h := ParseHandoff(p)
	if len(h.ActiveTasks) != 2 {
		t.Fatalf("expected 2 tasks, got %d", len(h.ActiveTasks))
	}
	if h.ActiveTasks[0] != "bold task" {
		t.Fatalf("expected 'bold task', got '%s'", h.ActiveTasks[0])
	}
	if h.ActiveTasks[1] != "italic task" {
		t.Fatalf("expected 'italic task', got '%s'", h.ActiveTasks[1])
	}
}

func TestParseHandoffNoTasksSection(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "HANDOFF.md")
	os.WriteFile(p, []byte("# Handoff\n\nNothing here.\n"), 0644)
	h := ParseHandoff(p)
	if len(h.ActiveTasks) != 0 {
		t.Fatalf("expected 0 tasks, got %d", len(h.ActiveTasks))
	}
}

// ── extractSection (via getSection) ──

func TestGetSectionFound(t *testing.T) {
	content := "## Sign-off\n\n- [x] Approved\n"
	got := getSection(content, "Sign-off")
	if got != "- [x] Approved" {
		t.Fatalf("expected '- [x] Approved', got '%s'", got)
	}
}

func TestGetSectionMissing(t *testing.T) {
	got := getSection("## Other\n\nstuff\n", "Sign-off")
	if got != "" {
		t.Fatalf("expected empty, got '%s'", got)
	}
}

func TestGetSectionAtEnd(t *testing.T) {
	content := "# Doc\n\n## Last Section\n\nfinal content\n"
	got := getSection(content, "Last Section")
	if got != "final content" {
		t.Fatalf("expected 'final content', got '%s'", got)
	}
}

// ── ParsePlanApproved ──

func TestParsePlanApprovedNoFile(t *testing.T) {
	if ParsePlanApproved(filepath.Join(t.TempDir(), "nope.md")) {
		t.Fatal("expected false for missing file")
	}
}

func TestParsePlanApprovedTrue(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "plan.md")
	os.WriteFile(p, []byte("---\nid: TKT-1\n---\n\n# Plan\n\n## Approach\nDo it.\n\n## Sign-off\n\n- [x] Approved\n"), 0644)
	if !ParsePlanApproved(p) {
		t.Fatal("expected true")
	}
}

func TestParsePlanApprovedFalse(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "plan.md")
	os.WriteFile(p, []byte("## Sign-off\n\n- [ ] Not yet\n"), 0644)
	if ParsePlanApproved(p) {
		t.Fatal("expected false")
	}
}

// ── ParsePlanDecision ──

func TestParsePlanDecisionNoFile(t *testing.T) {
	if ParsePlanDecision(filepath.Join(t.TempDir(), "nope.md")) != "" {
		t.Fatal("expected empty for missing file")
	}
}

func TestParsePlanDecisionHasDecision(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "plan.md")
	os.WriteFile(p, []byte("---\n---\n\n# Plan\n\n## Approach\nDo it.\n\n## Sign-off\n\n- [x] Approved\n\n## Decisions\n\n### Use FastMCP\n\nReason: Quick.\n"), 0644)
	got := ParsePlanDecision(p)
	if got != "Use FastMCP" {
		t.Fatalf("expected 'Use FastMCP', got '%s'", got)
	}
}

func TestParsePlanDecisionNoDecision(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "plan.md")
	os.WriteFile(p, []byte("## Decisions\n\nNothing decided.\n"), 0644)
	if ParsePlanDecision(p) != "" {
		t.Fatal("expected empty")
	}
}

// ── CheckSubagentRun ──

func TestCheckSubagentRunMatchFound(t *testing.T) {
	dir := t.TempDir()
	entry := `{"ts":"2024-01-15T10:30:00Z","agent_id":"eval-1"}`
	epoch := int64(1705314600)
	for _, rel := range AgentRunLogPaths {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0755)
		os.WriteFile(p, []byte(entry+"\n"), 0644)
	}
	if !CheckSubagentRun(dir, epoch) {
		t.Fatal("expected match found")
	}
}

func TestCheckSubagentRunNoMatch(t *testing.T) {
	dir := t.TempDir()
	entry := `{"ts":"2024-01-15T12:30:00Z","agent_id":"eval-1"}`
	epoch := int64(1705314600)
	for _, rel := range AgentRunLogPaths {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0755)
		os.WriteFile(p, []byte(entry+"\n"), 0644)
	}
	if CheckSubagentRun(dir, epoch) {
		t.Fatal("expected no match")
	}
}

func TestCheckSubagentRunEmptyLog(t *testing.T) {
	dir := t.TempDir()
	for _, rel := range AgentRunLogPaths {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0755)
		os.WriteFile(p, []byte(""), 0644)
	}
	if CheckSubagentRun(dir, 1705314600) {
		t.Fatal("expected false for empty log")
	}
}

func TestCheckSubagentRunMissingLog(t *testing.T) {
	if CheckSubagentRun(t.TempDir(), 1705314600) {
		t.Fatal("expected false for missing log")
	}
}

func TestCheckSubagentRunNoTimestampField(t *testing.T) {
	dir := t.TempDir()
	entry := `{"agent_id":"eval-1"}`
	for _, rel := range AgentRunLogPaths {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0755)
		os.WriteFile(p, []byte(entry+"\n"), 0644)
	}
	if CheckSubagentRun(dir, 1705314600) {
		t.Fatal("expected false for entry without ts")
	}
}

// ── ParseFrontmatterRaw ──

func TestParseFrontmatterRaw(t *testing.T) {
	data := ParseFrontmatterRaw("---\nname: sprint\ndescription: Test\nhidden: false\n---\n# Content\n")
	if data["name"] != "sprint" {
		t.Fatalf("expected sprint, got %s", data["name"])
	}
	if data["description"] != "Test" {
		t.Fatalf("expected Test, got %s", data["description"])
	}
	if data["hidden"] != "false" {
		t.Fatalf("expected false, got %s", data["hidden"])
	}
}

func TestParseFrontmatterRawEmpty(t *testing.T) {
	data := ParseFrontmatterRaw("# No frontmatter\n")
	if len(data) != 0 {
		t.Fatalf("expected empty, got %d", len(data))
	}
}

// ── json round-trip for AgentRunLogPaths entries (helpers) ──

func TestJsonlEntryRoundTrip(t *testing.T) {
	entry := map[string]any{
		"ts":         "2024-01-15T10:30:00Z",
		"session_id": "sess-1",
		"agent_id":   "eval-1",
		"agent_type": "evaluator",
	}
	b, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(b, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["ts"] != "2024-01-15T10:30:00Z" {
		t.Fatal("ts mismatch after round-trip")
	}
}
