package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
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

	tickets := loadTickets("")
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

	content, ok := readDoc("t-abcd-acceptance.md", "")
	if !ok || content != "legacy mapped acceptance\n" {
		t.Fatalf("readDoc legacy fallback = (%q, %v)", content, ok)
	}
	if !writeDoc("t-abcd-plan.md", "legacy mapped plan", "") {
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

	result := loadWhy("src/invoice.js", "")
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
	created := createTicket("", "", "", 2, "", false, "full", false, "", "", "")
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

func TestCreateTicketGate(t *testing.T) {
	setupTestProject(t)
	// eval mode writes the gate line and surfaces it in the ticket JSON
	ev := createTicket("eval gate", "task", "open", 2, "", true, "eval", false, "", "", "")
	if ev["gate"] != "eval" {
		t.Fatalf("gate JSON = %v, want eval", ev["gate"])
	}
	raw, _ := os.ReadFile(filepath.Join(ticketsDir, ev["id"].(string), "ticket.md"))
	if !strings.Contains(string(raw), "gate: eval") {
		t.Fatalf("ticket.md missing 'gate: eval':\n%s", raw)
	}
	// full mode (default) writes no gate line
	full := createTicket("full gate", "task", "open", 2, "", true, "full", false, "", "", "")
	raw2, _ := os.ReadFile(filepath.Join(ticketsDir, full["id"].(string), "ticket.md"))
	if strings.Contains(string(raw2), "gate:") {
		t.Fatalf("full-mode ticket.md should have no gate line:\n%s", raw2)
	}
}

// t-e53c: eval_override is human-only (hand-edit), so a created ticket is always seeded false, like `tkt create`.
func TestCreateTicketSeedsEvalOverrideFalse(t *testing.T) {
	setupTestProject(t)
	c := createTicket("override", "task", "open", 2, "", false, "full", false, "", "", "")
	raw, _ := os.ReadFile(filepath.Join(ticketsDir, c["id"].(string), "ticket.md"))
	if !strings.Contains(string(raw), "\neval_override: false\n") || strings.Contains(string(raw), "eval_override: true") {
		t.Fatalf("ticket.md must carry exactly eval_override: false:\n%s", raw)
	}
}

// t-354b: createTicket writes an allowlisted, order-preserving, deduped skills line.
func TestCreateTicketSkills(t *testing.T) {
	setupTestProject(t)
	c := createTicket("maint", "chore", "open", 2, "", false, "full", false, "context-check,dead-code-cleanup,bogus,context-check", "", "")
	raw, _ := os.ReadFile(filepath.Join(ticketsDir, c["id"].(string), "ticket.md"))
	if !strings.Contains(string(raw), "skills: context-check,dead-code-cleanup") {
		t.Fatalf("ticket.md missing expected skills line:\n%s", raw)
	}
	if strings.Contains(string(raw), "bogus") {
		t.Fatalf("non-allowlisted skill leaked into frontmatter:\n%s", raw)
	}
	none := createTicket("plain", "task", "open", 2, "", false, "full", false, "", "", "")
	raw2, _ := os.ReadFile(filepath.Join(ticketsDir, none["id"].(string), "ticket.md"))
	if strings.Contains(string(raw2), "skills:") {
		t.Fatalf("no-skills ticket should have no skills line:\n%s", raw2)
	}
}

// t-644a: createTicket writes an optional worktree_preference line, present/
// absent convention (parity with server.py's create_ticket).
func TestCreateTicketWorktreePreference(t *testing.T) {
	setupTestProject(t)
	withPref := createTicket("wt pref", "task", "open", 2, "", false, "full", false, "", "sprint/feat-x", "")
	raw, _ := os.ReadFile(filepath.Join(ticketsDir, withPref["id"].(string), "ticket.md"))
	if !strings.Contains(string(raw), "worktree_preference: sprint/feat-x") {
		t.Fatalf("ticket.md missing expected worktree_preference line:\n%s", raw)
	}
	none := createTicket("no wt pref", "task", "open", 2, "", false, "full", false, "", "", "")
	raw2, _ := os.ReadFile(filepath.Join(ticketsDir, none["id"].(string), "ticket.md"))
	if strings.Contains(string(raw2), "worktree_preference:") {
		t.Fatalf("no-preference ticket should have no worktree_preference line:\n%s", raw2)
	}
}

func TestWriteStatusUpdatesActive(t *testing.T) {
	setupTestProject(t)
	created := createTicket("Active test", "task", "open", 2, "", false, "full", false, "", "", "")
	id := created["id"].(string)

	if !writeStatus(id, "in_progress", "") {
		t.Fatal("writeStatus(in_progress) returned false")
	}
	activePath := filepath.Join(ticketsDir, "ACTIVE")
	raw, err := os.ReadFile(activePath)
	if err != nil {
		t.Fatalf("ACTIVE not written: %v", err)
	}
	if got := strings.TrimSpace(string(raw)); got != id {
		t.Fatalf("ACTIVE = %q, want %q", got, id)
	}

	if !writeStatus(id, "open", "") {
		t.Fatal("writeStatus(open) returned false")
	}
	if _, err := os.Stat(activePath); !os.IsNotExist(err) {
		t.Fatalf("expected ACTIVE to be cleared after status -> open, err = %v", err)
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

func TestSafeTicketDocRejectsSymlinkEscape(t *testing.T) {
	setupTestProject(t)
	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "secret.png")
	writeFile(t, outsideFile, "secret")

	ticketDir := filepath.Join(ticketsDir, "t-symv", "visuals")
	if err := os.MkdirAll(ticketDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outsideFile, filepath.Join(ticketDir, "evil.png")); err != nil {
		t.Fatal(err)
	}

	if _, ok := safeTicketDoc("t-symv/visuals/evil.png", ".png"); ok {
		t.Fatal("safeTicketDoc accepted a symlink escaping ticketsDir")
	}
}

func TestSafeTicketDocAcceptsLegitimateNestedPath(t *testing.T) {
	setupTestProject(t)
	realFile := filepath.Join(ticketsDir, "t-legt", "visuals", "real.png")
	writeFile(t, realFile, "\x89PNG\r\n\x1a\n")

	p, ok := safeTicketDoc("t-legt/visuals/real.png", ".png")
	if !ok {
		t.Fatal("safeTicketDoc rejected a legitimate nested real file")
	}
	if p != realFile {
		t.Fatalf("safeTicketDoc = %q, want %q", p, realFile)
	}
}

// t-f89a: the /api/ticket-feature route reuses safeTicketDoc with the .feature
// extension — same trust boundary as visuals, just a different ext.
func TestSafeTicketDocFeatureExtScoping(t *testing.T) {
	setupTestProject(t)
	realFile := filepath.Join(ticketsDir, "t-feat", "features", "spec.feature")
	writeFile(t, realFile, "Scenario: x\n  Given a\n")
	if p, ok := safeTicketDoc("t-feat/features/spec.feature", ".feature"); !ok || p != realFile {
		t.Fatalf("safeTicketDoc rejected a legitimate nested .feature (ok=%v p=%q)", ok, p)
	}

	tm := filepath.Join(ticketsDir, "t-feat", "ticket.md")
	writeFile(t, tm, "---\nid: t-feat\n---\n")
	if _, ok := safeTicketDoc("t-feat/ticket.md", ".feature"); ok {
		t.Fatal("safeTicketDoc accepted a non-.feature path under the .feature extension")
	}

	outside := filepath.Join(t.TempDir(), "outside.feature")
	writeFile(t, outside, "Scenario: leak\n")
	if err := os.Symlink(outside, filepath.Join(ticketsDir, "t-feat", "features", "evil.feature")); err != nil {
		t.Fatal(err)
	}
	if _, ok := safeTicketDoc("t-feat/features/evil.feature", ".feature"); ok {
		t.Fatal("safeTicketDoc accepted a symlink .feature escaping ticketsDir")
	}
}

func TestSafeTicketDocAllowsFreshWriteWithNonexistentLeaf(t *testing.T) {
	setupTestProject(t)
	if err := os.MkdirAll(filepath.Join(ticketsDir, "t-newf"), 0755); err != nil {
		t.Fatal(err)
	}

	p, ok := safeTicketDoc("t-newf/plan.md")
	if !ok {
		t.Fatal("safeTicketDoc rejected a fresh write to a not-yet-created file")
	}
	if p != filepath.Join(ticketsDir, "t-newf", "plan.md") {
		t.Fatalf("safeTicketDoc = %q, unexpected path", p)
	}
}

// A single-level "check only the immediate parent" fix would miss this: the
// leaf AND its immediate parent both don't exist yet, but an EXISTING
// symlinked directory two levels up already escapes ticketsDir. The guard
// must walk up to the deepest existing ancestor, not just one level.
func TestSafeTicketDocRejectsSymlinkEscapeTwoLevelsUpWithNonexistentLeaf(t *testing.T) {
	setupTestProject(t)
	outsideDir := t.TempDir()

	if err := os.Symlink(outsideDir, filepath.Join(ticketsDir, "evil-symlink-dir")); err != nil {
		t.Fatal(err)
	}

	if _, ok := safeTicketDoc("evil-symlink-dir/newticket/newfile.md"); ok {
		t.Fatal("safeTicketDoc accepted a path through an existing symlinked ancestor two levels up, with a nonexistent leaf and parent")
	}
}

// A dangling symlink (the symlink itself exists, but its target does not)
// makes filepath.EvalSymlinks fail — a fix that treats resolution failure as
// "nothing to escape through" would incorrectly allow this, even though
// os.WriteFile on such a path creates the target on write, landing outside
// ticketsDir the moment something is actually written.
func TestSafeTicketDocRejectsDanglingSymlinkAtLeaf(t *testing.T) {
	setupTestProject(t)
	outsideDir := t.TempDir()

	if err := os.MkdirAll(filepath.Join(ticketsDir, "t-dang"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outsideDir, "not-created-yet.md"), filepath.Join(ticketsDir, "t-dang", "evil.md")); err != nil {
		t.Fatal(err)
	}

	if _, ok := safeTicketDoc("t-dang/evil.md"); ok {
		t.Fatal("safeTicketDoc accepted a dangling symlink whose target lies outside ticketsDir")
	}
}

func TestSafeTicketDocAllowsFreshWriteThroughRealExistingParent(t *testing.T) {
	setupTestProject(t)
	if err := os.MkdirAll(filepath.Join(ticketsDir, "t-deep", "sub"), 0755); err != nil {
		t.Fatal(err)
	}

	p, ok := safeTicketDoc("t-deep/sub/brandnew.md")
	if !ok {
		t.Fatal("safeTicketDoc rejected a fresh write through a real, existing, non-symlinked parent chain")
	}
	if p != filepath.Join(ticketsDir, "t-deep", "sub", "brandnew.md") {
		t.Fatalf("safeTicketDoc = %q, unexpected path", p)
	}
}

// t-e40a: the shipped, git-tracked tools/cockpit-daemon-win.exe must be the
// first Windows candidate (the board couldn't find the daemon on a stock
// Windows clone because the resolver only looked for cockpit-daemon/cockpit-daemon.exe).
func TestCockpitDaemonCandidates(t *testing.T) {
	td := filepath.FromSlash("/x/tools")
	root := filepath.FromSlash("/proj")

	win := cockpitDaemonCandidates(td, root, "windows")
	if len(win) == 0 || win[0] != filepath.Join(td, "cockpit-daemon-win.exe") {
		t.Fatalf("windows first candidate = %v, want %s", win, filepath.Join(td, "cockpit-daemon-win.exe"))
	}
	// dev build must still appear as a fallback
	dev := filepath.Join(td, "cockpit-daemon", "cockpit-daemon.exe")
	foundDev := false
	for _, c := range win {
		if c == dev {
			foundDev = true
		}
	}
	if !foundDev {
		t.Fatalf("windows candidates missing dev fallback %s: %v", dev, win)
	}

	for _, goos := range []string{"darwin", "linux"} {
		u := cockpitDaemonCandidates(td, root, goos)
		want := filepath.Join(td, "cockpit-daemon", "cockpit-daemon")
		if len(u) == 0 || u[0] != want {
			t.Fatalf("%s first candidate = %v, want %s", goos, u, want)
		}
		for _, c := range u {
			if filepath.Base(c) == "cockpit-daemon-win.exe" {
				t.Fatalf("%s must not offer a -win.exe candidate: %v", goos, u)
			}
		}
	}

	// extraRoots contribute their own tools/ dirs on every platform.
	er := filepath.FromSlash("/wt")
	got := cockpitDaemonCandidates(td, root, "windows", er)
	wantExtra := filepath.Join(er, "tools", "cockpit-daemon-win.exe")
	foundExtra := false
	for _, c := range got {
		if c == wantExtra {
			foundExtra = true
		}
	}
	if !foundExtra {
		t.Fatalf("extraRoot tools dir missing from candidates: %v", got)
	}
}

// t-1776: upkeep-run is a bash script with no Windows-native entry point --
// exec.Command on an explicit path doesn't consult PATHEXT the way it would
// for a bare command name, so the bash script must never be Windows' first
// candidate; the .cmd wrapper (mirroring sprint.cmd) must come first there,
// and never appear at all on non-Windows.
func TestUpkeepRunBinCandidates(t *testing.T) {
	td := filepath.FromSlash("/x/tools")
	root := filepath.FromSlash("/proj")

	win := upkeepRunBinCandidates(td, root, "windows")
	wantWinFirst := filepath.Join(td, "upkeep-run.cmd")
	if len(win) == 0 || win[0] != wantWinFirst {
		t.Fatalf("windows first candidate = %v, want %s", win, wantWinFirst)
	}
	bashFallback := filepath.Join(td, "upkeep-run")
	foundBash := false
	for _, c := range win {
		if c == bashFallback {
			foundBash = true
		}
	}
	if !foundBash {
		t.Fatalf("windows candidates missing bash fallback %s: %v", bashFallback, win)
	}

	for _, goos := range []string{"darwin", "linux"} {
		u := upkeepRunBinCandidates(td, root, goos)
		want := filepath.Join(td, "upkeep-run")
		if len(u) == 0 || u[0] != want {
			t.Fatalf("%s first candidate = %v, want %s", goos, u, want)
		}
		for _, c := range u {
			if filepath.Base(c) == "upkeep-run.cmd" {
				t.Fatalf("%s must not offer a .cmd candidate: %v", goos, u)
			}
		}
	}

	// extraRoots contribute their own tools/ dirs on every platform.
	er := filepath.FromSlash("/wt")
	got := upkeepRunBinCandidates(td, root, "windows", er)
	wantExtra := filepath.Join(er, "tools", "upkeep-run.cmd")
	foundExtra := false
	for _, c := range got {
		if c == wantExtra {
			foundExtra = true
		}
	}
	if !foundExtra {
		t.Fatalf("extraRoot tools dir missing from candidates: %v", got)
	}
}

// t-99fa: /api/version returns {version, daemon}; version reflects the build
// var (stamped via -ldflags), daemon is "" when no daemon binary is resolved.
func TestVersionEndpoint(t *testing.T) {
	setupTestProject(t)
	oldVer, oldBin := version, cockpitDaemonBin
	version = "testver123"
	cockpitDaemonBin = "" // daemonVersion() → "" without a resolvable daemon bin
	defer func() { version = oldVer; cockpitDaemonBin = oldBin }()

	req := httptest.NewRequest("GET", "http://127.0.0.1/api/version", nil)
	rec := httptest.NewRecorder()
	handle(rec, req)
	if rec.Code != 200 {
		t.Fatalf("/api/version status = %d", rec.Code)
	}
	var v map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatal(err)
	}
	if v["version"] != "testver123" {
		t.Fatalf("version = %q, want testver123", v["version"])
	}
	if _, ok := v["daemon"]; !ok {
		t.Fatal("/api/version missing daemon key")
	}
	if v["daemon"] != "" {
		t.Fatalf("daemon = %q, want empty when no daemon bin", v["daemon"])
	}
}

// t-99fa: daemonVersion returns "" (not a crash) when the daemon binary path is
// empty or unresolvable.
func TestDaemonVersionEmpty(t *testing.T) {
	old := cockpitDaemonBin
	defer func() { cockpitDaemonBin = old }()
	cockpitDaemonBin = ""
	if got := daemonVersion(); got != "" {
		t.Fatalf("daemonVersion() = %q, want empty", got)
	}
	cockpitDaemonBin = filepath.Join(t.TempDir(), "does-not-exist")
	if got := daemonVersion(); got != "" {
		t.Fatalf("daemonVersion() with missing bin = %q, want empty", got)
	}
}

// t-9e55: committed canon mirror detection + replacement in a worktree.
func gitInitRepo(t *testing.T, dir string) {
	t.Helper()
	for _, args := range [][]string{
		{"-C", dir, "init", "-q"},
		{"-C", dir, "config", "user.email", "t@t"},
		{"-C", dir, "config", "user.name", "t"},
	} {
		if err := exec.Command("git", args...).Run(); err != nil {
			t.Skipf("git unavailable: %v", err)
		}
	}
}

func gitCommitAll(t *testing.T, dir, msg string) {
	t.Helper()
	if err := exec.Command("git", "-C", dir, "add", "-A").Run(); err != nil {
		t.Skipf("git unavailable: %v", err)
	}
	if err := exec.Command("git", "-C", dir, "commit", "-qm", msg).Run(); err != nil {
		t.Fatalf("git commit: %v", err)
	}
}

func TestIsCommittedCanonMirror(t *testing.T) {
	// tracked + sprint/SKILL.md marker → true
	wt := t.TempDir()
	gitInitRepo(t, wt)
	writeFile(t, filepath.Join(wt, ".agents/skills/sprint/SKILL.md"), "STALE")
	gitCommitAll(t, wt, "mirror")
	if !isCommittedCanonMirror(wt, ".agents/skills", filepath.Join(wt, ".agents/skills")) {
		t.Fatal("tracked mirror carrying sprint/SKILL.md must be detected as a committed canon mirror")
	}

	// tracked, no marker → false (genuine project-local skills)
	wt2 := t.TempDir()
	gitInitRepo(t, wt2)
	writeFile(t, filepath.Join(wt2, ".agents/skills/myproj/x.md"), "LOCAL")
	gitCommitAll(t, wt2, "local")
	if isCommittedCanonMirror(wt2, ".agents/skills", filepath.Join(wt2, ".agents/skills")) {
		t.Fatal("tracked dir lacking the sprint/SKILL.md marker must not be treated as a canon mirror")
	}

	// untracked real dir → false
	wt3 := t.TempDir()
	gitInitRepo(t, wt3)
	writeFile(t, filepath.Join(wt3, ".agents/skills/sprint/SKILL.md"), "STALE")
	if isCommittedCanonMirror(wt3, ".agents/skills", filepath.Join(wt3, ".agents/skills")) {
		t.Fatal("an untracked skills dir must not be treated as a committed canon mirror")
	}
}

func TestLinkSkillsIntoWorktreeReplacesCommittedMirror(t *testing.T) {
	// Point toolsDir at a fake canon so target = <fake>/skills resolves.
	fake := t.TempDir()
	writeFile(t, filepath.Join(fake, "skills/sprint/SKILL.md"), "CURRENT-CANON")
	saved := toolsDir
	toolsDir = filepath.Join(fake, "tools")
	defer func() { toolsDir = saved }()

	wt := t.TempDir()
	gitInitRepo(t, wt)
	writeFile(t, filepath.Join(wt, ".agents/skills/sprint/SKILL.md"), "STALE") // committed mirror → replace
	writeFile(t, filepath.Join(wt, ".claude/skills/myproj/x.md"), "LOCAL")     // committed, no marker → preserve
	gitCommitAll(t, wt, "mixed")

	linkSkillsIntoWorktree(wt)

	// .agents/skills replaced with a symlink resolving to current (fake) canon
	agents := filepath.Join(wt, ".agents/skills")
	if fi, err := os.Lstat(agents); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf(".agents/skills should be a symlink after replace (err=%v)", err)
	}
	b, err := os.ReadFile(filepath.Join(agents, "sprint", "SKILL.md"))
	if err != nil || strings.TrimSpace(string(b)) != "CURRENT-CANON" {
		t.Fatalf(".agents/skills should resolve to current canon, got %q (err=%v)", string(b), err)
	}
	if out, _ := gitInDirOutput(wt, "ls-files", "--", ".agents/skills"); strings.TrimSpace(out) != "" {
		t.Fatalf("replaced mirror should be untracked, ls-files: %q", out)
	}

	// .claude/skills (no marker) preserved as a real dir with its content
	claude := filepath.Join(wt, ".claude/skills")
	if fi, err := os.Lstat(claude); err != nil || fi.Mode()&os.ModeSymlink != 0 {
		t.Fatalf(".claude/skills (project-local, no marker) should be preserved as a real dir (err=%v)", err)
	}
	if b2, _ := os.ReadFile(filepath.Join(claude, "myproj", "x.md")); strings.TrimSpace(string(b2)) != "LOCAL" {
		t.Fatalf(".claude/skills project-local content lost, got %q", string(b2))
	}
}

