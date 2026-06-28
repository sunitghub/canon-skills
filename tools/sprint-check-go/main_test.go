package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
)

func setupTestProject(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	projectRoot = root
	ticketsDir = filepath.Join(root, ".tickets")
	handoffFile = filepath.Join(root, "HANDOFF.md")
	appHTML = filepath.Join(root, "tools", "sprint-check-app", "app.html")
	if err := os.MkdirAll(ticketsDir, 0755); err != nil {
		t.Fatal(err)
	}
	return root
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
}

func runCmd(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v failed: %v\n%s", args, err, out)
	}
}

func TestTicketComputedFieldsAndArchivedFilter(t *testing.T) {
	setupTestProject(t)
	writeFile(t, filepath.Join(ticketsDir, "t-ready", "ticket.md"), `---
id: t-ready
status: open
type: task
priority: 2
created: 2026-06-08T00:00:00Z
---
# Ready plan
`)
	writeFile(t, filepath.Join(ticketsDir, "t-ready", "acceptance.md"), `# Acceptance

## Criteria
- [x] Has criteria

## Test Plan
- [x] Has tests
`)
	writeFile(t, filepath.Join(ticketsDir, "t-ready", "plan.md"), `# Plan

## Sign-off
- [x] Plan approved

## Approach
Use the smallest board-side check.
`)
	writeFile(t, filepath.Join(ticketsDir, "t-archived", "ticket.md"), `---
id: t-archived
status: archived
type: task
priority: 2
created: 2026-01-01T00:00:00Z
---
# Old closed work
`)

	tickets := loadTickets()
	if len(tickets) != 2 {
		t.Fatalf("expected 2 tickets, got %d", len(tickets))
	}
	ready := tickets[0]
	if ready["id"] != "t-ready" && tickets[1]["id"] == "t-ready" {
		ready = tickets[1]
	}
	if ready["layout"] != "folder" {
		t.Fatalf("layout = %v, want folder", ready["layout"])
	}
	if ready["acceptance_has_items"] != true {
		t.Fatalf("acceptance_has_items = %v, want true", ready["acceptance_has_items"])
	}
	if ready["acceptance_unchecked"] != false {
		t.Fatalf("acceptance_unchecked = %v, want false", ready["acceptance_unchecked"])
	}
	if ready["plan_has_approach"] != true {
		t.Fatalf("plan_has_approach = %v, want true", ready["plan_has_approach"])
	}
	if ready["plan_approved"] != true {
		t.Fatalf("plan_approved = %v, want true", ready["plan_approved"])
	}
	if !queryHasAll("page=1&all=1") {
		t.Fatal("queryHasAll should accept all=1 among other query params")
	}

	req := httptest.NewRequest("GET", "http://127.0.0.1/api/tickets?page=1", nil)
	rec := httptest.NewRecorder()
	handle(rec, req)
	if rec.Code != 200 {
		t.Fatalf("default /api/tickets status = %d", rec.Code)
	}
	var defaultTickets []ticket
	if err := json.Unmarshal(rec.Body.Bytes(), &defaultTickets); err != nil {
		t.Fatal(err)
	}
	for _, ticket := range defaultTickets {
		if ticket["id"] == "t-archived" {
			t.Fatal("default /api/tickets included archived ticket")
		}
	}

	req = httptest.NewRequest("GET", "http://127.0.0.1/api/tickets?page=1&all=1", nil)
	rec = httptest.NewRecorder()
	handle(rec, req)
	if rec.Code != 200 {
		t.Fatalf("/api/tickets?all=1 status = %d", rec.Code)
	}
	var allTickets []ticket
	if err := json.Unmarshal(rec.Body.Bytes(), &allTickets); err != nil {
		t.Fatal(err)
	}
	foundArchived := false
	for _, ticket := range allTickets {
		if ticket["id"] == "t-archived" {
			foundArchived = true
		}
	}
	if !foundArchived {
		t.Fatal("/api/tickets?all=1 did not include archived ticket")
	}
}

