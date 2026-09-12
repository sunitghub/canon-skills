package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
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
	created := createTicket("", "", "", 2, "", false, false, "full", false, "", "")
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
	ev := createTicket("eval gate", "task", "open", 2, "", true, false, "eval", false, "", "")
	if ev["gate"] != "eval" {
		t.Fatalf("gate JSON = %v, want eval", ev["gate"])
	}
	raw, _ := os.ReadFile(filepath.Join(ticketsDir, ev["id"].(string), "ticket.md"))
	if !strings.Contains(string(raw), "gate: eval") {
		t.Fatalf("ticket.md missing 'gate: eval':\n%s", raw)
	}
	// full mode (default) writes no gate line
	full := createTicket("full gate", "task", "open", 2, "", true, false, "full", false, "", "")
	raw2, _ := os.ReadFile(filepath.Join(ticketsDir, full["id"].(string), "ticket.md"))
	if strings.Contains(string(raw2), "gate:") {
		t.Fatalf("full-mode ticket.md should have no gate line:\n%s", raw2)
	}
}

// t-354b: createTicket writes an allowlisted, order-preserving, deduped skills line.
func TestCreateTicketSkills(t *testing.T) {
	setupTestProject(t)
	c := createTicket("maint", "chore", "open", 2, "", false, false, "full", false, "context-check,dead-code-cleanup,bogus,context-check", "")
	raw, _ := os.ReadFile(filepath.Join(ticketsDir, c["id"].(string), "ticket.md"))
	if !strings.Contains(string(raw), "skills: context-check,dead-code-cleanup") {
		t.Fatalf("ticket.md missing expected skills line:\n%s", raw)
	}
	if strings.Contains(string(raw), "bogus") {
		t.Fatalf("non-allowlisted skill leaked into frontmatter:\n%s", raw)
	}
	none := createTicket("plain", "task", "open", 2, "", false, false, "full", false, "", "")
	raw2, _ := os.ReadFile(filepath.Join(ticketsDir, none["id"].(string), "ticket.md"))
	if strings.Contains(string(raw2), "skills:") {
		t.Fatalf("no-skills ticket should have no skills line:\n%s", raw2)
	}
}

func TestWriteStatusUpdatesActive(t *testing.T) {
	setupTestProject(t)
	created := createTicket("Active test", "task", "open", 2, "", false, false, "full", false, "", "")
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

	// non-git dir → error
	nongit := t.TempDir()
	if res := registryAdd(nongit, "x"); res["ok"].(bool) {
		t.Fatal("non-git dir should be rejected")
	}
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

	tk := createTicket("Scoped", "task", "open", 2, "body", false, false, "full", false, "", broot)
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
	// registerSkill rejects any non-sprint skill (fixed trust boundary)
	if res := registerSkill(dir, "wrapup"); res["ok"] != false {
		t.Fatalf("non-sprint skill must be rejected, got %v", res)
	}
}