// ── Canon Cockpit registry (t-9917) ───────────────────────────────────────

func TestRegistryIDStable(t *testing.T) {
	a := registryID("/Users/x/proj")
	b := registryID("/Users/x/proj")
	if a != b {
		t.Fatalf("id not stable: %s != %s", a, b)
	}
	if len(a) != 12 {
		t.Fatalf("id length = %d, want 12", len(a))
	}
	if registryID("/Users/x/proj") == registryID("/Users/x/other") {
		t.Fatal("different paths produced the same id")
	}
	if !regexp.MustCompile(`^[0-9a-f]{12}$`).MatchString(a) {
		t.Fatalf("id not 12 lowercase hex: %s", a)
	}
}

func TestRegistryAddListRemove(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", filepath.Join(home, ".canon"))

	// a valid git dir
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".git"), 0755); err != nil {
		t.Fatal(err)
	}

	if got := registryLoad(); len(got) != 0 {
		t.Fatalf("expected empty registry, got %d", len(got))
	}

	res := registryAdd(proj, "a demo project")
	if ok, _ := res["ok"].(bool); !ok {
		t.Fatalf("add failed: %v", res)
	}
	entries := registryLoad()
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	// filepath.EvalSymlinks resolves the temp dir; name is its basename.
	if entries[0].Description != "a demo project" {
		t.Fatalf("description mismatch: %q", entries[0].Description)
	}

	// re-add same path → duplicate error, still 1 entry
	if res := registryAdd(proj, "again"); res["ok"].(bool) {
		t.Fatal("re-add should fail as duplicate")
	}
	if len(registryLoad()) != 1 {
		t.Fatal("duplicate add changed the registry")
	}

	// t-07c8: non-git dir now registers with a non-blocking warning (git relaxed)
	nongit := t.TempDir()
	ngres := registryAdd(nongit, "x")
	if !ngres["ok"].(bool) {
		t.Fatalf("non-git dir should now register (ok:true), got %v", ngres)
	}
	if w, _ := ngres["warning"].(string); !strings.Contains(strings.ToLower(w), "git") {
		t.Fatalf("non-git dir should register with a git warning, got %v", ngres)
	}
	registryRemove(ngres["project"].(registryProject).ID) // keep the rest of the test single-entry
	// missing path → error
	if res := registryAdd(filepath.Join(home, "nope"), "x"); res["ok"].(bool) {
		t.Fatal("missing path should be rejected")
	}
	// empty path → error
	if res := registryAdd("", "x"); res["ok"].(bool) {
		t.Fatal("empty path should be rejected")
	}

	// remove by id
	id := entries[0].ID
	if res := registryRemove(id); !res["removed"].(bool) {
		t.Fatal("remove should report removed=true")
	}
	if len(registryLoad()) != 0 {
		t.Fatal("registry not empty after remove")
	}
	// remove unknown → no-op success
	if res := registryRemove("deadbeef0000"); res["removed"].(bool) {
		t.Fatal("removing unknown id should report removed=false")
	}
}

