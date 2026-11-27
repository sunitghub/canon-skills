//go:build !windows

package board

import (
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Protects the ticket loader against a FIFO named like a ticket file (t-ca73): os.ReadFile blocked on it forever, which hung
// /api/tickets and /api/v1/tickets. The loader must answer, with the other tickets, in well under the timeout.

func TestTicketFileFIFOsDoNotBlockTheLoader(t *testing.T) {
	for _, name := range []string{"ticket.md", "acceptance.md", "plan.md"} {
		root := setupTestProject(t)
		writeTicket(t, root, "t-good")
		dir := writeTicket(t, root, "t-fifo")
		fifo := filepath.Join(dir, name)
		if name == "ticket.md" {
			os.Remove(fifo)
		}
		if err := syscall.Mkfifo(fifo, 0o600); err != nil {
			t.Skip("no mkfifo:", err)
		}
		done := make(chan map[string]ticket, 1)
		go func() { done <- ticketIDs(root) }()
		select {
		case got := <-done:
			if got["t-good"] == nil {
				t.Errorf("%s: the other ticket vanished: %v", name, got)
			}
			if _, listed := got["t-fifo"]; listed != (name != "ticket.md") {
				t.Errorf("%s: t-fifo listed=%v", name, listed)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s as a FIFO blocked the loader", name)
		}
	}
}

// t-2800: the board's theme list reads each file through the themes folder's os.Root. A theme swapped for a FIFO after
// its Lstat must not block (the nonblock open) and reads as "not a regular file"; a symlinked theme is never read.
func TestThemeReadThroughRootFIFOSwapAndSymlink(t *testing.T) {
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "a.json"), []byte(`{"name":"A","mode":"dark","colors":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	calls := 0
	var fifoErr error
	t.Cleanup(func() { afterPathCheck = nil })
	afterPathCheck = func() { // runs on themeRead's goroutine: no t.Skip/Fatal here
		calls++
		if calls == 2 { // after the Lstat, before the open
			os.Remove(filepath.Join(d, "a.json"))
			fifoErr = syscall.Mkfifo(filepath.Join(d, "a.json"), 0o600)
		}
	}
	done := make(chan string, 1)
	go func() { _, reason := themeRead(d, "a.json"); done <- reason }()
	select {
	case reason := <-done:
		if fifoErr != nil {
			t.Skip("no FIFOs here")
		}
		if reason != "not a regular file" {
			t.Fatalf("a theme swapped for a FIFO: reason %q, want \"not a regular file\"", reason)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("themeRead hung on a theme swapped for a FIFO")
	}
	afterPathCheck = nil
	if err := os.Symlink(filepath.Join(d, "a.json"), filepath.Join(d, "b.json")); err != nil {
		t.Fatal(err)
	}
	if _, reason := themeRead(d, "b.json"); reason != "symbolic links are not read" {
		t.Fatalf("a symlinked theme: reason %q", reason)
	}
	// and a plain valid theme is still read through the root (mutation sweep: a dropped open went unnoticed)
	writeFile(t, filepath.Join(d, "c.json"), fuzzTheme)
	if th, reason := themeRead(d, "c.json"); reason != "" || th.Name == "" {
		t.Fatalf("a valid theme: %+v, reason %q", th, reason)
	}
}

// t-fe8d: GET /api/why reads each related ticket's plan.md for its first decision. A plan.md linked to a file outside
// .tickets must not be read: decision is "". (A regular plan.md: TestLoadWhy... in main_test.go.)
// Falsifier: planDecision back on os.ReadFile returns the outside heading.
func TestFe8dWhyDoesNotReadALinkedPlan(t *testing.T) {
	root := setupTestProject(t)
	runCmd(t, root, "git", "init", "-q")
	runCmd(t, root, "git", "config", "user.email", "test@example.com")
	runCmd(t, root, "git", "config", "user.name", "Test User")
	dir := filepath.Join(ticketsDir, "t-why1")
	writeFile(t, filepath.Join(dir, "ticket.md"), "---\nid: t-why1\nstatus: closed\n---\n# Improve invoice renderer\n")
	outside := filepath.Join(t.TempDir(), "secret.md")
	writeFile(t, outside, "# Plan\n\n## Decisions\n### SECRET-HEADING\n")
	if err := os.Symlink(outside, filepath.Join(dir, "plan.md")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "src", "invoice.js"), "x\n")
	runCmd(t, root, "git", "add", ".")
	runCmd(t, root, "git", "commit", "-qm", "refact invoice renderer paths")
	rec := httptest.NewRecorder()
	handle(rec, httptest.NewRequest("GET", "http://127.0.0.1/api/why?file=src/invoice.js", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"t-why1"`) {
		t.Fatalf("why: %d %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "SECRET") || !strings.Contains(rec.Body.String(), `"decision":""`) {
		t.Fatalf("a plan.md linked outside .tickets was read: %s", rec.Body.String())
	}
}

// t-fe8d: a ticket doc, image or feature file that is a FIFO must not block its GET (rootLoc.read opened it blocking);
// a regular file on the same route is still served. Each route is graded alone.
// Falsifier: rootLoc.read back on Root.ReadFile blocks every FIFO case past the timeout.
func TestFe8dTicketFileRoutesDoNotBlockOnAFIFO(t *testing.T) {
	for _, tc := range []struct{ route, name, want string }{
		{"/api/doc/t-aaaa/", "notes.md", `"content":"regular doc"`},
		{"/api/ticket-image/t-aaaa/", "shot.png", "regular doc"},
		{"/api/ticket-feature/t-aaaa/", "x.feature", `"content":"regular doc"`},
	} {
		root := setupTestProject(t)
		dir := writeTicket(t, root, "t-aaaa")
		writeFile(t, filepath.Join(dir, "ok-"+tc.name), "regular doc")
		rec := httptest.NewRecorder()
		handle(rec, httptest.NewRequest("GET", "http://127.0.0.1"+tc.route+"ok-"+tc.name, nil))
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), tc.want) {
			t.Errorf("%s regular: %d %q", tc.route, rec.Code, rec.Body.String())
		}
		fifo := filepath.Join(dir, tc.name)
		if err := syscall.Mkfifo(fifo, 0o600); err != nil {
			t.Skip("no mkfifo:", err)
		}
		done := make(chan int, 1)
		go func() {
			rec := httptest.NewRecorder()
			handle(rec, httptest.NewRequest("GET", "http://127.0.0.1"+tc.route+url.PathEscape(tc.name), nil))
			done <- rec.Code
		}()
		select {
		case code := <-done:
			if code == 200 {
				t.Errorf("%s FIFO: answered 200", tc.route)
			}
		case <-time.After(2 * time.Second):
			if w, err := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0); err == nil {
				w.Close() // release the blocked reader
			}
			t.Errorf("%s: a FIFO blocked the GET", tc.route)
		}
	}
}

