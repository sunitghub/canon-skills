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
	rv := "## Findings\nHygiene: a [severity: low · confidence: high · class: ../../etc/passwd]\nHygiene: b says class: bloat in prose\nHygiene: c [severity: low · confidence: high · class: nosuch]\n##\nHygiene: after a bare heading [severity: low · confidence: high · class: bloat]\n"
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

func fcRun(root, tbl string, args ...string) (int, string, string) {
	old, _ := os.Getwd()
	os.Chdir(root)
	defer os.Chdir(old)
	var o, e bytes.Buffer
	c := findingClassesCLI(append([]string{"--table", tbl}, args...), &o, &e)
	return c, o.String(), e.String()
}

func TestFindingClassesLineShapes(t *testing.T) {
	root := t.TempDir()
	slugs, _ := fcLoadTable(fcTable(t, root))
	// a concern line before any heading is not under ## Findings; "## Findings and more" is another section; a tag with trailing blanks is a tag;
	// an uppercase or over-long slug is no tag (untagged), a well-formed slug outside the table is unknown; an eval line that is not a list item ("see 1. x") is not a finding; "No findings." is none
	rv := "Hygiene: before any heading [severity: low · confidence: high · class: bloat]\n## Findings and more\nHygiene: wrong section [severity: low · confidence: high · class: bloat]\n## Findings\nHygiene: ok [severity: low · confidence: high · class: bloat]  \t\nHygiene: up [severity: low · confidence: high · class: Bloat]\nHygiene: long [severity: low · confidence: high · class: " + strings.Repeat("a", 60) + "]\nHygiene: nosuch [severity: low · confidence: high · class: nosuch]\n"
	ev := "## Findings\nsee 1. not an item [class: bloat]\n- a bullet item [class: hardcoding]\n3) another [class: other]\nNo findings.\n"
	fcTicketFiles(t, root, "t-ddd1", "2026-11-01", rv, ev)
	r := findingClasses(root, slugs, 10)
	got := map[string]int{}
	for _, c := range r.Classes {
		got[c.Slug] = c.Findings
	}
	if got["bloat"] != 1 || got["hardcoding"] != 1 || got["other"] != 1 || len(got) != 3 || r.Unknown != 1 || r.Untagged != 2 {
		t.Fatalf("shapes: classes %v unknown %d untagged %d", got, r.Unknown, r.Untagged)
	}
}

func TestFindingClassesOrderAndTicketFolders(t *testing.T) {
	root := t.TempDir()
	slugs, _ := fcLoadTable(fcTable(t, root))
	// same created day: the higher id is newer; a class with more tickets sorts first, ties by slug; non-ticket entries are ignored; a ticket
	// with no created date is still read (oldest)
	fcTicketFiles(t, root, "t-eee1", "2026-11-05", review("hardcoding"), "")
	fcTicketFiles(t, root, "t-eee2", "2026-11-05", review("bloat"), "")
	fcTicketFiles(t, root, "t-eee3", "2026-11-05", review("bloat"), "")
	fcTicketFiles(t, root, "t-eee4", "", review("other"), "")
	os.MkdirAll(filepath.Join(root, ".tickets", "notes"), 0o755)
	os.WriteFile(filepath.Join(root, ".tickets", "t-fff1"), []byte("a file, not a ticket"), 0o644)
	os.Symlink(filepath.Join(root, ".tickets", "t-eee1"), filepath.Join(root, ".tickets", "t-ggg1"))
	r := findingClasses(root, slugs, 10)
	if r.Tickets != 4 || len(r.Classes) != 3 {
		t.Fatalf("report = %+v", r)
	}
	if r.Classes[0].Slug != "bloat" || strings.Join(r.Classes[0].Tickets, " ") != "t-eee3 t-eee2" {
		t.Fatalf("most tickets first, newest id first: %+v", r.Classes[0])
	}
	if r.Classes[1].Slug != "hardcoding" || r.Classes[2].Slug != "other" {
		t.Fatalf("ties by slug: %+v", r.Classes)
	}
	r = findingClasses(root, slugs, 3)
	if r.Tickets != 3 || len(r.Classes) != 2 {
		t.Fatalf("--last 3 must drop the undated ticket: %+v", r)
	}
}