// TestRegistryJSONShapeMatchesPython pins the on-disk JSON so it stays
// byte-identical to server.py's json.dumps(indent=2)+"\n" (parity contract).
func TestRegistryJSONShapeMatchesPython(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", filepath.Join(home, ".canon"))
	proj := t.TempDir()
	os.MkdirAll(filepath.Join(proj, ".git"), 0755)
	registryAdd(proj, "desc")
	raw, err := os.ReadFile(registryFile())
	if err != nil {
		t.Fatal(err)
	}
	s := string(raw)
	// 2-space indent, field order id,path,name,description,added, trailing \n
	if !strings.HasSuffix(s, "\n") {
		t.Fatal("registry file must end with a newline (parity with Python)")
	}
	idIdx := strings.Index(s, `"id"`)
	pathIdx := strings.Index(s, `"path"`)
	nameIdx := strings.Index(s, `"name"`)
	descIdx := strings.Index(s, `"description"`)
	addedIdx := strings.Index(s, `"added"`)
	if !(idIdx < pathIdx && pathIdx < nameIdx && nameIdx < descIdx && descIdx < addedIdx) {
		t.Fatalf("field order must be id,path,name,description,added — got:\n%s", s)
	}
	if !strings.Contains(s, "\n    \"id\"") { // array→object nesting = 4-space indent on fields
		t.Fatalf("expected 2-space incremental indent (4-space field indent in an array), got:\n%s", s)
	}
}

// TestEffectiveRootAndProjectStats (t-a55a): ?project resolves a registered
// id to its path, unknown → ok=false (→400), absent → projectRoot; projectStats
// reports the per-project ticket count + a non-empty relative "updated".
func TestEffectiveRootAndProjectStats(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", filepath.Join(home, ".canon"))
	gitRun := func(dir string, args ...string) {
		c := exec.Command("git", args...)
		c.Dir = dir
		_ = c.Run()
	}
	mk := func(desc string, tickets int) string {
		p := t.TempDir()
		gitRun(p, "init")
		gitRun(p, "config", "user.email", "t@t")
		gitRun(p, "config", "user.name", "t")
		os.WriteFile(filepath.Join(p, "f"), []byte("x"), 0644)
		gitRun(p, "add", "-A")
		gitRun(p, "commit", "-m", "init")
		for i := 0; i < tickets; i++ {
			d := filepath.Join(p, ".tickets", "t-"+strings.Repeat("a", 3)+strconvItoa(i))
			os.MkdirAll(d, 0755)
			os.WriteFile(filepath.Join(d, "ticket.md"), []byte("# t"), 0644)
		}
		registryAdd(p, desc)
		return p
	}
	pA := mk("projA", 3)
	_ = mk("projB", 1)

	var idA string
	for _, e := range registryLoad() {
		if filepath.Base(e.Path) == filepath.Base(pA) {
			idA = e.ID
		}
	}
	if idA == "" {
		t.Fatal("could not find registered projA id")
	}

	if got, ok := effectiveRoot(httptest.NewRequest("GET", "/api/tickets?project="+idA, nil)); !ok || filepath.Base(got) != filepath.Base(pA) {
		t.Fatalf("effectiveRoot(idA) = %q,%v; want projA", got, ok)
	}
	if _, ok := effectiveRoot(httptest.NewRequest("GET", "/api/tickets?project=deadbeef0000", nil)); ok {
		t.Fatal("effectiveRoot(unknown) should be ok=false → 400")
	}
	projectRoot = home
	if got, ok := effectiveRoot(httptest.NewRequest("GET", "/api/tickets", nil)); !ok || got != home {
		t.Fatalf("effectiveRoot(absent) = %q,%v; want projectRoot", got, ok)
	}

	stats := projectStats(pA)
	if stats["ticket_count"].(int) != 3 {
		t.Fatalf("projectStats.ticket_count = %v; want 3", stats["ticket_count"])
	}
	if u, _ := stats["updated"].(string); u == "" {
		t.Fatal("projectStats.updated should be non-empty for a repo with a commit")
	}
}

func strconvItoa(i int) string { return strconv.Itoa(i) }

// TestRegistryDoesNotHTMLEscape pins that & < > are written literally (not
// \u0026 etc.) so the on-disk JSON stays byte-identical to Python's
// json.dumps(ensure_ascii=False) (t-9917 review finding: Go's default
// MarshalIndent HTML-escapes and would diverge).
func TestRegistryDoesNotHTMLEscape(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", filepath.Join(home, ".canon"))
	proj := t.TempDir()
	os.MkdirAll(filepath.Join(proj, ".git"), 0755)
	registryAdd(proj, "a & b < c > d")
	raw, _ := os.ReadFile(registryFile())
	s := string(raw)
	if !strings.Contains(s, "a & b < c > d") {
		t.Fatalf("description must be stored with literal & < >, got:\n%s", s)
	}
	for _, bad := range []string{`\u0026`, `\u003c`, `\u003e`} {
		if strings.Contains(s, bad) {
			t.Fatalf("registry JSON must NOT HTML-escape (found %s) — breaks Python parity:\n%s", bad, s)
		}
	}
}

