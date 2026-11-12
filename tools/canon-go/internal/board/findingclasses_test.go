package board

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-70f2: protects `canon-go finding-classes`, which `sprint start` and a close read to see a class repeat across tickets.

func fcTable(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "classes.tsv")
	body := "# comment\nbloat\tmore than needed\tHygiene\nhardcoding\ta value in code\tHygiene\nother\tfits none\tCorrectness\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func fcTicketFiles(t *testing.T, root, id, created, review, eval string) {
	t.Helper()
	d := filepath.Join(root, ".tickets", id)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(d, "ticket.md"), []byte("---\nid: "+id+"\ncreated: "+created+"\n---\n# t\n"), 0o644)
	if review != "" {
		os.WriteFile(filepath.Join(d, "review-notes.md"), []byte(review), 0o644)
	}
	if eval != "" {
		os.WriteFile(filepath.Join(d, "eval-report.md"), []byte(eval), 0o644)
	}
}

const fcReview = "## Findings\nHygiene: a.sh:3 — big [severity: low · confidence: high · class: %s]\nCorrectness: none — checked b.sh:4\nSecurity and trust boundaries: none — checked c.sh:9\n\n## Triage\nNoted: a.sh:3 — big [severity: low · confidence: high · class: %s]\n"

func review(slug string) string { return strings.ReplaceAll(fcReview, "%s", slug) }

func TestFindingClassesCountsTicketsNotLines(t *testing.T) {
	root := t.TempDir()
	slugs, err := fcLoadTable(fcTable(t, root))
	if err != nil {
		t.Fatal(err)
	}
	// one ticket with three bloat findings (reviewer, reviewer repeat, evaluator): one ticket, three findings; Triage lines are not findings
	rv := "## Findings\nHygiene: a [severity: low · confidence: high · class: bloat]\nHygiene: b [severity: low · confidence: high · class: bloat]\nHygiene: q [class: bloat] and more words after the tag\n\n## Triage\nNoted: a [severity: low · confidence: high · class: bloat]\n\n## Notes\nHygiene: outside the Findings section [severity: low · confidence: high · class: bloat]\n"
	ev := "## Findings\n1. a thing [class: bloat]\n2. another thing\n\n## Verdict\npass\n"
	fcTicketFiles(t, root, "t-aaaa", "2026-11-01", rv, ev)
	r := findingClasses(root, slugs, 10)
	if len(r.Classes) != 1 || r.Classes[0].Slug != "bloat" || len(r.Classes[0].Tickets) != 1 || r.Classes[0].Findings != 3 {
		t.Fatalf("classes = %+v", r.Classes)
	}
	if r.Untagged != 2 || r.Tagged != 3 || r.Tickets != 1 || r.Classes[0].Step != "" {
		t.Fatalf("report = %+v", r)
	}
}

func TestFindingClassesLadderAndWindow(t *testing.T) {
	root := t.TempDir()
	slugs, _ := fcLoadTable(fcTable(t, root))
	fcTicketFiles(t, root, "t-aaa1", "2026-11-01", review("bloat"), "")
	fcTicketFiles(t, root, "t-aaa2", "2026-11-02", review("bloat"), "")
	fcTicketFiles(t, root, "t-aaa3", "2026-11-03", review("hardcoding"), "")
	r := findingClasses(root, slugs, 10)
	if r.Classes[0].Slug != "bloat" || r.Classes[0].Step != "rule" || r.Classes[1].Step != "" {
		t.Fatalf("twice must propose a rule, once nothing: %+v", r.Classes)
	}
	fcTicketFiles(t, root, "t-aaa4", "2026-11-04", review("bloat"), "")
	r = findingClasses(root, slugs, 10)
	if r.Classes[0].Step != "check" || strings.Join(r.Classes[0].Tickets, " ") != "t-aaa4 t-aaa2 t-aaa1" {
		t.Fatalf("three tickets must propose a check, newest first: %+v", r.Classes[0])
	}
	// --last 2 sees only the two newest tickets (t-aaa4, t-aaa3): bloat once, hardcoding once
	r = findingClasses(root, slugs, 2)
	if r.Tickets != 2 || len(r.Classes) != 2 || r.Classes[0].Step != "" {
		t.Fatalf("window of 2 = %+v", r)
	}
}

