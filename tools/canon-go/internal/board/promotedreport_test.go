package board

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Prod path: `canon-go promoted-report` (t-1219): promoted lines from their tags, the date a line last changed from git, and the later tickets that
// name the class or only a promoting ticket id.

func prGit(t *testing.T, root, date string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE="+date, "GIT_COMMITTER_DATE="+date, "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func prPut(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func prTicket(t *testing.T, root, id, created string, files map[string]string) {
	t.Helper()
	head := "---\nid: " + id + "\nstatus: closed\n"
	if created != "" {
		head += "created: " + created + "T10:00:00Z\n"
	}
	prPut(t, root, ".tickets/"+id+"/ticket.md", head+"---\n# x\n")
	for f, body := range files {
		prPut(t, root, ".tickets/"+id+"/"+f, body)
	}
}

func prSeed(t *testing.T) string {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is required")
	}
	root := t.TempDir()
	prGit(t, root, "2026-10-01T12:00:00Z", "init", "-q")
	prPut(t, root, "standards/efficiency-notes.md", "# notes\n- rule A (t-aaaa; class: slug-one)\n- untagged rule\n- rule B (t-bbbb, t-cccc; class: slug-two; id: P-007)\n```\n- an example (t-eeee; class: slug-fenced)\n```\n")
	prGit(t, root, "2026-10-01T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-01T12:00:00Z", "commit", "-q", "-m", "one")
	prPut(t, root, "skills/x/SKILL.md", "# x\n- rule C (t-dddd; class: slug-three)\n")
	prGit(t, root, "2026-10-10T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-10T12:00:00Z", "commit", "-q", "-m", "two")
	prTicket(t, root, "t-0001", "2026-10-05", map[string]string{"review-notes.md": "the slug-one failure again\n"})
	prTicket(t, root, "t-0002", "2026-10-06", map[string]string{"eval-report.md": "see t-aaaa for the history\n"})
	prTicket(t, root, "t-0003", "2026-09-20", map[string]string{"review-notes.md": "slug-one before the promotion\n"})
	prTicket(t, root, "t-aaaa", "2026-10-07", map[string]string{"learnings.md": "slug-one, the promoting ticket itself\n"})
	prTicket(t, root, "t-0004", "2026-10-08", map[string]string{"learnings.md": "slug-two and slug-two again\n"})
	prTicket(t, root, "t-0005", "2026-10-09", map[string]string{"eval-report.md": "slug-two, and t-cccc\n"})
	prTicket(t, root, "t-0006", "2026-10-10", map[string]string{"review-notes.md": "slug-three on the day it was promoted\n"})
	prTicket(t, root, "t-0007", "", map[string]string{"review-notes.md": "slug-one with no created date\n"})
	prTicket(t, root, "t-0009", "2026-10-11", map[string]string{"review-notes.md": strings.Repeat("x", 300<<10) + "slug-one\n"})
	if err := os.Symlink(filepath.Join(root, ".tickets", "t-0001"), filepath.Join(root, ".tickets", "t-0008")); err != nil {
		t.Fatal(err)
	}
	return root
}

func prFind(r *prReport, slug string) prEntry {
	for _, e := range r.Entries {
		if e.Slug == slug {
			return e
		}
	}
	return prEntry{}
}

func TestPromotedReportCountsEqualAHandCount(t *testing.T) {
	r := promotedReport(prSeed(t))
	if len(r.Entries) != 3 {
		t.Fatalf("entries = %d, want 3 (the fenced tag is not one): %+v", len(r.Entries), r.Entries)
	}
	one, two, three := prFind(r, "slug-one"), prFind(r, "slug-two"), prFind(r, "slug-three")
	// slug-one promoted 2026-10-01: t-0001 names it, t-0002 only the ticket id, t-0003 is older, t-aaaa is the promoting ticket, t-0007 has no date, t-0009 is oversize
	if one.Date != "2026-10-01" || one.BySlug != 1 || one.Mentions != 2 || one.Verdict != "Mentioned once" || one.ID != "" {
		t.Errorf("slug-one = %+v", one)
	}
	// slug-two: t-0004 names it twice (one ticket), t-0005 names it and t-cccc
	if two.BySlug != 2 || two.Mentions != 2 || two.Verdict != "Failing again" || two.ID != "P-007" || len(two.Tickets) != 2 {
		t.Errorf("slug-two = %+v", two)
	}
	// slug-three promoted 2026-10-10: a ticket created that day is not later
	if three.Date != "2026-10-10" || three.BySlug != 0 || three.Mentions != 0 || three.Verdict != "Not mentioned" {
		t.Errorf("slug-three = %+v", three)
	}
	if r.Tickets != 8 {
		t.Errorf("tickets read = %d, want 8 (t-0007 has no created date, the symlink is skipped)", r.Tickets)
	}
	if r.Skipped["tag inside a code fence"] != 1 || r.Skipped["ticket without a created date"] != 1 || r.Unreadable["larger than 256 KB"] != 1 {
		t.Errorf("skipped %v unreadable %v", r.Skipped, r.Unreadable)
	}
}

func TestPromotedReportTextAndJSON(t *testing.T) {
	root := prSeed(t)
	var b bytes.Buffer
	prText(promotedReport(root), &b)
	want := `promoted lines, from their (t-…; class: …) tags: 3 lines, 8 tickets read for a later mention of the class or the promoting ticket
1 not counted: tag inside a code fence; 1 not counted: ticket without a created date; 1 unreadable: larger than 256 KB
A later ticket counts when its review, eval or learnings text names the class itself (class N, which drives the verdict) or only a promoting ticket id (ref M: it was mentioned, which is not a recurrence). 0 means never written down, not never recurred.

  Mentioned once class 1   ref 2   -      slug-one (t-aaaa, 2026-10-01)  standards/efficiency-notes.md
  Failing again  class 2   ref 2   P-007  slug-two (t-bbbb t-cccc, 2026-10-01)  standards/efficiency-notes.md
  Not mentioned  class 0   ref 0   -      slug-three (t-dddd, 2026-10-10)  skills/x/SKILL.md
`
	if b.String() != want {
		t.Errorf("text differs:\n%s\nwant:\n%s", b.String(), want)
	}
	before := prTreeHash(t, root)
	cwd, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(cwd)
	var out, errb bytes.Buffer
	if rc := promotedReportCLI([]string{"--json"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d err %q", rc, errb.String())
	}
	var rep map[string]any
	if err := json.Unmarshal(out.Bytes(), &rep); err != nil || rep["tickets_read"] != float64(8) {
		t.Errorf("json: %v %s", err, out.String())
	}
	if rc := promotedReportCLI([]string{"--nope"}, &out, &errb); rc != 2 || !strings.Contains(errb.String(), "usage: canon-go promoted-report [--json]") {
		t.Errorf("usage rc %d %q", rc, errb.String())
	}
	if after := prTreeHash(t, root); after != before {
		t.Error("the command changed the tree")
	}
}

func prTreeHash(t *testing.T, root string) string {
	t.Helper()
	var sb strings.Builder
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && !strings.Contains(p, "/.git/") {
			b, _ := os.ReadFile(p)
			sb.WriteString(p + string(b))
		}
		return nil
	})
	return sb.String()
}

// a tagged line with no git history is listed as No date and counted, never read as zero recurrences
func TestPromotedReportWithoutGitHistory(t *testing.T) {
	root := t.TempDir()
	prPut(t, root, "standards/efficiency-notes.md", "- rule (t-aaaa; class: slug-one)\n")
	prTicket(t, root, "t-0001", "2026-10-05", map[string]string{"review-notes.md": "slug-one\n"})
	r := promotedReport(root)
	if len(r.Entries) != 1 || r.Entries[0].Verdict != "No date" || r.Entries[0].BySlug != 0 || r.Skipped["no git date for the line"] != 1 {
		t.Errorf("no-git report = %+v skipped %v", r.Entries, r.Skipped)
	}
}

func TestPromotedReportUnreadableTicketsFolder(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read a mode 000 folder")
	}
	root := t.TempDir()
	dir := filepath.Join(root, ".tickets")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	cwd, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(cwd)
	var out, errb bytes.Buffer
	if rc := promotedReportCLI(nil, &out, &errb); rc != 1 || !strings.Contains(errb.String(), "cannot be read") || out.Len() != 0 {
		t.Errorf("rc %d out %q err %q", rc, out.String(), errb.String())
	}
}