// TestScopedWritesTargetProject (t-8485): create/status/doc with a registered
// ?project root land in THAT project's .tickets, not the process default.
func TestScopedWritesTargetProject(t *testing.T) {
	setupTestProject(t) // sets ticketsDir = default project
	home := t.TempDir()
	t.Setenv("CANON_HOME", filepath.Join(home, ".canon"))
	B := t.TempDir()
	os.MkdirAll(filepath.Join(B, ".git"), 0755)
	os.MkdirAll(filepath.Join(B, ".tickets"), 0755)
	broot, _ := filepath.EvalSymlinks(B)

	tk := createTicket("Scoped", "task", "open", 2, "body", false, "full", false, "", "", broot)
	id := fmt.Sprint(tk["id"])
	if _, err := os.Stat(filepath.Join(broot, ".tickets", id, "ticket.md")); err != nil {
		t.Fatalf("scoped create did not land in project B: %v", err)
	}
	if _, err := os.Stat(filepath.Join(ticketsDir, id)); err == nil {
		t.Fatal("scoped create leaked into the default project")
	}
	if !writeStatus(id, "in_progress", broot) {
		t.Fatal("scoped writeStatus returned false")
	}
	active, _ := os.ReadFile(filepath.Join(broot, ".tickets", "ACTIVE"))
	if strings.TrimSpace(string(active)) != id {
		t.Fatalf("scoped status did not write project B's ACTIVE (got %q)", strings.TrimSpace(string(active)))
	}
	if !writeDoc(id+"/plan.md", "# Plan\nx", broot) {
		t.Fatal("scoped writeDoc returned false")
	}
	if _, err := os.Stat(filepath.Join(broot, ".tickets", id, "plan.md")); err != nil {
		t.Fatalf("scoped writeDoc did not land in project B: %v", err)
	}
	if _, ok := effectiveRoot(httptest.NewRequest("GET", "/api/tickets?project=deadbeef0000", nil)); ok {
		t.Fatal("unknown project id should be ok=false (→400)")
	}
}

// TestRegisteredSkills (t-7485): parse the AGENTS.md AI-SKILLS table; byte-parity
// with server.py registered_skills (names in table order; [] when absent).
func TestRegisteredSkills(t *testing.T) {
	dir := t.TempDir()
	// no AGENTS.md → empty (non-nil) slice
	if got := registeredSkills(dir); len(got) != 0 {
		t.Fatalf("no AGENTS.md should yield no skills, got %v", got)
	}
	agents := "# X\n<!-- AI-SKILLS:BEGIN -->\n## Active canon skills\n\n" +
		"| Skill | Category | Source |\n|-------|----------|--------|\n" +
		"| sprint | dev | /x/skills/sprint/SKILL.md |\n" +
		"| context-check | dev | /x/skills/context-check/SKILL.md |\n" +
		"<!-- AI-SKILLS:END -->\n"
	if err := os.WriteFile(filepath.Join(dir, "AGENTS.md"), []byte(agents), 0644); err != nil {
		t.Fatal(err)
	}
	got := registeredSkills(dir)
	if len(got) != 2 || got[0] != "sprint" || got[1] != "context-check" {
		t.Fatalf("want [sprint context-check] in table order, got %v", got)
	}
	// registerSkill accepts only the fixed allowlist {sprint, efficiency} (t-96c3)
	if res := registerSkill(dir, "wrapup"); res["ok"] != false {
		t.Fatalf("skill outside the allowlist must be rejected, got %v", res)
	}
	if res := registerSkill(dir, "../evil"); res["ok"] != false {
		t.Fatalf("path-shaped skill must be rejected, got %v", res)
	}
}

// TestBrowseDirs (t-1b88): dirs-only listing (files excluded), home default,
// clean error on a file/nonexistent path — parity with server.py browse_dirs.
func TestBrowseDirs(t *testing.T) {
	d := t.TempDir()
	os.Mkdir(filepath.Join(d, "sub1"), 0755)
	os.Mkdir(filepath.Join(d, "sub2"), 0755)
	os.WriteFile(filepath.Join(d, "afile.txt"), []byte("x"), 0644)
	r := browseDirs(d, false)
	if r["error"] != nil {
		t.Fatalf("unexpected error: %v", r)
	}
	ents := r["entries"].([]map[string]any)
	names := []string{}
	for _, e := range ents {
		names = append(names, e["name"].(string))
	}
	if len(names) != 2 || names[0] != "sub1" || names[1] != "sub2" {
		t.Fatalf("want [sub1 sub2] dirs-only, got %v", names)
	}
	for _, n := range names {
		if n == "afile.txt" {
			t.Fatal("browseDirs must not list files")
		}
	}
	if r["parent"] == nil {
		t.Fatal("parent should be set for a non-root dir")
	}
	// home default
	if browseDirs("", false)["error"] != nil {
		t.Fatal("empty path should default to home, not error")
	}
	// a file path and a nonexistent path → clean error
	if browseDirs(filepath.Join(d, "afile.txt"), false)["error"] == nil {
		t.Fatal("a file path should return an error")
	}
	if browseDirs("/no/such/dir/xyz123", false)["error"] == nil {
		t.Fatal("a nonexistent path should return an error")
	}
}

// TestBrowseDirsHidden (t-340d): dotfolders hidden by default, shown with showHidden.
func TestBrowseDirsHidden(t *testing.T) {
	d := t.TempDir()
	os.Mkdir(filepath.Join(d, "visible"), 0755)
	os.Mkdir(filepath.Join(d, ".hiddendir"), 0755)
	names := func(res map[string]any) []string {
		out := []string{}
		for _, e := range res["entries"].([]map[string]any) {
			out = append(out, e["name"].(string))
		}
		return out
	}
	def := names(browseDirs(d, false))
	if len(def) != 1 || def[0] != "visible" {
		t.Fatalf("default should hide dotfolders, got %v", def)
	}
	all := names(browseDirs(d, true))
	if len(all) != 2 {
		t.Fatalf("showHidden should include .hiddendir, got %v", all)
	}
}

// writeStubScript (t-7ae6) writes an executable script at dir/name that prints
// stdout, exits with the given code. Mirrors this file's existing pattern for
// stubbing external binaries via an env-var override — never overwrite the
// real on-disk script in place (t-1781).
func writeStubScript(t *testing.T, dir, name, stdout string, exitCode int) string {
	t.Helper()
	p := filepath.Join(dir, name)
	body := fmt.Sprintf("#!/bin/sh\nprintf '%%s' '%s'\nexit %d\n", stdout, exitCode)
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestResolveUpkeepRunBin(t *testing.T) {
	t.Setenv("UPKEEP_RUN_BIN", "/custom/upkeep-run")
	if got := resolveUpkeepRunBin("/tools", "/root"); got != "/custom/upkeep-run" {
		t.Fatalf("env override not honored: got %q", got)
	}
	t.Setenv("UPKEEP_RUN_BIN", "")
	toolsDirD := t.TempDir()
	p := filepath.Join(toolsDirD, "upkeep-run")
	os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755)
	if got := resolveUpkeepRunBin(toolsDirD, "/nonexistent-root"); got != p {
		t.Fatalf("expected toolsDir candidate %q, got %q", p, got)
	}
}

// t-1776: a failed run's output must be persisted AND surfaced via
// getUpkeepRunState — the whole point of persisting it is that a caller can
// see WHY a run failed, not just someone opening upkeepRuns.json by hand
// (reviewer finding). Also confirms the 2048-byte tail cap actually bounds a
// long output, not just that a short one round-trips.
func TestRunUpkeepPersistsAndSurfacesBoundedOutput(t *testing.T) {
	root := setupTestProject(t)
	longMsg := strings.Repeat("X", 5000)
	stub := writeStubScript(t, t.TempDir(), "stub-upkeep-run", longMsg, 1)
	oldBin := upkeepRunBin
	upkeepRunBin = stub
	defer func() { upkeepRunBin = oldBin }()

	// runUpkeep assumes startUpkeepRun already seeded this map entry (it
	// normally runs as a goroutine startUpkeepRun launches) — seed it the
	// same way here so this synchronous, direct call doesn't panic on a nil
	// map write.
	key := upkeepKey{root, "context-check"}
	upkeepRunsMu.Lock()
	upkeepRuns[key] = map[string]any{"status": "running", "output": "", "exit_code": nil, "started_at": time.Now()}
	upkeepRunsMu.Unlock()

	runUpkeep(root, "context-check", "claude-haiku-4-5-20251001")

	state := getUpkeepRunState(root, "context-check")
	out, _ := state["output"].(string)
	if len(out) != 2048 {
		t.Fatalf("getUpkeepRunState output not bounded to 2048 bytes: got %d", len(out))
	}

	persisted := upkeepStateLoad(root)["context-check"]
	pout, _ := persisted["output"].(string)
	if len(pout) != 2048 {
		t.Fatalf("persisted output not bounded to 2048 bytes: got %d", len(pout))
	}
}

func TestGetUpkeepRunStateIdle(t *testing.T) {
	root := t.TempDir()
	upkeepRuns = map[upkeepKey]map[string]any{}
	state := getUpkeepRunState(root, "context-check")
	if state["status"] != "idle" {
		t.Fatalf("expected idle for a never-run skill, got %v", state)
	}
}

// TestStartUpkeepRunDoubleSpawnGuard: a second start while one is "running"
// for the same (root, skill) must not spawn a second process — mirrors
// startHeadlessRun's own guard, same shape, different key.
func TestStartUpkeepRunDoubleSpawnGuard(t *testing.T) {
	root := t.TempDir()
	upkeepRuns = map[upkeepKey]map[string]any{}
	key := upkeepKey{root, "context-check"}
	upkeepRuns[key] = map[string]any{"status": "running", "started_at": time.Now()}
	result := startUpkeepRun(root, "context-check", "claude-haiku-4-5-20251001")
	if result["busy"] != true {
		t.Fatalf("expected busy:true when already running, got %v", result)
	}
}

func TestStartUpkeepRunUnknownSkill(t *testing.T) {
	root := t.TempDir()
	result := startUpkeepRun(root, "not-a-real-skill", "claude-haiku-4-5-20251001")
	if result["ok"] != false {
		t.Fatalf("expected ok:false for an unknown skill, got %v", result)
	}
}