func TestFindingClassesTableErrors(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"two.tsv":     "bloat\tonly two\n",
		"badslug.tsv": "Bloat\tx\tHygiene\n",
		"empty.tsv":   "# nothing\n\n",
	} {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(body), 0o644)
		if _, err := fcLoadTable(p); err == nil {
			t.Fatalf("%s must be refused", name)
		}
	}
	if _, err := fcLoadTable(filepath.Join(dir, "missing.tsv")); err == nil || !strings.Contains(err.Error(), "missing.tsv") {
		t.Fatalf("a missing table must name the file: %v", err)
	}
	root := t.TempDir()
	if c, _, e := fcRun(root, filepath.Join(dir, "missing.tsv")); c != 2 || !strings.HasPrefix(e, "finding-classes: ") {
		t.Fatalf("a missing table exits 2 naming the command: %d %q", c, e)
	}
}

func TestFindingClassesCLIOutput(t *testing.T) {
	root := t.TempDir()
	tbl := fcTable(t, root)
	fcTicketFiles(t, root, "t-hhh1", "2026-11-01", review("bloat"), "")
	fcTicketFiles(t, root, "t-hhh2", "2026-11-02", review("bloat"), "")
	fcTicketFiles(t, root, "t-hhh3", "2026-11-03", review("hardcoding"), "")
	c, out, _ := fcRun(root, tbl, "--last", "2")
	if c != 0 || !strings.HasPrefix(out, "finding classes: 2 tickets with a gate report (newest 2); 2 tagged findings, 0 untagged, 0 with a class not in the table\n") {
		t.Fatalf("--last 2 header: %d %q", c, out)
	}
	if strings.Contains(out, "propose") {
		t.Fatalf("two tickets, two classes once each: no ladder: %q", out)
	}
	c, out, _ = fcRun(root, tbl)
	if !strings.Contains(out, "bloat                  2 tickets, 2 findings: t-hhh2 t-hhh1  -> propose a rule\n") {
		t.Fatalf("text row: %q", out)
	}
	_, out, _ = fcRun(root, tbl, "--start")
	if out != "Recurring finding class: bloat in 2 tickets (t-hhh2 t-hhh1): propose a rule. Details: canon-go finding-classes\n" {
		t.Fatalf("start line: %q", out)
	}
	var m map[string]any
	_, out, _ = fcRun(root, tbl, "--json")
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"last", "tickets_read", "tagged_findings", "untagged_findings", "unknown_class_findings", "classes", "promoted_rules_recurred"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("json lost %q: %v", k, m)
		}
	}
	cl := m["classes"].([]any)[0].(map[string]any)
	for _, k := range []string{"class", "tickets", "findings", "step"} {
		if _, ok := cl[k]; !ok {
			t.Fatalf("a class lost %q: %v", k, cl)
		}
	}
}