// t-fe8d: worktree create's .worktreeinclude copy. Falsifier: the copy back on os.ReadFile/os.WriteFile copies the
// linked file's outside bytes and writes through the checkout's linked folder; without -z the non-ASCII name is skipped.
func worktreeIncludeFixture(t *testing.T) (root, outside string) {
	t.Helper()
	root = setupTestProject(t)
	runCmd(t, root, "git", "init", "-q")
	writeFile(t, filepath.Join(root, ".gitignore"), "*.env\n")
	writeFile(t, filepath.Join(root, ".worktreeinclude"), "*.env\n")
	outside = t.TempDir()
	return root, outside
}

func TestFe8dWorktreeIncludeSkipsALinkOutAndKeepsNamesAndModes(t *testing.T) {
	root, outside := worktreeIncludeFixture(t)
	writeFile(t, filepath.Join(outside, "outside.txt"), "OUTSIDE")
	if err := os.Symlink(filepath.Join(outside, "outside.txt"), filepath.Join(root, "link.env")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(root, "café.env"), "café bytes")
	if err := os.Chmod(filepath.Join(root, "café.env"), 0o600); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	got := copyWorktreeIncludeFiles(dest, root)
	if len(got) != 1 || got[0] != "café.env" {
		t.Fatalf("copied %q, want only café.env", got)
	}
	if _, err := os.Lstat(filepath.Join(dest, "link.env")); err == nil {
		t.Fatal("a link out of the project was copied")
	}
	b, err := os.ReadFile(filepath.Join(dest, "café.env"))
	if err != nil || string(b) != "café bytes" {
		t.Fatalf("café.env: %q %v", b, err)
	}
	if fi, _ := os.Stat(filepath.Join(dest, "café.env")); fi == nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("café.env mode: %v, want 0600", fi)
	}
}