// TestRunUpkeepEndToEnd runs the real dispatch machinery against a stub
// upkeep-run binary (never the real claude -p — this test asserts the Go
// wiring, not a live model call) that prints the UPKEEP_REPORT sentinel line,
// and confirms the resulting state + persisted .reports/upkeepRuns.json both
// reflect it.
func TestRunUpkeepEndToEnd(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, ".reports"), 0o755)
	reportPath := filepath.Join(root, ".reports", "context-check_test.md")
	os.WriteFile(reportPath, []byte("# Report\n"), 0o644)
	stubDir := t.TempDir()
	upkeepRunBin = writeStubScript(t, stubDir, "upkeep-run", "UPKEEP_REPORT: "+reportPath+"\n", 0)
	// runUpkeep assumes its map entry already exists — startUpkeepRun normally
	// initializes it before launching the goroutine that calls this.
	upkeepRuns = map[upkeepKey]map[string]any{
		{root, "context-check"}: {"status": "running", "started_at": time.Now()},
	}

	runUpkeep(root, "context-check", "claude-haiku-4-5-20251001")

	state := getUpkeepRunState(root, "context-check")
	if state["status"] != "done" {
		t.Fatalf("expected status done, got %v", state)
	}
	if state["report_path"] != reportPath {
		t.Fatalf("expected report_path %q, got %v", reportPath, state["report_path"])
	}
	persisted := upkeepStateLoad(root)
	if persisted["context-check"] == nil {
		t.Fatal("expected .reports/upkeepRuns.json to have a context-check entry")
	}

	report := getUpkeepReport(root, "context-check")
	if report["ok"] != true || report["content"] != "# Report\n" {
		t.Fatalf("expected report content to be served, got %v", report)
	}
}

// TestGetUpkeepReportRejectsPathOutsideReports: a report_path that doesn't
// live under this root's own .reports/ must be refused, even if it somehow
// ended up in state — the containment check must not just trust the state.
func TestGetUpkeepReportRejectsPathOutsideReports(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "not-in-reports.md")
	os.WriteFile(outside, []byte("secret"), 0o644)
	upkeepRuns = map[upkeepKey]map[string]any{
		{root, "context-check"}: {"status": "done", "report_path": outside},
	}
	report := getUpkeepReport(root, "context-check")
	if report["ok"] != false {
		t.Fatalf("expected the out-of-.reports/ path to be refused, got %v", report)
	}
}

// TestUpkeepModelIDCases (t-be1f): the model string reaches `claude --model`, so it must be a plain model id.
// The good/bad cases live in tests/fixtures/model-id-cases.json, shared with the bash and Python tests.
func TestUpkeepModelIDCases(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/model-id-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases struct {
		Good []string `json:"good"`
		Bad  []string `json:"bad"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	// Other tests share the package-level upkeepRuns map, so only look at this test's own root.
	hasUpkeepJob := func(r string) bool {
		upkeepRunsMu.Lock()
		defer upkeepRunsMu.Unlock()
		for k := range upkeepRuns {
			if k.root == r {
				return true
			}
		}
		return false
	}
	for _, m := range cases.Bad {
		if validUpkeepModel(m) {
			t.Errorf("validUpkeepModel accepted %q", m)
		}
		r := startUpkeepRun(root, "context-check", m)
		if r["ok"] != false || !strings.Contains(fmt.Sprint(r["error"]), "model") {
			t.Errorf("startUpkeepRun(%q) = %v, want a model refusal", m, r)
		}
	}
	for _, m := range cases.Good {
		if !validUpkeepModel(m) {
			t.Errorf("validUpkeepModel refused %q", m)
		}
	}
	if hasUpkeepJob(root) {
		t.Errorf("a refused model started a job for %s", root)
	}
	// Seeded fuzz: strings built from parts that can never be legitimate are always refused.
	rng := rand.New(rand.NewSource(20260922))
	// A dash is only hostile as the FIRST character (ok-tail is a valid id); the rest are never valid anywhere.
	badChars := []string{" ", ";", "$(", "`", "|", "&", "\n", "\r", "\t", "'", "\"", "\\", "/", "é", "*", "="}
	heads := []string{"", "ok", "xxxxx"}
	for i := 0; i < 300; i++ {
		var m string
		if rng.Intn(10) < 3 {
			m = []string{"-", "--"}[rng.Intn(2)] + []string{"", "tail", "x y"}[rng.Intn(3)]
		} else {
			m = heads[rng.Intn(len(heads))] + badChars[rng.Intn(len(badChars))] + []string{"", "tail"}[rng.Intn(2)]
		}
		if r := startUpkeepRun(root, "context-check", m); r["ok"] != false {
			t.Fatalf("fuzz: startUpkeepRun(%q) = %v", m, r)
		}
	}
	if hasUpkeepJob(root) {
		t.Errorf("the fuzz started a job for %s", root)
	}
}

// t-b9a7: concurrent run completions must not lose or corrupt each other's state entries.
func TestSkillEvalStateSaveIsSerialized(t *testing.T) {
	root := t.TempDir()
	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			skillEvalStateSave(root, fmt.Sprintf("/skills/s%d", i), map[string]any{"status": "done", "pad": strings.Repeat("x", 4000)})
		}(i)
	}
	wg.Wait()
	b, err := os.ReadFile(skillEvalStatePath(root))
	if err != nil {
		t.Fatal(err)
	}
	var state map[string]any
	if err := json.Unmarshal(b, &state); err != nil {
		t.Fatalf("state file corrupted: %v", err)
	}
	if len(state) != 64 {
		t.Fatalf("state has %d entries, want 64 (lost updates)", len(state))
	}
}

// t-b9a7: canon's own skills are refused even when the selected project contains canon, and an
// unverifiable canon root refuses everything (fail closed) instead of disabling that check.
func TestValidateSkillDirRefusesCanon(t *testing.T) {
	wd, _ := os.Getwd()
	canon := filepath.Dir(filepath.Dir(wd)) // tools/sprint-check-go → repo root
	saved := appHTML
	defer func() { appHTML = saved }()
	appHTML = filepath.Join(canon, "tools", "sprint-check-app", "app.html")
	if _, msg := validateSkillDir(filepath.Dir(canon), filepath.Join(canon, "skills", "capture")); msg != "canon's own skills are checked internally, not here" {
		t.Fatalf("canon skill: got %q", msg)
	}
	outside := t.TempDir()
	skill := filepath.Join(outside, "proj", "good")
	if err := os.MkdirAll(skill, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, msg := validateSkillDir(filepath.Join(outside, "proj"), skill); msg != "" {
		t.Fatalf("ordinary skill refused: %q", msg)
	}
	appHTML = filepath.Join(outside, "nowhere", "sprint-check-app", "app.html")
	if _, msg := validateSkillDir(filepath.Join(outside, "proj"), skill); msg != "canon's own skills are checked internally, not here" {
		t.Fatalf("unknown canon root must fail closed, got %q", msg)
	}
}

// t-b9a7: a junction (ModeIrregular, possibly with ModeDir) or a symlink is never a plain entry.
func TestPlainModeRefusesJunctionsAndLinks(t *testing.T) {
	cases := map[fs.FileMode]bool{
		0: true, fs.ModeDir: true, 0o644: true, fs.ModeDir | 0o755: true,
		fs.ModeSymlink: false, fs.ModeIrregular: false, fs.ModeDir | fs.ModeIrregular: false,
		fs.ModeDir | fs.ModeSymlink: false, fs.ModeNamedPipe: false, fs.ModeSocket: false, fs.ModeDevice: false,
	}
	for m, want := range cases {
		if got := plainMode(m); got != want {
			t.Errorf("plainMode(%v) = %v, want %v", m, got, want)
		}
	}
}

// t-d538: synced-folder detection is warn-only, but it must see Windows paths too.
func TestSyncedServiceDetectsSyncedFolders(t *testing.T) {
	cases := map[string]any{
		`/Users/a/Library/Mobile Documents/com~apple~CloudDocs/plans`: "iCloud Drive",
		`/Users/a/Library/CloudStorage/GoogleDrive-a@b.c/My Drive/x`:  "cloud storage",
		`C:\Users\a\Dropbox (Personal)\plans`:                         "Dropbox",
		`C:\Users\a\OneDrive - Acme\Designs`:                          "OneDrive",
		`G:\My Drive\roadmap`:                                         "Google Drive",
		`/Users/a/Google Drive/roadmap`:                               "Google Drive",
		`/Users/a/Developer/canon`:                                    nil,
		`C:\Users\a\projects\app`:                                     nil,
	}
	for path, want := range cases {
		if got := syncedService(path); got != want {
			t.Errorf("syncedService(%q) = %v, want %v", path, got, want)
		}
	}
}

// t-b9a7: any non-plain component between the project root and the skill refuses it (a symlink here
// stands in for a Windows junction, which EvalSymlinks no longer resolves since Go 1.23).
func TestPlainDirsBetweenRefusesLinkedComponent(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "real", "skill"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "real"), filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if !plainDirsBetween(root, filepath.Join(root, "real", "skill")) {
		t.Fatal("plain path refused")
	}
	if plainDirsBetween(root, filepath.Join(root, "link", "skill")) {
		t.Fatal("a linked intermediate component was accepted")
	}
}

