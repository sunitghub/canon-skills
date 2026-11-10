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
	prPut(t, root, "PROMOTED.md", "- rule D (t-ffff; class: slug-four)\n")
	prPut(t, root, "skills/x/notes.txt", "- not markdown (t-gggg; class: slug-text)\n")
	prPut(t, root, "standards/big.md", "- big (t-hhhh; class: slug-big)\n"+strings.Repeat("x", 300<<10))
	prGit(t, root, "2026-10-01T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-01T12:00:00Z", "commit", "-q", "-m", "one")
	prPut(t, root, "skills/x/SKILL.md", "# x\n- rule C (t-dddd; class: slug-three)\n")
	prGit(t, root, "2026-10-10T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-10T12:00:00Z", "commit", "-q", "-m", "two")
	// two commits to one file: each tagged line keeps the date of the commit that wrote it, whatever its position
	prPut(t, root, "docs/releasing.md", "- first (t-iiii; class: slug-five)\n")
	prGit(t, root, "2026-10-02T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-02T12:00:00Z", "commit", "-q", "-m", "three")
	prPut(t, root, "docs/releasing.md", "- first (t-iiii; class: slug-five)\n- second (t-jjjj; class: slug-six)\n")
	prGit(t, root, "2026-10-03T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-03T12:00:00Z", "commit", "-q", "-m", "four")
	prTicket(t, root, "t-0001", "2026-10-05", map[string]string{"review-notes.md": "the slug-one failure again\n"})
	prTicket(t, root, "t-0002", "2026-10-06", map[string]string{"eval-report.md": "see t-aaaa for the history\n"})
	prTicket(t, root, "t-0003", "2026-09-20", map[string]string{"review-notes.md": "slug-one before the promotion\n"})
	prTicket(t, root, "t-aaaa", "2026-10-07", map[string]string{"learnings.md": "slug-one, the promoting ticket itself\n"})
	prTicket(t, root, "t-0004", "2026-10-08", map[string]string{"learnings.md": "slug-two and slug-two again, slug-four\n"})
	prTicket(t, root, "t-0005", "2026-10-09", map[string]string{"eval-report.md": "slug-two, and t-cccc, slug-four\n"})
	prTicket(t, root, "t-0006", "2026-10-10", map[string]string{"review-notes.md": "slug-three on the day it was promoted\n"})
	prTicket(t, root, "t-0007", "", map[string]string{"review-notes.md": "slug-one with no created date\n"})
	prTicket(t, root, "t-0009", "2026-10-11", map[string]string{"review-notes.md": strings.Repeat("x", 300<<10) + "slug-one\n"})
	if err := os.Symlink(filepath.Join(root, ".tickets", "t-0001"), filepath.Join(root, ".tickets", "t-0008")); err != nil {
		t.Fatal(err)
	}
	// a ticket.md that is a symlink is unreadable, so the ticket has no created date
	prTicket(t, root, "t-0010", "2026-10-12", map[string]string{"review-notes.md": "slug-one\n"})
	_ = os.Remove(filepath.Join(root, ".tickets", "t-0010", "ticket.md"))
	if err := os.Symlink(filepath.Join(root, ".tickets", "t-0001", "ticket.md"), filepath.Join(root, ".tickets", "t-0010", "ticket.md")); err != nil {
		t.Fatal(err)
	}
	// a class split across two report files is not a mention
	prTicket(t, root, "t-0011", "2026-10-12", map[string]string{"review-notes.md": "slug-", "eval-report.md": "one"})
	// not a ticket folder, and a file named like one
	prTicket(t, root, "other", "2026-10-12", map[string]string{"review-notes.md": "slug-one\n"})
	prPut(t, root, ".tickets/t-9999", "slug-one\n")
	// a markdown symlink under a place is not followed
	if err := os.Symlink(filepath.Join(root, "standards", "efficiency-notes.md"), filepath.Join(root, "skills", "x", "link.md")); err != nil {
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
	if five, six := prFind(r, "slug-five"), prFind(r, "slug-six"); five.Date != "2026-10-02" || six.Date != "2026-10-03" {
		t.Errorf("dates of a two-commit file: slug-five %q slug-six %q, want 2026-10-02 and 2026-10-03", five.Date, six.Date)
	}
	if len(r.Entries) != 6 {
		t.Fatalf("entries = %d, want 6 (the fenced tag, the .txt file, the oversize file and the symlink add none): %+v", len(r.Entries), r.Entries)
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
	if four := prFind(r, "slug-four"); four.BySlug != 2 || four.Verdict != "Failing again" || four.File != "PROMOTED.md" {
		t.Errorf("slug-four = %+v", four)
	}
	if r.Tickets != 9 {
		t.Errorf("tickets read = %d, want 9 (t-0007 and t-0010 have no readable created date; the symlink, other/ and the t-9999 file are not tickets)", r.Tickets)
	}
	if r.Skipped["tag inside a code fence"] != 1 || r.Skipped["ticket without a created date"] != 2 || r.Unreadable["larger than 256 KB"] != 2 || r.Unreadable["not a regular file"] != 1 {
		t.Errorf("skipped %v unreadable %v", r.Skipped, r.Unreadable)
	}
}

func TestPromotedReportTextAndJSON(t *testing.T) {
	root := prSeed(t)
	var b bytes.Buffer
	prText(promotedReport(root), &b)
	want := `promoted lines, from their (t-…; class: …) tags: 6 lines, 9 tickets read for a later mention of the class or the promoting ticket
1 not counted: tag inside a code fence; 2 not counted: ticket without a created date; 2 unreadable: larger than 256 KB; 1 unreadable: not a regular file
A later ticket counts when its review, eval or learnings text names the class itself or cites its P-id (class N, which drives the verdict) or only a promoting ticket id (ref M: it was mentioned, which is not a recurrence). 0 means never written down, not never recurred.

  Failing again  class 2   ref 2   -      slug-four (t-ffff, 2026-10-01)  PROMOTED.md
  Mentioned once class 1   ref 2   -      slug-one (t-aaaa, 2026-10-01)  standards/efficiency-notes.md
  Failing again  class 2   ref 2   P-007  slug-two (t-bbbb t-cccc, 2026-10-01)  standards/efficiency-notes.md
  Not mentioned  class 0   ref 0   -      slug-five (t-iiii, 2026-10-02)  docs/releasing.md
  Not mentioned  class 0   ref 0   -      slug-six (t-jjjj, 2026-10-03)  docs/releasing.md
  Not mentioned  class 0   ref 0   -      slug-three (t-dddd, 2026-10-10)  skills/x/SKILL.md
`
	if !strings.HasPrefix(b.String(), want) { // the entries come first; the size table after them has its own tests
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
	if err := json.Unmarshal(out.Bytes(), &rep); err != nil || rep["tickets_read"] != float64(9) {
		t.Errorf("json: %v %s", err, out.String())
	}
	es, _ := rep["entries"].([]any)
	first, _ := es[0].(map[string]any)
	for _, k := range []string{"file", "class", "tickets", "promoted", "later_tickets_referencing_it", "later_tickets_naming_the_class", "verdict"} {
		if _, ok := first[k]; !ok {
			t.Errorf("json entry has no %q: %v", k, first)
		}
	}
	for _, k := range []string{"entries", "tickets_read", "skipped", "unreadable"} {
		if _, ok := rep[k]; !ok {
			t.Errorf("json report has no %q", k)
		}
	}
	if _, ok := first["id"]; ok {
		t.Errorf("an entry with no id carries an id key: %v", first) // slug-four has none
	}
	out.Reset()
	if rc := promotedReportCLI(nil, &out, &errb); rc != 0 || !strings.HasPrefix(out.String(), "promoted lines, from their") {
		t.Errorf("text mode rc %d out %q", rc, out.String())
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

// a caller's GIT_DIR must not redirect the blame, and a file git does not know prints as No date in the text
func TestPromotedReportIgnoresGitDirAndPrintsNoDate(t *testing.T) {
	root := prSeed(t)
	t.Setenv("GIT_DIR", filepath.Join(t.TempDir(), "nowhere"))
	t.Setenv("GIT_WORK_TREE", t.TempDir())
	if one := prFind(promotedReport(root), "slug-one"); one.Date != "2026-10-01" {
		t.Errorf("slug-one date = %q with GIT_DIR set, want 2026-10-01", one.Date)
	}
	nogit := t.TempDir()
	prPut(t, nogit, "standards/efficiency-notes.md", "- rule (t-aaaa; class: slug-one)\n")
	prTicket(t, nogit, "t-0001", "2026-10-05", map[string]string{"review-notes.md": "slug-one\n"})
	var b bytes.Buffer
	prText(promotedReport(nogit), &b)
	if !strings.Contains(b.String(), "No date") || !strings.Contains(b.String(), "slug-one (t-aaaa, no date)") || !strings.Contains(b.String(), "1 not counted: no git date for the line") {
		t.Errorf("no-git text:\n%s", b.String())
	}
}

// a file name with a control byte cannot forge a line in the text view, and a tag on a fence line is counted, not dropped
func TestPromotedReportNamesAndFenceLines(t *testing.T) {
	if got := prSafeName("standards/a\nb\x1b[31m.md"); got != "standards/a?b?[31m.md" {
		t.Errorf("prSafeName = %q", got)
	}
	root := t.TempDir()
	prPut(t, root, "standards/efficiency-notes.md", "```go (t-aaaa; class: slug-one)\n- in a fence (t-bbbb; class: slug-two)\n```\n")
	r := promotedReport(root)
	if len(r.Entries) != 0 || r.Skipped["tag on a code fence line"] != 1 || r.Skipped["tag inside a code fence"] != 1 {
		t.Errorf("fence handling: entries %+v skipped %v", r.Entries, r.Skipped)
	}
}

// a later ticket that cites the entry's P-id counts as naming it; an id on another entry, or a longer id that starts the same, does not
func TestPromotedReportCountsAnIDCitation(t *testing.T) {
	root := t.TempDir()
	prGit(t, root, "2026-10-01T12:00:00Z", "init", "-q")
	prPut(t, root, "standards/efficiency-notes.md", "- rule A (t-aaaa; class: slug-one; id: P-001)\n- rule B (t-bbbb; class: slug-two; id: P-002)\n")
	prGit(t, root, "2026-10-01T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-01T12:00:00Z", "commit", "-q", "-m", "one")
	prTicket(t, root, "t-0001", "2026-10-05", map[string]string{"review-notes.md": "Correctness: a.go:1 — falls under P-001\n"})
	prTicket(t, root, "t-0002", "2026-10-06", map[string]string{"eval-report.md": "see P-0010 and P-001.\n"})
	prTicket(t, root, "t-0003", "2026-10-07", map[string]string{"learnings.md": "P-0020 is another rule\n"})
	r := promotedReport(root)
	if one := prFind(r, "slug-one"); one.BySlug != 2 || one.Verdict != "Failing again" || one.ID != "P-001" {
		t.Errorf("slug-one = %+v, want two citing tickets", one)
	}
	if two := prFind(r, "slug-two"); two.BySlug != 0 || two.Verdict != "Not mentioned" {
		t.Errorf("slug-two = %+v: P-0020 must not count as P-002", two)
	}
	// the edges of each alphanumeric range: these characters touch an id and it is not a whole token; the ones just outside each range do not
	for _, c := range []string{"0", "9", "A", "Z", "a", "z"} {
		if prCitesID(c+"P-7", "P-7") || prCitesID("P-7"+c, "P-7") {
			t.Errorf("an id touching %q counted as a whole token", c)
		}
	}
	for _, c := range []string{"/", ":", "@", "[", "`", "{", "-", " ", "(", ".", ","} {
		if !prCitesID(c+"P-7", "P-7") || !prCitesID("P-7"+c, "P-7") {
			t.Errorf("an id next to %q was not counted", c)
		}
	}
	for text, want := range map[string]bool{"x P-7": true, "P-7": true, "x P-70": false, "P-70 P-7": true, "XP-7": false, "AP-7x": false, "(P-7)": true, "p-7": false, "XP-7 P-7": true, "P-7P-7": false} {
		if got := prCitesID(text, "P-7"); got != want {
			t.Errorf("prCitesID(%q) = %v, want %v", text, got, want)
		}
	}
}

// the header's skip reasons are in a fixed order, so two runs over the same tree print the same text
func TestPromotedReportHeaderReasonOrder(t *testing.T) {
	r := &prReport{Entries: []prEntry{}, Tickets: 0,
		Skipped:    map[string]int{"tag on a code fence line": 1, "no git date for the line": 1, "ticket without a created date": 1},
		Unreadable: map[string]int{"unreadable": 1, "larger than 256 KB": 1, "not a regular file": 1}}
	var first bytes.Buffer
	prText(r, &first)
	want := "1 not counted: no git date for the line; 1 not counted: tag on a code fence line; 1 not counted: ticket without a created date; 1 unreadable: larger than 256 KB; 1 unreadable: not a regular file; 1 unreadable: unreadable"
	if !strings.Contains(first.String(), want) {
		t.Errorf("header order:\n%s", first.String())
	}
	for i := 0; i < 20; i++ {
		var b bytes.Buffer
		prText(r, &b)
		if b.String() != first.String() {
			t.Fatalf("run %d differs", i)
		}
	}
}

// a commit listed in .git-blame-ignore-revs (one that only added ids) does not reset a line's promotion date; without the file it does
func TestPromotedReportIgnoresTheIDBackfillCommit(t *testing.T) {
	root := t.TempDir()
	prGit(t, root, "2026-10-01T12:00:00Z", "init", "-q")
	prPut(t, root, "standards/efficiency-notes.md", "- rule A (t-aaaa; class: slug-one)\n")
	prGit(t, root, "2026-10-01T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-01T12:00:00Z", "commit", "-q", "-m", "one")
	prPut(t, root, "standards/efficiency-notes.md", "- rule A (t-aaaa; class: slug-one; id: P-001)\n")
	prGit(t, root, "2026-11-09T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-11-09T12:00:00Z", "commit", "-q", "-m", "ids")
	if e := prFind(promotedReport(root), "slug-one"); e.Date != "2026-11-09" {
		t.Fatalf("without an ignore file the id commit owns the line: date %q", e.Date)
	}
	sha := strings.TrimSpace(prOut(t, root, "rev-parse", "HEAD"))
	prPut(t, root, ".git-blame-ignore-revs", "# ids only\n"+sha+"\n")
	if e := prFind(promotedReport(root), "slug-one"); e.Date != "2026-10-01" || e.ID != "P-001" {
		t.Errorf("with the ignore file the line keeps its promotion date: %+v", e)
	}
}

func prOut(t *testing.T, root string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func prSizeOf(t *testing.T, r *prReport, file string) prSize {
	t.Helper()
	for _, z := range r.Sizes {
		if z.File == file {
			return z
		}
	}
	t.Fatalf("no size row for %s: %+v", file, r.Sizes)
	return prSize{}
}

// Prod path: the Size table of `canon-go promoted-report` (t-3620): each row's lines and words equal a hand count of the file, tokens are words x 1.3,
// the always-on files come first and an absent or unreadable file says why instead of reading as zero.
func TestPromotedReportSizeRowsEqualAHandCount(t *testing.T) {
	root := prSeed(t)
	r := promotedReport(root)
	var order []string
	for _, z := range r.Sizes {
		order = append(order, z.File)
	}
	if got, want := strings.Join(order[:4], " "), "standards/efficiency.md AGENTS.md CLAUDE.md PROMOTED.md"; got != want {
		t.Errorf("always-on rows come first, in order: got %q want %q", got, want)
	}
	z := prSizeOf(t, r, "standards/efficiency-notes.md") // 7 lines, 28 words by hand; two promoted lines of 6 and 9 words (the fenced one is not promoted)
	if z.Lines != 7 || z.Words != 28 || z.Tokens != 36 || z.PromotedLines != 2 || z.PromotedWords != 15 || z.AlwaysOn || z.Note != "" {
		t.Errorf("efficiency-notes row: %+v", z)
	}
	body, _ := os.ReadFile(filepath.Join(root, "standards", "efficiency-notes.md"))
	if len(strings.Fields(string(body))) != z.Words || bytes.Count(body, []byte("\n")) != z.Lines {
		t.Errorf("row disagrees with an independent count: %+v", z)
	}
	if p := prSizeOf(t, r, "PROMOTED.md"); p.Words != 6 || p.Lines != 1 || p.PromotedLines != 1 || p.PromotedWords != 6 || !p.AlwaysOn || p.NoClassTags {
		t.Errorf("PROMOTED.md with a tagged line: %+v", p)
	}
	if a := prSizeOf(t, r, "AGENTS.md"); a.Note != "not in this project" || a.Words != 0 || !a.AlwaysOn {
		t.Errorf("an absent always-on file says so: %+v", a)
	}
	if b := prSizeOf(t, r, "standards/big.md"); b.Note != "larger than 256 KB" || b.Words != 0 {
		t.Errorf("an oversize file says why: %+v", b)
	}
}

// Prod path: `canon-go promoted-report --since` (t-3620): the words of promoted lines last changed on or after the day; a bad day is a usage error.
func TestPromotedReportSinceAndItsUsageErrors(t *testing.T) {
	root := prSeed(t)
	before := prTreeHash(t, root)
	r := promotedReport(root)
	r.applySince("2026-10-03")
	want := map[string]int{"docs/releasing.md": 5, "skills/x/SKILL.md": 6, "standards/efficiency-notes.md": 0, "PROMOTED.md": 0}
	for f, n := range want {
		if z := prSizeOf(t, r, f); z.SinceWords == nil || *z.SinceWords != n {
			t.Errorf("%s since 2026-10-03: %v want %d", f, z.SinceWords, n)
		}
	}
	if z := prSizeOf(t, r, "standards/big.md"); z.SinceWords != nil {
		t.Errorf("a row with no numbers has no since figure: %+v", z)
	}
	cwd, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(cwd)
	for _, bad := range [][]string{{"--since"}, {"--since", "yesterday"}, {"--since=2026-13-40"}, {"--since=2026-10-1"}, {"--since="}, {"--since", ""}} {
		var out, errb bytes.Buffer
		if rc := promotedReportCLI(bad, &out, &errb); rc != 2 || !strings.Contains(errb.String(), "usage: canon-go promoted-report [--json] [--since YYYY-MM-DD]") || out.Len() != 0 {
			t.Errorf("%v: rc %d out %q err %q", bad, rc, out.String(), errb.String())
		}
	}
	var out, errb bytes.Buffer
	if rc := promotedReportCLI([]string{"--since=2026-10-03", "--json"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d err %q", rc, errb.String())
	}
	var rep struct {
		Sizes []map[string]any `json:"sizes"`
	}
	if err := json.Unmarshal(out.Bytes(), &rep); err != nil || len(rep.Sizes) == 0 {
		t.Fatalf("json: %v %s", err, out.String())
	}
	for _, k := range []string{"file", "always_on", "lines", "words", "tokens_estimate", "promoted_lines", "promoted_words", "since_words"} {
		if _, ok := rep.Sizes[3][k]; !ok { // PROMOTED.md: a readable row
			t.Errorf("a size row has no %q: %v", k, rep.Sizes[3])
		}
	}
	if after := prTreeHash(t, root); after != before {
		t.Error("the command changed the tree")
	}
}

// Prod path: `canon-go promoted-report` in an end user's project (t-3620): its PROMOTED.md entries carry no class tag, so the row counts the block's entries
// against the 60-line advisory cap, says recurrence is n/a, names the canon-only files as absent and exits 0.
func TestPromotedReportInAConsumerProject(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is required")
	}
	root := t.TempDir()
	prGit(t, root, "2026-10-01T12:00:00Z", "init", "-q")
	prPut(t, root, "AGENTS.md", "@PROMOTED.md\n")
	prPut(t, root, "PROMOTED.md", "# Promoted\n<!-- canon:promoted:BEGIN -->\n- When a, do b. (t-1234)\n- When c, do d. (t-5678)\n<!-- canon:promoted:END -->\n")
	if err := os.Symlink(filepath.Join(root, "AGENTS.md"), filepath.Join(root, "CLAUDE.md")); err != nil {
		t.Fatal(err)
	}
	prGit(t, root, "2026-10-01T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-01T12:00:00Z", "commit", "-q", "-m", "one")
	cwd, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(cwd)
	var out, errb bytes.Buffer
	if rc := promotedReportCLI([]string{"--since=2026-10-01"}, &out, &errb); rc != 0 || errb.Len() != 0 {
		t.Fatalf("rc %d err %q", rc, errb.String())
	}
	r := promotedReport(root)
	p := prSizeOf(t, r, "PROMOTED.md")
	if p.PromotedLines != 2 || p.PromotedWords != 12 || !p.NoClassTags || p.CapUsed == nil || *p.CapUsed != 2 || p.CapLimit != 60 || p.CapUnit != "block-lines" {
		t.Errorf("consumer PROMOTED.md row: %+v", p)
	}
	if e := prSizeOf(t, r, "standards/efficiency.md"); e.Note != "not in this project" {
		t.Errorf("a canon-only file is absent, not an error: %+v", e)
	}
	if c := prSizeOf(t, r, "CLAUDE.md"); c.Note != "not a regular file" {
		t.Errorf("a symlinked agent file is named, never followed: %+v", c)
	}
	got := out.String()
	if !strings.Contains(got, "no class tags, recurrence n/a") || !strings.Contains(got, "cap 2 of 60 block-lines") || !strings.Contains(got, "+12 since") || !strings.Contains(got, "standards/efficiency.md: not in this project") {
		t.Errorf("consumer text:\n%s", got)
	}
	if len(r.Entries) != 0 {
		t.Errorf("untagged entries are not recurrence entries: %+v", r.Entries)
	}
}

// Prod path: the Size table shows a capped file's use from canon's own tools/caps.tsv, the one table of caps (t-19bb), so the report and
// `canon-go caps` cannot disagree.
func TestPromotedReportSizeShowsTheCapFromCapsTSV(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is required")
	}
	root := t.TempDir()
	prGit(t, root, "2026-10-01T12:00:00Z", "init", "-q")
	prPut(t, root, "tools/src-key.sh", "#!/bin/sh\n")
	prPut(t, root, "tools/caps.tsv", "x\tskills/x.md\t10\twords\t-\n")
	prPut(t, root, "skills/x.md", "- rule (t-aaaa; class: slug-one)\n")
	cwd, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(cwd)
	z := prSizeOf(t, promotedReport(root), "skills/x.md")
	if z.CapUsed == nil || *z.CapUsed != 5 || z.CapLimit != 10 || z.CapUnit != "words" {
		t.Errorf("cap of a promoted file from caps.tsv: %+v", z)
	}
}

// Prod path: the Size table's PROMOTED.md row (t-3620, reviewer): a block that mixes tagged and untagged entries counts them all and still shows the cap row.
func TestPromotedReportMixedPromotedBlockKeepsTheCap(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is required")
	}
	root := t.TempDir()
	prGit(t, root, "2026-10-01T12:00:00Z", "init", "-q")
	prPut(t, root, "PROMOTED.md", "<!-- canon:promoted:BEGIN -->\n- tagged rule (t-aaaa; class: slug-one)\n- When a, do b. (t-1234)\n<!-- canon:promoted:END -->\n")
	prGit(t, root, "2026-10-01T12:00:00Z", "add", "-A")
	prGit(t, root, "2026-10-01T12:00:00Z", "commit", "-q", "-m", "one")
	p := prSizeOf(t, promotedReport(root), "PROMOTED.md")
	if p.PromotedLines != 2 || p.NoClassTags || p.CapUsed == nil || *p.CapUsed != 2 || p.CapLimit != 60 {
		t.Errorf("mixed block: %+v", p)
	}
}

// Prod path: the Size table is printed from repo-controlled file names (t-3620, reviewer): an escape code in a name never reaches the terminal.
func TestPromotedReportSizeTableEscapesFileNames(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is required")
	}
	root := t.TempDir()
	prGit(t, root, "2026-10-01T12:00:00Z", "init", "-q")
	name := "skills/a\x1b[31mred.md"
	if err := os.MkdirAll(filepath.Join(root, "skills"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, name), []byte("- rule (t-aaaa; class: slug-one)\n"), 0o644); err != nil {
		t.Skip("this file system refuses an escape byte in a name")
	}
	var b bytes.Buffer
	prText(promotedReport(root), &b)
	if strings.Contains(b.String(), "\x1b") {
		t.Errorf("an escape byte reached the text view: %q", b.String())
	}
	if !strings.Contains(b.String(), "on demand") || !strings.Contains(b.String(), "red.md") {
		t.Errorf("the escaped name has no row: %q", b.String())
	}
}
