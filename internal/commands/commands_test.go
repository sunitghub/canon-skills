package commands

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mkTicket(t *testing.T, dir, id string) string {
	t.Helper()
	d := filepath.Join(dir, id)
	os.MkdirAll(d, 0755)
	return d
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0755)
	os.WriteFile(path, []byte(content), 0644)
}

// ── AddAcceptanceCriterion ──

func TestAddAcceptanceCriterionFileNotFound(t *testing.T) {
	result := AddAcceptanceCriterion(t.TempDir(), "TKT-1", "criterion")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

func TestAddAcceptanceCriterionHeadingNotFound(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "acceptance.md"), "# No heading\n")
	result := AddAcceptanceCriterion(dir, "TKT-1", "New criterion")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	content, _ := os.ReadFile(filepath.Join(d, "acceptance.md"))
	if !strings.Contains(string(content), "New criterion") {
		t.Fatal("New criterion not found in file")
	}
}

func TestAddAcceptanceCriterionAppendBullet(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "acceptance.md"), "## Acceptance Criteria\n- [ ] Existing item\n")
	AddAcceptanceCriterion(dir, "TKT-1", "New item")
	content, _ := os.ReadFile(filepath.Join(d, "acceptance.md"))
	if !strings.Contains(string(content), "- [ ] New item") {
		t.Fatal("New item not found")
	}
}

func TestAddAcceptanceCriterionAppendNumbered(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "acceptance.md"), "## Acceptance Criteria\n1. [ ] First\n")
	AddAcceptanceCriterion(dir, "TKT-1", "Second")
	content, _ := os.ReadFile(filepath.Join(d, "acceptance.md"))
	if !strings.Contains(string(content), "2. [ ] Second") {
		t.Fatal("numbered item not found")
	}
}

func TestAddAcceptanceCriterionBlankLinesBetweenItems(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "acceptance.md"), "## Acceptance Criteria\n- [ ] Item 1\n\n- [ ] Item 2\n")
	AddAcceptanceCriterion(dir, "TKT-1", "Item 3")
	content, _ := os.ReadFile(filepath.Join(d, "acceptance.md"))
	for _, want := range []string{"Item 1", "Item 2", "Item 3"} {
		if !strings.Contains(string(content), want) {
			t.Fatalf("missing: %s", want)
		}
	}
}

func TestAddAcceptanceCriterionEmptyListSection(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "acceptance.md"), "## Acceptance Criteria\n")
	AddAcceptanceCriterion(dir, "TKT-1", "Only item")
	content, _ := os.ReadFile(filepath.Join(d, "acceptance.md"))
	if !strings.Contains(string(content), "- [ ] Only item") {
		t.Fatal("Only item not found")
	}
}

// ── CreateSprintTicket ──

func TestCreateSprintTicketCreates(t *testing.T) {
	dir := t.TempDir()
	result := CreateSprintTicket(dir, "My new ticket", "high")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	tid := result["ticket_id"].(string)
	for _, f := range []string{"ticket.md", "acceptance.md", "test_plan.md"} {
		p := filepath.Join(dir, tid, f)
		if _, err := os.Stat(p); os.IsNotExist(err) {
			t.Fatalf("missing %s", f)
		}
	}
}

func TestCreateSprintTicketHasFrontmatter(t *testing.T) {
	dir := t.TempDir()
	result := CreateSprintTicket(dir, "Test title", "low")
	tid := result["ticket_id"].(string)
	content, _ := os.ReadFile(filepath.Join(dir, tid, "ticket.md"))
	body := string(content)
	if !strings.Contains(body, "id: "+tid) {
		t.Fatal("missing id in frontmatter")
	}
	if !strings.Contains(body, "title: \"Test title\"") {
		t.Fatal("missing title in frontmatter")
	}
	if !strings.Contains(body, "status: open") {
		t.Fatal("missing status in frontmatter")
	}
	if !strings.Contains(body, "priority: low") {
		t.Fatal("missing priority in frontmatter")
	}
}

func TestCreateSprintTicketLongTitleTruncated(t *testing.T) {
	dir := t.TempDir()
	long := strings.Repeat("A", 60)
	result := CreateSprintTicket(dir, long, "medium")
	tid := result["ticket_id"].(string)
	content, _ := os.ReadFile(filepath.Join(dir, tid, "ticket.md"))
	body := string(content)
	if !strings.Contains(body, "...") {
		t.Fatal("expected truncation")
	}
}

// ── UpdateTicketStatus ──

func TestUpdateTicketStatusUpdates(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "ticket.md"), "---\nid: TKT-1\nstatus: open\n---\n\nBody\n")
	result := UpdateTicketStatus(dir, "TKT-1", "closed")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	content, _ := os.ReadFile(filepath.Join(d, "ticket.md"))
	if !strings.Contains(string(content), "status: closed") {
		t.Fatal("status not updated")
	}
}

func TestUpdateTicketStatusInvalid(t *testing.T) {
	result := UpdateTicketStatus(t.TempDir(), "TKT-1", "bogus")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error for invalid status")
	}
}

func TestUpdateTicketStatusNotFound(t *testing.T) {
	result := UpdateTicketStatus(t.TempDir(), "NONEXIST", "closed")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error for not found")
	}
}

func TestUpdateTicketStatusOnlyFrontmatterChanged(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "ticket.md"), "---\nid: TKT-1\nstatus: open\n---\n\nStatus: do not touch this\n")
	UpdateTicketStatus(dir, "TKT-1", "closed")
	content, _ := os.ReadFile(filepath.Join(d, "ticket.md"))
	body := string(content)
	if !strings.Contains(body, "status: closed") {
		t.Fatal("frontmatter status not updated")
	}
	if !strings.Contains(body, "Status: do not touch this") {
		t.Fatal("body status was modified")
	}
}