// t-e555: a run is done iff claude exits 0 or 1 and wrote its result file (server.py's rule);
// any other exit, a missing result, or the timeout is an error. Exit 1 ("some cases did not
// pass") was misread as a failure because the context was checked after cancel().
func TestRunSkillEvalExitCodes(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the stub claude is a bash script")
	}
	wd, _ := os.Getwd()
	canon := filepath.Dir(filepath.Dir(wd))
	savedHTML, savedTimeout := appHTML, skillEvalRunTimeout
	defer func() { appHTML, skillEvalRunTimeout = savedHTML, savedTimeout }()
	appHTML = filepath.Join(canon, "tools", "sprint-check-app", "app.html")

	tmp := t.TempDir()
	root := filepath.Join(tmp, "proj")
	skill := filepath.Join(root, "skills", "good")
	if err := os.MkdirAll(filepath.Dir(skill), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := exec.Command("cp", "-R", filepath.Join(canon, "tests", "fixtures", "skill-check", "good"), skill).Run(); err != nil {
		t.Fatal(err)
	}
	skill, _ = filepath.EvalSymlinks(skill)
	t.Cleanup(func() { os.RemoveAll(filepath.Join(canon, ".canon-cache", "skill-eval", skillEvalTag(root, skill))) })

	stub := filepath.Join(tmp, "claude-stub")
	script := "#!/usr/bin/env bash\nout=\"\"; while [ $# -gt 0 ]; do [ \"$1\" = --json ] && out=\"$2\"; shift; done\n" +
		"sleep \"${STUB_SLEEP:-0}\"\n" +
		"[ -z \"${STUB_LINGER:-}\" ] || (sleep 5) &\n" +
		"[ -n \"${STUB_NO_RESULT:-}\" ] || echo '{\"aggregates\":{\"casesTotal\":2,\"casesPassed\":1}}' > \"$out\"\n" +
		"exit \"${STUB_EXIT:-0}\"\n"
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SKILL_EVAL_CLAUDE_BIN", stub)

	cases := []struct {
		name, exit, sleep, noResult, linger, want string
		timeout                                   time.Duration
	}{
		{"exit 0 with result", "0", "0", "", "", "done", time.Minute},
		{"exit 1 with result", "1", "0", "", "", "done", time.Minute},
		{"exit 2 with result", "2", "0", "", "", "error", time.Minute},
		{"exit 1 without result", "1", "0", "1", "", "error", time.Minute},
		{"past the timeout", "0", "5", "", "", "error", 300 * time.Millisecond},
		// a child still holds the output pipe after claude exits 0: Wait returns ErrWaitDelay (a
		// non-zero exit would win as ExitError instead) and the run keeps claude's own exit code
		{"exit 0 with a lingering child", "0", "0", "", "1", "done", time.Minute},
	}
	for _, c := range cases {
		t.Setenv("STUB_EXIT", c.exit)
		t.Setenv("STUB_SLEEP", c.sleep)
		t.Setenv("STUB_NO_RESULT", c.noResult)
		t.Setenv("STUB_LINGER", c.linger)
		skillEvalRunTimeout = c.timeout
		start := time.Now()
		runSkillEval(root, skill, "claude-haiku-4-5-20251001", 3.0)
		skillEvalMu.Lock()
		st := skillEvalRuns[skillEvalKey(root, skill)]
		skillEvalMu.Unlock()
		if st["status"] != c.want {
			t.Errorf("%s: status %v, want %s (output %q)", c.name, st["status"], c.want, st["output"])
		}
		if c.want == "done" {
			if sum, _ := st["summary"].(map[string]any); sum["casesPassed"] != float64(1) {
				t.Errorf("%s: summary %v, want casesPassed 1", c.name, st["summary"])
			}
		}
		if (c.name == "past the timeout" || c.linger != "") && time.Since(start) > 4*time.Second {
			t.Errorf("%s: the run was not killed at the timeout (took %v)", c.name, time.Since(start))
		}
	}
}

// t-824e: the daemon's two reaper timeouts reach Admin through /api/cockpit's running_build; a
// daemon predating them reports 0 (Admin then hides the reaper line). Mirrors server.py's check
// in tests/canon.sh.
func TestCockpitRunningBuildPassesReaperTimeouts(t *testing.T) {
	for _, c := range []struct {
		body           string
		idle, idleMain float64
	}{
		{`{"version":"v","exe_mtime":1,"uptime_secs":2,"debug_enabled":true,"idle_timeout_secs":300,"idle_timeout_main_secs":1800}`, 300, 1800},
		{`{"version":"v","exe_mtime":1,"uptime_secs":2,"debug_enabled":false}`, 0, 0},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, c.body) }))
		got := cockpitRunningBuild(strings.TrimPrefix(srv.URL, "http://"))
		srv.Close()
		raw, _ := json.Marshal(got)
		var m map[string]any
		json.Unmarshal(raw, &m)
		if m["idle_timeout_secs"] != c.idle || m["idle_timeout_main_secs"] != c.idleMain || m["version"] != "v" {
			t.Errorf("running_build for %s = %v", c.body, m)
		}
	}
}

// t-4487: running_build carries the daemon's build stamp (`commit`) so Help > Versions can show `0.3.0 (0e2fd866)`;
// "" for a daemon that sends none, a non-string, null, odd text or an oversized value. Mirrors tests/canon.sh for server.py.
func TestCockpitRunningBuildPassesCommit(t *testing.T) {
	long := strings.Repeat("é", 100)
	longAlnum := strings.Repeat("a", 100)
	for _, c := range []struct{ body, want string }{
		{`{"version":"0.3.0","commit":"0e2fd866"}`, "0e2fd866"},
		{`{"version":"0.3.0"}`, ""},
		{`{"version":"0.3.0","commit":null}`, ""},
		{`{"version":"0.3.0","commit":12345}`, ""},
		{`{"version":"0.3.0","commit":["a"]}`, ""},
		{`{"version":"0.3.0","commit":{"x":1}}`, ""},
		{`{"version":"0.3.0","commit":"` + long + `"}`, ""},
		{`{"version":"0.3.0","commit":"` + longAlnum + `"}`, ""},
		{`{"version":"0.3.0","commit":"` + strings.Repeat("a", 64) + `"}`, strings.Repeat("a", 64)},
		{`{"version":"0.3.0","commit":"\ud800ab"}`, ""},
		{`{"version":"0.3.0","commit":"a b"}`, ""},
		{`{"version":"0.3.0","commit":"<b>x</b>"}`, ""},
		{`{"version":"dev","commit":"dev"}`, "dev"},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, c.body) }))
		got := cockpitRunningBuild(strings.TrimPrefix(srv.URL, "http://"))
		srv.Close()
		if got == nil || got["commit"] != c.want || (got["version"] != "0.3.0" && got["version"] != "dev") {
			t.Errorf("running_build for %.60s = %v, want commit %.20q", c.body, got, c.want)
		}
	}
}

// t-5df2: Admin > Model Tiers edits go to the Cockpit data dir; the tracked seed is read-only.
func TestModelTiersSavesToDataDirNotSeed(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", filepath.Join(dir, "home"))
	seed := filepath.Join(dir, "model-tiers.json")
	seedBody := `{"defaults":{"eval":{"anthropic":"seed-model"}},"models":{"anthropic":[{"id":"seed-model"}]}}`
	if err := os.WriteFile(seed, []byte(seedBody), 0o644); err != nil {
		t.Fatal(err)
	}
	old := modelTiersPath
	modelTiersPath = seed
	defer func() { modelTiersPath = old }()
	defaultOf := func() any {
		return loadModelTiers()["defaults"].(map[string]any)["eval"].(map[string]any)["anthropic"]
	}

	if got := defaultOf(); got != "seed-model" {
		t.Fatalf("with no data-dir copy want the seed, got %v", got)
	}
	edited := map[string]any{
		"defaults": map[string]any{"eval": map[string]any{"anthropic": "edited-model"}},
		"models":   map[string]any{"anthropic": []any{map[string]any{"id": "edited-model"}}},
	}
	if res := saveModelTiers(edited); res["ok"] != true {
		t.Fatalf("valid save refused: %v", res)
	}
	if got := defaultOf(); got != "edited-model" {
		t.Fatalf("want the data-dir copy, got %v", got)
	}
	if b, _ := os.ReadFile(seed); string(b) != seedBody {
		t.Fatalf("seed was modified: %s", b)
	}
	userFile := modelTiersUserFile()
	before, _ := os.ReadFile(userFile)
	for _, bad := range []map[string]any{
		{"models": "x", "defaults": map[string]any{}},
		{"reset": "yes"},
		{"reset": false},
		{"reset": true, "x": 1},
		{"models": map[string]any{"anthropic": []any{map[string]any{"id": "../x"}}}, "defaults": map[string]any{}},
	} {
		if res := saveModelTiers(bad); res["ok"] == true {
			t.Fatalf("payload %v should be refused", bad)
		}
		if after, _ := os.ReadFile(userFile); string(after) != string(before) {
			t.Fatalf("refused payload %v changed the data-dir copy", bad)
		}
	}
	for i := 0; i < 2; i++ { // second reset: nothing to remove, still ok
		if res := saveModelTiers(map[string]any{"reset": true}); res["ok"] != true {
			t.Fatalf("reset %d failed: %v", i, res)
		}
	}
	if _, err := os.Stat(userFile); !os.IsNotExist(err) {
		t.Fatalf("reset left the data-dir copy (err %v)", err)
	}
	if got := defaultOf(); got != "seed-model" {
		t.Fatalf("after reset want the seed, got %v", got)
	}
}