func TestFindingClassesUnknownAndHostileFiles(t *testing.T) {
	root := t.TempDir()
	slugs, _ := fcLoadTable(fcTable(t, root))
	// an unknown slug is counted, its text never kept; a class tag in prose (not the trailing bracket) is not a tag
	rv := "## Findings\nHygiene: a [severity: low · confidence: high · class: ../../etc/passwd]\nHygiene: b says class: bloat in prose\nHygiene: c [severity: low · confidence: high · class: nosuch]\n"
	fcTicketFiles(t, root, "t-bbb1", "2026-11-01", rv, "")
	// a symlinked report and an oversized one are not read
	fcTicketFiles(t, root, "t-bbb2", "2026-11-02", "", "")
	os.Symlink(filepath.Join(root, ".tickets", "t-bbb1", "review-notes.md"), filepath.Join(root, ".tickets", "t-bbb2", "review-notes.md"))
	fcTicketFiles(t, root, "t-bbb3", "2026-11-03", "## Findings\n"+strings.Repeat("x", 300<<10), "")
	r := findingClasses(root, slugs, 10)
	if len(r.Classes) != 0 || r.Unknown != 1 || r.Untagged != 2 || r.Tickets != 1 {
		t.Fatalf("hostile input = %+v", r)
	}
}

func TestFindingClassesCLI(t *testing.T) {
	root := t.TempDir()
	tbl := fcTable(t, root)
	fcTicketFiles(t, root, "t-ccc1", "2026-11-01", review("bloat"), "")
	fcTicketFiles(t, root, "t-ccc2", "2026-11-02", review("bloat"), "")
	old, _ := os.Getwd()
	os.Chdir(root)
	defer os.Chdir(old)
	run := func(args ...string) (int, string, string) {
		var o, e bytes.Buffer
		c := findingClassesCLI(args, &o, &e)
		return c, o.String(), e.String()
	}
	c, out, _ := run("--table", tbl)
	if c != 0 || !strings.Contains(out, "bloat") || !strings.Contains(out, "propose a rule") {
		t.Fatalf("text: %d %q", c, out)
	}
	c, out, _ = run("--table", tbl, "--start")
	if c != 0 || !strings.HasPrefix(out, "Recurring finding class: bloat in 2 tickets (t-ccc2 t-ccc1): propose a rule") {
		t.Fatalf("start: %d %q", c, out)
	}
	c, out, _ = run("--table", tbl, "--json")
	if c != 0 || !strings.Contains(out, `"class":"bloat"`) || !strings.Contains(out, `"step":"rule"`) {
		t.Fatalf("json: %d %q", c, out)
	}
	for _, bad := range [][]string{{"--last", "0"}, {"--last", "x"}, {"--last", "007"}, {"--last", "201"}, {"--bogus"}} {
		if c, _, e := run(append([]string{"--table", tbl}, bad...)...); c != 2 || !strings.Contains(e, "usage:") {
			t.Fatalf("%v must exit 2 with usage: %d %q", bad, c, e)
		}
	}
	// a bad table exits 2; a duplicate slug is bad
	dup := filepath.Join(root, "dup.tsv")
	os.WriteFile(dup, []byte("bloat\ta\tHygiene\nbloat\tb\tHygiene\n"), 0o644)
	if c, _, _ := run("--table", dup); c != 2 {
		t.Fatalf("duplicate slug must exit 2, got %d", c)
	}
	// no tagged findings: say how to tag, exit 0; --start prints nothing
	empty := t.TempDir()
	os.Chdir(empty)
	c, out, _ = run("--table", tbl)
	if c != 0 || !strings.Contains(out, "no tagged findings yet") {
		t.Fatalf("empty: %d %q", c, out)
	}
	if _, out, _ = run("--table", tbl, "--start"); out != "" {
		t.Fatalf("--start with nothing to say must print nothing: %q", out)
	}
}