// a promoted rule that a later ticket named again is listed with the check step (promoted-report's own count, one owner)
func TestFindingClassesListsRecurredPromotedRule(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	root := t.TempDir()
	tbl := fcTable(t, root)
	os.MkdirAll(filepath.Join(root, "standards"), 0o755)
	os.WriteFile(filepath.Join(root, "standards", "efficiency-notes.md"), []byte("- a rule (t-aaaa; class: the-old-slug; id: P-001)\n- another (t-aaaa; class: no-id-slug)\n- quiet (t-aaaa; class: never-named-again)\n"), 0o644)
	env := append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t", "GIT_AUTHOR_DATE=2026-10-01T12:00:00Z", "GIT_COMMITTER_DATE=2026-10-01T12:00:00Z", "GIT_CONFIG_GLOBAL=/dev/null")
	for _, a := range [][]string{{"init", "-q"}, {"add", "standards"}, {"commit", "-q", "-m", "one"}} {
		cmd := exec.Command("git", a...)
		cmd.Dir, cmd.Env = root, env
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", a, err, out)
		}
	}
	fcTicketFiles(t, root, "t-iii1", "2026-11-01", "## Findings\nCorrectness: x [severity: low · confidence: high · class: other] the-old-slug and no-id-slug came back\n", "")
	_, out, _ := fcRun(root, tbl)
	for _, want := range []string{
		"promoted rule the-old-slug (P-001) was named again by 1 later tickets  -> propose a mechanical check (a ticket stub, never auto-filed)\n",
		"promoted rule no-id-slug (no id) was named again by 1 later tickets  -> propose a mechanical check",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in %q", want, out)
		}
	}
	if strings.Contains(out, "never-named-again") {
		t.Fatalf("a promoted rule no later ticket named must not be listed: %q", out)
	}
	_, out, _ = fcRun(root, tbl, "--start")
	if out != "" {
		t.Fatalf("a recurred promoted rule must not repeat in the start line: %q", out)
	}
	var m map[string]any
	_, js, _ := fcRun(root, tbl, "--json")
	if err := json.Unmarshal([]byte(js), &m); err != nil {
		t.Fatal(err)
	}
	matched := 0
	for _, r := range m["promoted_rules_recurred"].([]any) {
		row := r.(map[string]any)
		if row["class"] != "the-old-slug" {
			continue
		}
		matched++
		if row["id"] != "P-001" || row["later_tickets_naming_the_class"] != float64(1) {
			t.Fatalf("a promoted row = %v", row)
		}
	}
	if matched != 1 {
		t.Fatalf("the recurred rule must be one row keyed class/id/later_tickets_naming_the_class: %v", m["promoted_rules_recurred"])
	}
}

func TestFindingClassesNewestByCreatedAndManyTies(t *testing.T) {
	root := t.TempDir()
	tbl := filepath.Join(root, "ties.tsv")
	os.WriteFile(tbl, []byte("alpha\tx\tHygiene\nbravo\tx\tHygiene\ncharlie\tx\tHygiene\ndelta\tx\tHygiene\necho\tx\tHygiene\nfoxtrot\tx\tHygiene\ngolf\tx\tHygiene\nhotel\tx\tHygiene\n"), 0o644)
	slugs, err := fcLoadTable(tbl)
	if err != nil {
		t.Fatal(err)
	}
	// the newest ticket is the one created last, not the one with the highest id
	fcTicketFiles(t, root, "t-zzz1", "2026-11-01", review("hotel"), "")
	fcTicketFiles(t, root, "t-aaa1", "2026-11-09", review("golf"), "")
	if r := findingClasses(root, slugs, 1); len(r.Classes) != 1 || r.Classes[0].Slug != "golf" {
		t.Fatalf("--last 1 must take the ticket created last: %+v", r.Classes)
	}
	// non-ticket folders and a linked ticket folder are not read, even with a report inside
	os.MkdirAll(filepath.Join(root, ".tickets", "notes"), 0o755)
	os.WriteFile(filepath.Join(root, ".tickets", "notes", "review-notes.md"), []byte(review("alpha")), 0o644)
	os.Symlink(filepath.Join(root, ".tickets", "t-zzz1"), filepath.Join(root, ".tickets", "t-yyy1"))
	r := findingClasses(root, slugs, 10)
	if r.Tickets != 2 {
		t.Fatalf("a notes folder or a symlinked ticket was read: %+v", r)
	}
	// more tickets first; ties by slug, whatever the map order
	for i, sl := range []string{"alpha", "bravo", "charlie", "delta", "echo", "foxtrot"} {
		fcTicketFiles(t, root, "t-ttt"+string(rune('a'+i)), "2026-10-0"+string(rune('1'+i)), review(sl), "")
	}
	fcTicketFiles(t, root, "t-ttt9", "2026-10-09", review("hotel"), "")
	got := []string{}
	for _, c := range findingClasses(root, slugs, 20).Classes {
		got = append(got, c.Slug)
	}
	if strings.Join(got, " ") != "hotel alpha bravo charlie delta echo foxtrot golf" {
		t.Fatalf("order = %v", got)
	}
}