// t-9b2d: GET /static/<name> serves only a flat css/js name whose real file is static/<name>.
func TestServeStatic(t *testing.T) {
	root := setupTestProject(t)
	app := filepath.Join(root, "tools", "sprint-check-app")
	writeFile(t, filepath.Join(app, "app.html"), "<html>secret-app</html>")
	writeFile(t, filepath.Join(app, "static", "board-a.css"), "body{color:red}")
	writeFile(t, filepath.Join(app, "static", "editor.js"), "export const x = 1;")
	writeFile(t, filepath.Join(app, "static", "page.html"), "secret-html")
	writeFile(t, filepath.Join(app, "static", "sub", "x.css"), "secret-sub")
	writeFile(t, filepath.Join(app, "static", "notes.txt"), "secret-txt")
	if err := os.Symlink(filepath.Join(app, "app.html"), filepath.Join(app, "static", "out.css")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(app, "static", "notes.txt"), filepath.Join(app, "static", "in.css")); err != nil {
		t.Fatal(err)
	}
	get := func(target, host string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "http://127.0.0.1"+target, nil)
		if host != "" {
			req.Host = host
		}
		rec := httptest.NewRecorder()
		handle(rec, req)
		return rec
	}
	for _, c := range []struct{ target, ctype, body string }{
		{"/static/board-a.css", "text/css; charset=utf-8", "body{color:red}"},
		{"/static/editor.js", "text/javascript; charset=utf-8", "export const x = 1;"},
	} {
		rec := get(c.target, "")
		if rec.Code != 200 || rec.Header().Get("Content-Type") != c.ctype || rec.Body.String() != c.body {
			t.Fatalf("%s: code=%d type=%q body=%q", c.target, rec.Code, rec.Header().Get("Content-Type"), rec.Body.String())
		}
		if rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("%s: Cache-Control = %q, want no-store", c.target, rec.Header().Get("Cache-Control"))
		}
	}
	for _, target := range []string{
		"/static/../app.html", "/static/%2e%2e/app.html", "/static/..%2fapp.html", "/static/%2e%2e%2fserver.py",
		"/static/sub/x.css", "/static/BOARD-A.CSS", "/static/board-a.CSS", "/static/page.html", "/static/.css",
		"/static/board-a.css%00", "/static/..%5capp.html", "/static/out.css", "/static/in.css", "/static/notes.txt",
		"/static/missing.css", "/static/",
	} {
		rec := get(target, "")
		if rec.Code == 200 || strings.Contains(rec.Body.String(), "secret") {
			t.Fatalf("%s: code=%d body=%q, want a refusal", target, rec.Code, rec.Body.String())
		}
	}
	if rec := get("/static/board-a.css", "evil.example"); rec.Code != http.StatusForbidden {
		t.Fatalf("bad Host: code=%d, want 403", rec.Code)
	}
}

// t-718b: a new merge job must not keep the previous job's command handle: a stop sent before the new process
// registers would otherwise signal the finished one and be lost. startMergeRun clears it before the job starts.
func TestStartMergeRunDropsPreviousCmd(t *testing.T) {
	dir := t.TempDir()
	stub := filepath.Join(dir, "tkt")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nsleep 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TKT_BIN", stub)
	key := mergeKey{dir, "t-ab12"}
	old := &exec.Cmd{}
	mergeRunsMu.Lock()
	mergeCmds[key] = old
	mergeRuns[key] = map[string]any{"status": "done", "output": "", "exit_code": 0}
	mergeRunsMu.Unlock()
	startMergeRun(dir, "t-ab12", nil)
	mergeRunsMu.Lock()
	got := mergeCmds[key]
	mergeRunsMu.Unlock()
	if got == old {
		t.Fatalf("startMergeRun kept the previous job's command handle")
	}
	stopMergeRun(dir, "t-ab12")
}

// t-1699: a regex compiled inside a function runs on every request or ticket line; only section()'s per-heading cache may compile.
func TestNoRegexCompileInFuncs(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range f.Decls {
		fn, ok := d.(*ast.FuncDecl)
		if !ok || fn.Body == nil || fn.Name.Name == "headingLineRe" {
			continue
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "regexp" && strings.Contains(sel.Sel.Name, "Compile") {
				t.Errorf("%s: regexp.%s inside func %s: hoist it to a package-level var", fset.Position(call.Pos()), sel.Sel.Name, fn.Name.Name)
			}
			return true
		})
	}
}