// ── GetTicket ──

func TestGetTicketNotFound(t *testing.T) {
	result := GetTicket(t.TempDir(), "NONEXIST")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

func TestGetTicketReturns(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "TKT-0001", "ticket.md"), "---\nid: TKT-0001\n---\n\nBody\n")
	writeFile(t, filepath.Join(dir, "TKT-0001", "acceptance.md"), "## Acceptance Criteria\n- [ ] Item\n")
	result := GetTicket(dir, "TKT-0001")
	files, ok := result["files"].(map[string]string)
	if !ok {
		t.Fatal("expected files map")
	}
	if _, ok := files["ticket.md"]; !ok {
		t.Fatal("missing ticket.md")
	}
	if _, ok := files["acceptance.md"]; !ok {
		t.Fatal("missing acceptance.md")
	}
	if _, ok := result["plan"]; !ok {
		t.Fatal("missing plan")
	}
}

// ── UpdateTicketBody ──

func TestUpdateTicketBodyReplaces(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "ticket.md"), "---\nid: TKT-1\n---\n\nOld body\n")
	result := UpdateTicketBody(dir, "TKT-1", "New body")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	content, _ := os.ReadFile(filepath.Join(d, "ticket.md"))
	if !strings.Contains(string(content), "New body") {
		t.Fatal("body not updated")
	}
	if strings.Contains(string(content), "Old body") {
		t.Fatal("old body still present")
	}
}

func TestUpdateTicketBodyEmptyRejected(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "ticket.md"), "---\nid: TKT-1\n---\n\nBody\n")
	result := UpdateTicketBody(dir, "TKT-1", "")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error for empty body")
	}
}

func TestUpdateTicketBodyNoFrontmatter(t *testing.T) {
	dir := t.TempDir()
	d := mkTicket(t, dir, "TKT-1")
	writeFile(t, filepath.Join(d, "ticket.md"), "Body\n")
	UpdateTicketBody(dir, "TKT-1", "New body")
	content, _ := os.ReadFile(filepath.Join(d, "ticket.md"))
	if string(content) != "New body" {
		t.Fatalf("expected 'New body', got '%s'", string(content))
	}
}

func TestUpdateTicketBodyNotFound(t *testing.T) {
	result := UpdateTicketBody(t.TempDir(), "NONEXIST", "Body")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

// ── ReadDoc ──

func TestReadDocInvalidName(t *testing.T) {
	result := ReadDoc(t.TempDir(), "TKT-1", "invalid.md")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

func TestReadDocNotFound(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "TKT-1", "ticket.md"), "---\n---\n")
	result := ReadDoc(dir, "TKT-1", "plan.md")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

func TestReadDocReads(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "TKT-1", "ticket.md"), "---\n---\n")
	writeFile(t, filepath.Join(dir, "TKT-1", "acceptance.md"), "## Acceptance Criteria\n- [ ] Green build\n")
	result := ReadDoc(dir, "TKT-1", "acceptance.md")
	if !strings.Contains(result["content"].(string), "Green build") {
		t.Fatal("content missing expected text")
	}
}

// ── WriteDoc ──

func TestWriteDocInvalidName(t *testing.T) {
	result := WriteDoc(t.TempDir(), "TKT-1", "invalid.md", "content")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

func TestWriteDocTicketNotFound(t *testing.T) {
	result := WriteDoc(t.TempDir(), "NONEXIST", "acceptance.md", "content")
	if _, ok := result["error"]; !ok {
		t.Fatal("expected error")
	}
}

func TestWriteDocWrites(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "TKT-1", "ticket.md"), "---\n---\n")
	result := WriteDoc(dir, "TKT-1", "acceptance.md", "## New\n- [ ] Item\n")
	if result["status"] != "ok" {
		t.Fatalf("expected ok, got %v", result)
	}
	content, _ := os.ReadFile(filepath.Join(dir, "TKT-1", "acceptance.md"))
	if !strings.Contains(string(content), "New") {
		t.Fatal("content not written")
	}
}

// ── yamlEscape ──

func TestYamlEscapeBackslash(t *testing.T) {
	got := yamlEscape("a\\b")
	if got != "a\\\\b" {
		t.Fatalf("expected 'a\\\\b', got '%s'", got)
	}
}

func TestYamlEscapeQuotes(t *testing.T) {
	got := yamlEscape(`say "hello"`)
	if got != `say \"hello\"` {
		t.Fatalf("expected 'say \\\"hello\\\"', got '%s'", got)
	}
}

func TestYamlEscapeNewline(t *testing.T) {
	got := yamlEscape("line1\nline2")
	if got != "line1\\nline2" {
		t.Fatalf("expected 'line1\\\\nline2', got '%s'", got)
	}
}

func TestYamlEscapeMultiple(t *testing.T) {
	got := yamlEscape("a\tb\nc")
	if !strings.Contains(got, "\\t") {
		t.Fatal("expected tab escape")
	}
	if !strings.Contains(got, "\\n") {
		t.Fatal("expected newline escape")
	}
}

// ── ValidStatuses ──

func TestValidStatuses(t *testing.T) {
	for _, s := range []string{"open", "in_progress", "closed", "cancelled", "archived"} {
		if !ValidStatuses[s] {
			t.Fatalf("expected valid: %s", s)
		}
	}
	if ValidStatuses["bogus"] {
		t.Fatal("expected invalid: bogus")
	}
}