func TestFindingClassesFlagBounds(t *testing.T) {
	root := t.TempDir()
	tbl := fcTable(t, root)
	for _, ok := range []string{"1", "200"} {
		if c, _, e := fcRun(root, tbl, "--last", ok); c != 0 {
			t.Fatalf("--last %s must be accepted: %d %q", ok, c, e)
		}
	}
	for _, args := range [][]string{{"--last"}, {"--table"}} {
		old, _ := os.Getwd()
		os.Chdir(root)
		var o, e bytes.Buffer
		c := findingClassesCLI(append([]string{"--table", tbl}, args...), &o, &e)
		if args[0] == "--table" { // the flag with no value after the real --table: it is the value of nothing
			c = findingClassesCLI([]string{"--table"}, &o, &e)
		}
		os.Chdir(old)
		if c != 2 || !strings.Contains(e.String(), "usage:") {
			t.Fatalf("%v with no value must exit 2 with usage: %d %q", args, c, e.String())
		}
	}
	// a slug with trailing junk is not a slug
	bad := filepath.Join(root, "junk.tsv")
	os.WriteFile(bad, []byte("bloat!\tx\tHygiene\n"), 0o644)
	if _, err := fcLoadTable(bad); err == nil {
		t.Fatal("a slug with a trailing character must be refused")
	}
}

func TestFindingClassesDefaultTable(t *testing.T) {
	// no --table: the install's own tools/finding-classes.tsv, found from the project folder (a canon root has tools/src-key.sh)
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, ".tickets"), 0o755)
	os.MkdirAll(filepath.Join(root, "tools"), 0o755)
	os.WriteFile(filepath.Join(root, "tools", "src-key.sh"), []byte("#!/bin/sh\n"), 0o644)
	os.WriteFile(filepath.Join(root, "tools", "finding-classes.tsv"), []byte("bloat\tx\tHygiene\n"), 0o644)
	old, _ := os.Getwd()
	os.Chdir(root)
	defer os.Chdir(old)
	var o, e bytes.Buffer
	if c := findingClassesCLI([]string{"--last", "1"}, &o, &e); c != 0 || !strings.HasPrefix(o.String(), "finding classes:") {
		t.Fatalf("default table: %d %q %q", c, o.String(), e.String())
	}
	// a project that is not a canon install (and the test binary is not one): exit 2 naming --table
	os.Remove(filepath.Join(root, "tools", "src-key.sh"))
	o.Reset()
	e.Reset()
	if c := findingClassesCLI(nil, &o, &e); c != 2 || !strings.Contains(e.String(), "no canon install found; pass --table <file>") {
		t.Fatalf("no install: %d %q", c, e.String())
	}
}

func TestFindingClassesFirstCreatedLineWins(t *testing.T) {
	root := t.TempDir()
	slugs, _ := fcLoadTable(fcTable(t, root))
	fcTicketFiles(t, root, "t-jjj1", "2026-11-01", review("bloat"), "")
	fcTicketFiles(t, root, "t-jjj2", "2026-11-05", review("hardcoding"), "")
	// a second `created:` line in the body must not move t-jjj1 to the newest
	os.WriteFile(filepath.Join(root, ".tickets", "t-jjj1", "ticket.md"), []byte("---\nid: t-jjj1\ncreated: 2026-11-01\n---\n# t\ncreated: 2030-01-01\n"), 0o644)
	if r := findingClasses(root, slugs, 1); len(r.Classes) != 1 || r.Classes[0].Slug != "hardcoding" {
		t.Fatalf("the first created line decides: %+v", r.Classes)
	}
}