// t-1699: the pre-cache section(), kept to prove the cached one returns the same text.
func oldSection(text, heading string) string {
	var out []string
	active := false
	for _, line := range strings.Split(text, "\n") {
		if regexp.MustCompile(`^##\s+` + regexp.QuoteMeta(heading) + `\s*$`).MatchString(line) {
			active = true
			continue
		}
		if active && strings.HasPrefix(line, "## ") {
			break
		}
		if active {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

func TestSectionMatchesOld(t *testing.T) {
	texts := []string{
		"# T\n## Criteria\n- [x] a\n## Test Plan\n- [ ] b\n",
		"## Criteria  \n- [ ] trailing spaces\n##\tTest Plan\t\n- [x] tab\n",
		"## Criteria\r\n- [ ] crlf\r\n## Sign-off\r\n- [x] ok\r\n",
		"##Criteria\n- no space after ##\n## Criteria extra\n- longer heading\n",
		"## a.b*c (x)\nmeta\n## Approach\n\n<!-- c -->\nbody\n",
		"", "## Wrapup Gates\n| g | ran |\n### sub\nstill in\n## Next\n",
		"text ## Criteria\n- [ ] mid-line heading is not a heading\n## Criteria\n- [x] real\n",
	}
	headings := []string{"Criteria", "Test Plan", "Sign-off", "Approach", "Wrapup Gates", "a.b*c (x)", "Criteria extra", "Missing"}
	for _, txt := range texts {
		for _, h := range headings {
			for i := 0; i < 2; i++ { // second pass reads the cached regex
				if got, want := section(txt, h), oldSection(txt, h); got != want {
					t.Errorf("section(%q, %q) = %q, want %q", txt, h, got, want)
				}
			}
		}
	}
}

// t-1699: go test -bench BenchmarkParseTicket -benchmem -run '^$' ./tools/sprint-check-go
func BenchmarkParseTicket(b *testing.B) {
	dir := b.TempDir()
	td := filepath.Join(dir, "t-abcd")
	if err := os.MkdirAll(td, 0o755); err != nil {
		b.Fatal(err)
	}
	for name, body := range map[string]string{
		"ticket.md":     "---\nid: t-abcd\nstatus: in_progress\ntype: task\npriority: 1\n---\n# A ticket\n\nBody.\n",
		"acceptance.md": "# Acceptance\n\n## Criteria\n" + strings.Repeat("- [x] C criterion text\n", 8) + "\n## Test Plan\n" + strings.Repeat("- [ ] T step\n", 8) + "\n## QA\n- [ ] Tested locally\n\n## Wrapup Gates\n| g | ran | (model: sonnet) |\n",
		"plan.md":       "# Plan\n\n## Sign-off\n- [x] Plan approved\n\n## Approach\n" + strings.Repeat("Step line.\n", 20) + "\n## Files\n- a.go\n",
	} {
		if err := os.WriteFile(filepath.Join(td, name), []byte(body), 0o644); err != nil {
			b.Fatal(err)
		}
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := parseTicket(filepath.Join(td, "ticket.md")); err != nil {
			b.Fatal(err)
		}
	}
}

// t-1699: the parsed-ticket cache must never show a stale card after any input of parseTicket changes.
func cacheTicket(t *testing.T, root, id string) ticket {
	t.Helper()
	for _, tk := range loadTickets(root) {
		if tk["id"] == id {
			return tk
		}
	}
	return nil
}

func bumpMtime(t *testing.T, path string, by time.Duration) {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, st.ModTime().Add(by), st.ModTime().Add(by)); err != nil {
		t.Fatal(err)
	}
}

func TestTicketCacheSeesEdits(t *testing.T) {
	root := setupTestProject(t)
	dir := filepath.Join(ticketsDir, "t-c1a1")
	tm := filepath.Join(dir, "ticket.md")
	writeFile(t, tm, "---\nid: t-c1a1\nstatus: open\ntype: task\n---\n# Title one\n")
	writeFile(t, filepath.Join(dir, "acceptance.md"), "## Criteria\n- [ ] a\n## Test Plan\n- [ ] b\n")
	writeFile(t, filepath.Join(dir, "plan.md"), "## Sign-off\n- [ ] Plan approved\n## Approach\nx\n")
	if tk := cacheTicket(t, root, "t-c1a1"); tk["status"] != "open" || tk["plan_approved"] != false || tk["acceptance_unchecked"] != true {
		t.Fatalf("initial load: %v", tk)
	}
	writeFile(t, tm, "---\nid: t-c1a1\nstatus: in_progress\ntype: task\n---\n# Title one\n")
	if tk := cacheTicket(t, root, "t-c1a1"); tk["status"] != "in_progress" {
		t.Fatalf("ticket.md edit not seen: %v", tk["status"])
	}
	writeFile(t, filepath.Join(dir, "acceptance.md"), "## Criteria\n- [x] a\n## Test Plan\n- [x] b\n")
	bumpMtime(t, filepath.Join(dir, "acceptance.md"), 2*time.Second) // same size: do not rely on two writes landing on different clock ticks
	if tk := cacheTicket(t, root, "t-c1a1"); tk["acceptance_unchecked"] != false || tk["acceptance_has_items"] != true {
		t.Fatalf("acceptance.md edit not seen: %v %v", tk["acceptance_unchecked"], tk["acceptance_has_items"])
	}
	writeFile(t, filepath.Join(dir, "plan.md"), "## Sign-off\n- [x] Plan approved\n## Approach\nx\n")
	bumpMtime(t, filepath.Join(dir, "plan.md"), 2*time.Second)
	if tk := cacheTicket(t, root, "t-c1a1"); tk["plan_approved"] != true {
		t.Fatalf("plan.md edit not seen: %v", tk["plan_approved"])
	}
	writeFile(t, filepath.Join(dir, "notes.md"), "n\n")
	if tk := cacheTicket(t, root, "t-c1a1"); !strings.Contains(fmt.Sprint(tk["docs"]), "notes.md") {
		t.Fatalf("added doc not listed: %v", tk["docs"])
	}
	if err := os.Remove(filepath.Join(dir, "plan.md")); err != nil {
		t.Fatal(err)
	}
	if tk := cacheTicket(t, root, "t-c1a1"); tk["plan_approved"] != nil {
		t.Fatalf("removed plan.md still read: %v", tk["plan_approved"])
	}
	// same size, new content: the mtime alone must invalidate
	writeFile(t, tm, "---\nid: t-c1a1\nstatus: in_progress\ntype: task\n---\n# Title two\n")
	bumpMtime(t, tm, 2*time.Second)
	if tk := cacheTicket(t, root, "t-c1a1"); tk["title"] != "Title two" {
		t.Fatalf("same-size edit not seen: %v", tk["title"])
	}
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if tk := cacheTicket(t, root, "t-c1a1"); tk != nil {
		t.Fatalf("deleted ticket still listed: %v", tk)
	}
	if _, hit := ticketCache.Load(tm); hit {
		t.Fatal("deleted ticket's cache entry was not evicted")
	}
	// every deleted ticket is evicted, not only the first one the scan meets
	var gone []string
	for _, id := range []string{"t-c1b1", "t-c1b2", "t-c1b3"} {
		p := filepath.Join(ticketsDir, id, "ticket.md")
		writeFile(t, p, "---\nid: "+id+"\nstatus: open\n---\n# E\n")
		gone = append(gone, p)
	}
	cacheTicket(t, root, "t-c1b1")
	for _, p := range gone {
		if err := os.RemoveAll(filepath.Dir(p)); err != nil {
			t.Fatal(err)
		}
	}
	cacheTicket(t, root, "t-c1b1")
	for _, p := range gone {
		if _, hit := ticketCache.Load(p); hit {
			t.Fatalf("deleted ticket %s was not evicted", p)
		}
	}
}

// A ticket that stats but cannot be read is skipped, never listed as an empty ticket, and is read again once readable.
func TestTicketCacheUnreadableTicket(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs a mode-0000 file to be unreadable: not on Windows, not as root")
	}
	root := setupTestProject(t)
	tm := filepath.Join(ticketsDir, "t-c3c3", "ticket.md")
	writeFile(t, tm, "---\nid: t-c3c3\nstatus: open\n---\n# Readable\n")
	if tk := cacheTicket(t, root, "t-c3c3"); tk == nil {
		t.Fatal("ticket not listed while readable")
	}
	writeFile(t, tm, "---\nid: t-c3c3\nstatus: open\n---\n# Locked out\n")
	if err := os.Chmod(tm, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(tm, 0o644)
	for _, tk := range loadTickets(root) {
		if tk == nil || tk["id"] == "t-c3c3" {
			t.Fatalf("an unreadable ticket was listed: %v", tk)
		}
	}
	if err := os.Chmod(tm, 0o644); err != nil {
		t.Fatal(err)
	}
	if tk := cacheTicket(t, root, "t-c3c3"); tk == nil || tk["title"] != "Locked out" {
		t.Fatalf("ticket not read again once readable: %v", tk)
	}
}

// The cache is used at all (a pure re-parse would pass TestTicketCacheSeesEdits too), and a caller's edits never reach it.
func TestTicketCacheReusesAndCopies(t *testing.T) {
	root := setupTestProject(t)
	tm := filepath.Join(ticketsDir, "t-c2b2", "ticket.md")
	writeFile(t, tm, "---\nid: t-c2b2\nstatus: open\n---\n# Kept\n")
	first := cacheTicket(t, root, "t-c2b2") // a miss: parsed and stored
	first["status"], first["injected"] = "hacked", true
	hit := cacheTicket(t, root, "t-c2b2") // a hit
	if hit["status"] != "open" || hit["injected"] != nil {
		t.Fatalf("a caller's edit of a fresh parse reached the cache: %v", hit)
	}
	hit["status"] = "hacked-again"
	if tk := cacheTicket(t, root, "t-c2b2"); tk["status"] != "open" {
		t.Fatalf("a caller's edit of a cache hit reached the cache: %v", tk["status"])
	}
	// a size change alone (mtime restored) must invalidate
	st0, _ := os.Stat(tm)
	writeFile(t, tm, "---\nid: t-c2b2\nstatus: open\n---\n# Kept longer\n")
	if err := os.Chtimes(tm, st0.ModTime(), st0.ModTime()); err != nil {
		t.Fatal(err)
	}
	if tk := cacheTicket(t, root, "t-c2b2"); tk["title"] != "Kept longer" {
		t.Fatalf("size-only change not seen: %v", tk["title"])
	}
	writeFile(t, tm, "---\nid: t-c2b2\nstatus: open\n---\n# Kept\n")
	st, _ := os.Stat(tm)
	writeFile(t, tm, "---\nid: t-c2b2\nstatus: open\n---\n# Kxpt\n") // same size
	if err := os.Chtimes(tm, st.ModTime(), st.ModTime()); err != nil {
		t.Fatal(err)
	}
	bumpMtime(t, filepath.Dir(tm), 3*time.Second) // ticket.md's mtime and size are restored; only the folder moved
	if tk := cacheTicket(t, root, "t-c2b2"); tk["title"] != "Kxpt" {
		t.Fatalf("folder mtime change did not invalidate: %v", tk["title"])
	}
	// now nothing moves: a content change hidden behind identical mtime+size is served from the cache (documented limit)
	st, _ = os.Stat(tm)
	dst, _ := os.Stat(filepath.Dir(tm))
	writeFile(t, tm, "---\nid: t-c2b2\nstatus: open\n---\n# Kzzt\n")
	_ = os.Chtimes(tm, st.ModTime(), st.ModTime())
	_ = os.Chtimes(filepath.Dir(tm), dst.ModTime(), dst.ModTime())
	if tk := cacheTicket(t, root, "t-c2b2"); tk["title"] != "Kxpt" {
		t.Fatalf("unchanged stat key re-parsed (no cache in use?): %v", tk["title"])
	}
}

func TestTicketCacheConcurrentLoads(t *testing.T) {
	root := setupTestProject(t)
	for i := 0; i < 20; i++ {
		writeFile(t, filepath.Join(ticketsDir, fmt.Sprintf("t-r%03d", i), "ticket.md"), fmt.Sprintf("---\nid: t-r%03d\nstatus: open\n---\n# R\n", i))
	}
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 30; i++ {
				if g == 0 {
					writeFile(t, filepath.Join(ticketsDir, fmt.Sprintf("t-r%03d", i%20), "ticket.md"), fmt.Sprintf("---\nid: t-r%03d\nstatus: in_progress\n---\n# R%d\n", i%20, i))
				}
				for _, tk := range loadTickets(root) {
					tk["type_outcome"] = g // callers write keys; must not race with other loads
				}
			}
		}(g)
	}
	wg.Wait()
	if n := len(loadTickets(root)); n != 20 {
		t.Fatalf("want 20 tickets, got %d", n)
	}
}

// t-1699: go test -bench BenchmarkLoadTickets -benchmem -run '^$' ./tools/sprint-check-go
func BenchmarkLoadTickets(b *testing.B) {
	root := b.TempDir()
	projectRoot, ticketsDir = root, filepath.Join(root, ".tickets")
	for i := 0; i < 200; i++ {
		d := filepath.Join(ticketsDir, fmt.Sprintf("t-%04x", i))
		_ = os.MkdirAll(d, 0o755)
		_ = os.WriteFile(filepath.Join(d, "ticket.md"), []byte(fmt.Sprintf("---\nid: t-%04x\nstatus: closed\ntype: task\n---\n# T\n\nBody.\n", i)), 0o644)
		_ = os.WriteFile(filepath.Join(d, "acceptance.md"), []byte("## Criteria\n"+strings.Repeat("- [x] c\n", 8)+"## Test Plan\n- [x] t\n## Wrapup Gates\n| g | (model: sonnet) |\n"), 0o644)
		_ = os.WriteFile(filepath.Join(d, "plan.md"), []byte("## Sign-off\n- [x] ok\n## Approach\n"+strings.Repeat("Step.\n", 20)), 0o644)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if n := len(loadTickets(root)); n != 200 {
			b.Fatal(n)
		}
	}
}

// t-15d8 (ported from board-branch-divergence.sh's server.py case): the divergence scan reads a worktree ticket
// only through plain folders; a linked ticket folder, ticket.md or .tickets is refused.
func TestScanTicketSafeRefusesLinks(t *testing.T) {
	base := t.TempDir()
	elsewhere := filepath.Join(base, "elsewhere")
	if err := os.MkdirAll(filepath.Join(elsewhere, "t-zzzz"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(elsewhere, "t-zzzz", "ticket.md"), []byte("status: open\n"), 0o644)
	mk := func(wt string) string {
		p := filepath.Join(base, wt)
		os.MkdirAll(filepath.Join(p, ".tickets"), 0o755)
		return p
	}
	plain := mk("plain")
	os.MkdirAll(filepath.Join(plain, ".tickets", "t-aaaa"), 0o755)
	os.WriteFile(filepath.Join(plain, ".tickets", "t-aaaa", "ticket.md"), []byte("status: open\n"), 0o644)
	if !scanTicketSafe(plain, "t-aaaa") {
		t.Fatal("a plain worktree ticket must be readable")
	}
	dirLink := mk("dirlink")
	if err := os.Symlink(filepath.Join(elsewhere, "t-zzzz"), filepath.Join(dirLink, ".tickets", "t-aaaa")); err != nil {
		t.Skip("symlinks unavailable:", err)
	}
	fileLink := mk("filelink")
	os.MkdirAll(filepath.Join(fileLink, ".tickets", "t-aaaa"), 0o755)
	os.Symlink(filepath.Join(elsewhere, "t-zzzz", "ticket.md"), filepath.Join(fileLink, ".tickets", "t-aaaa", "ticket.md"))
	treeLink := filepath.Join(base, "treelink")
	os.MkdirAll(treeLink, 0o755)
	os.Symlink(filepath.Join(plain, ".tickets"), filepath.Join(treeLink, ".tickets"))
	for wt, what := range map[string]string{dirLink: "ticket folder", fileLink: "ticket.md", treeLink: ".tickets"} {
		if scanTicketSafe(wt, "t-aaaa") {
			t.Errorf("a linked %s must be refused", what)
		}
	}
}