// Break-it (t-fe8d): a first-listed name with a leading space was trimmed and skipped; a 0664 source landed 0644 under
// umask 022. Protects worktree create's .worktreeinclude copy (POST /api/worktree/create).
func TestFe8dWorktreeIncludeKeepsLeadingSpaceAndUmaskedMode(t *testing.T) {
	root, _ := worktreeIncludeFixture(t)
	writeFile(t, filepath.Join(root, " a.env"), "space")
	if err := os.Chmod(filepath.Join(root, " a.env"), 0o664); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	got := copyWorktreeIncludeFiles(dest, root)
	if len(got) != 1 || got[0] != " a.env" {
		t.Fatalf("copied %q, want only \" a.env\"", got)
	}
	if fi, _ := os.Stat(filepath.Join(dest, " a.env")); fi == nil || fi.Mode().Perm() != 0o664 {
		t.Fatalf("\" a.env\" mode: %v, want 0664", fi)
	}
}

func TestFe8dWorktreeIncludeDoesNotWriteThroughALinkedCheckoutFolder(t *testing.T) {
	root, outside := worktreeIncludeFixture(t)
	writeFile(t, filepath.Join(root, "config", "x.env"), "secret")
	dest := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dest, "config")); err != nil {
		t.Fatal(err)
	}
	if got := copyWorktreeIncludeFiles(dest, root); len(got) != 0 {
		t.Fatalf("copied %q through a linked folder", got)
	}
	if _, err := os.Lstat(filepath.Join(outside, "x.env")); err == nil {
		t.Fatal("x.env was written outside the new checkout")
	}
}

// t-fe8d: GET /api/skill-eval/report.html checks the report is inside the run's cache folder, then reads it. The
// run folder swapped for a link out after the check must answer 404, not the outside bytes.
// Falsifier: the read back on os.ReadFile(report_path) never calls the seam (fired stays false) and serves OUTSIDE.
func TestFe8dSkillEvalReportSwapAfterCheckRefused(t *testing.T) {
	canon := t.TempDir()
	writeFile(t, filepath.Join(canon, "tools", "src-key.sh"), "")
	old := appHTML
	t.Cleanup(func() { appHTML = old })
	root := setupTestProject(t)
	appHTML = filepath.Join(canon, "tools", "sprint-check-app", "app.html")
	skill := filepath.Join(root, ".claude", "skills", "demo")
	writeFile(t, filepath.Join(skill, "SKILL.md"), "x")
	p, errMsg := validateSkillDir(root, skill)
	if errMsg != "" {
		t.Fatal(errMsg)
	}
	tagDir := filepath.Join(resolvedOrAbs(canon), ".canon-cache", "skill-eval", skillEvalTag(root, p))
	report := filepath.Join(tagDir, "plugin", "evals", "results", "1", "report.html")
	writeFile(t, report, "INSIDE")
	skillEvalStateSave(root, p, map[string]any{"status": "done", "summary": map[string]any{}, "report_path": report})
	get := func() (int, string) {
		rec := httptest.NewRecorder()
		handle(rec, httptest.NewRequest("GET", "http://127.0.0.1/api/skill-eval/report.html?skill_dir="+url.QueryEscape(skill), nil))
		return rec.Code, rec.Body.String()
	}
	if code, body := get(); code != 200 || body != "INSIDE" {
		t.Fatalf("regular report: %d %q", code, body)
	}
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "plugin", "evals", "results", "1", "report.html"), "OUTSIDE")
	fired := false
	t.Cleanup(func() { afterPathCheck = nil })
	afterPathCheck = func() {
		if fired {
			return
		}
		fired = true
		os.Rename(tagDir, filepath.Join(t.TempDir(), "moved"))
		os.Symlink(outside, tagDir)
	}
	code, body := get()
	afterPathCheck = nil
	if !fired {
		t.Fatal("the report was not read through rootLoc (the seam never ran)")
	}
	if code != 404 || strings.Contains(body, "OUTSIDE") {
		t.Fatalf("swapped run folder: %d %q", code, body)
	}
}