func TestLegacyDocFallback(t *testing.T) {
	setupTestProject(t)
	writeFile(t, filepath.Join(ticketsDir, "t-abcd", "ticket.md"), `---
id: t-abcd
status: open
type: task
priority: 2
created: 2026-06-27
---
# Legacy docs
`)
	writeFile(t, filepath.Join(ticketsDir, "t-abcd", "acceptance.md"), "legacy mapped acceptance\n")

	content, ok := readDoc("t-abcd-acceptance.md")
	if !ok || content != "legacy mapped acceptance\n" {
		t.Fatalf("readDoc legacy fallback = (%q, %v)", content, ok)
	}
	if !writeDoc("t-abcd-plan.md", "legacy mapped plan") {
		t.Fatal("writeDoc returned false")
	}
	raw, err := os.ReadFile(filepath.Join(ticketsDir, "t-abcd-plan.md"))
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "legacy mapped plan\n" {
		t.Fatalf("flat legacy write content = %q", raw)
	}
}

func TestLoadWhyKeywordFallbackAndDecision(t *testing.T) {
	root := setupTestProject(t)
	runCmd(t, root, "git", "init")
	runCmd(t, root, "git", "config", "user.email", "test@example.com")
	runCmd(t, root, "git", "config", "user.name", "Test User")
	writeFile(t, filepath.Join(ticketsDir, "t-why1", "ticket.md"), `---
id: t-why1
status: closed
type: task
priority: 2
created: 2026-06-27
---
# Improve invoice renderer
`)
	writeFile(t, filepath.Join(ticketsDir, "t-why1", "plan.md"), `# Plan

## Decisions
### Keep renderer local
- The board should show this excerpt.
`)
	writeFile(t, filepath.Join(root, "src", "invoice.js"), "console.log('invoice')\n")
	runCmd(t, root, "git", "add", ".")
	runCmd(t, root, "git", "commit", "-m", "refact invoice renderer paths")

	result := loadWhy("src/invoice.js")
	results := result["results"].([]map[string]any)
	if len(results) != 1 {
		t.Fatalf("results length = %d, want 1: %#v", len(results), result)
	}
	if results[0]["id"] != "t-why1" {
		t.Fatalf("id = %v, want t-why1", results[0]["id"])
	}
	if results[0]["decision"] != "Keep renderer local" {
		t.Fatalf("decision = %v, want Keep renderer local", results[0]["decision"])
	}
}

func TestCreateTicketDefaultsAndIDShape(t *testing.T) {
	setupTestProject(t)
	created := createTicket("", "", "", 2, "")
	id := created["id"].(string)
	if !regexp.MustCompile(`^t-[a-z0-9]{4}$`).MatchString(id) {
		t.Fatalf("id = %q, want t-[a-z0-9]{4}", id)
	}
	if created["title"] != "Untitled" {
		t.Fatalf("title = %v, want Untitled", created["title"])
	}
	if created["type"] != "task" {
		t.Fatalf("type = %v, want task", created["type"])
	}
	if created["status"] != "open" {
		t.Fatalf("status = %v, want open", created["status"])
	}
	if created["priority"] != 2 {
		t.Fatalf("priority = %v, want 2", created["priority"])
	}
}

func TestResolveAppHTMLFallsBackToProjectRoot(t *testing.T) {
	root := t.TempDir()
	toolsDir := filepath.Join(t.TempDir(), "go-build-cache")
	appPath := filepath.Join(root, "tools", "sprint-check-app", "app.html")
	writeFile(t, appPath, "<!doctype html>\n")

	got := resolveAppHTML(toolsDir, root)
	if got != appPath {
		t.Fatalf("resolveAppHTML = %q, want %q", got, appPath)
	}
}

func TestResolveAppHTMLPrefersExecutableToolsDir(t *testing.T) {
	root := t.TempDir()
	toolsDir := filepath.Join(t.TempDir(), "tools")
	exeApp := filepath.Join(toolsDir, "sprint-check-app", "app.html")
	rootApp := filepath.Join(root, "tools", "sprint-check-app", "app.html")
	writeFile(t, exeApp, "exe app\n")
	writeFile(t, rootApp, "root app\n")

	got := resolveAppHTML(toolsDir, root)
	if got != exeApp {
		t.Fatalf("resolveAppHTML = %q, want %q", got, exeApp)
	}
}

func TestResolveAppHTMLFallsBackToSourceWorkingDir(t *testing.T) {
	projectRoot := t.TempDir()
	sourceRoot := t.TempDir()
	toolsDir := filepath.Join(t.TempDir(), "go-build-cache")
	appPath := filepath.Join(sourceRoot, "tools", "sprint-check-app", "app.html")
	writeFile(t, appPath, "<!doctype html>\n")

	got := resolveAppHTML(toolsDir, projectRoot, sourceRoot)
	if got != appPath {
		t.Fatalf("resolveAppHTML = %q, want %q", got, appPath)
	}
}
