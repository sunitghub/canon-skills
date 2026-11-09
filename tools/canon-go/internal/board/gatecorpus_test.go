package board

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Protects `canon-go gate-corpus` (t-a05d stage 1): every count of a seeded set of ticket folders equals a hand count, only fixed shapes are counted
// (a bucket line outside a triage section is not a bucket), a report with no Model or date lands under unknown and undated, an oversized file and a
// symlink are counted as unreadable without stopping the run, hostile text is never printed, and a run writes nothing.

var gcoUnreadable int // 1 when the seed holds a file the test cannot read (not as root)

func gcoSeed(t *testing.T) string {
	root := t.TempDir()
	gcoUnreadable = 0
	if os.Geteuid() != 0 {
		gcoUnreadable = 1
	}
	put := func(id, name, body string) {
		gcWrite(t, filepath.Join(root, ".tickets", id, name), body)
	}
	put("t-0001", "review-notes.md", "# Review Notes\n\nModel: claude-sonnet-5\nReviewed: 2026-10-03\n\n## Findings\n\nScope creep: none — checked x\nStandards violations: a.go:1 — a finding\nVisual regression: none\nDead code: Dead code in b.go:2 [severity: low]\n\n## Triage\n\nAct On: a.go:1 — x\nAct On: c.go:3 — y\nConsider: none\nNoted: d.go:4 — z\nDismissed: e.go:5 — w\n\n## Verdict\n\nNO\n")
	put("t-0002", "review-notes.md", "# Review Notes\n\nModel: claude-opus-4.8\nReviewed: 2026-09-10\n\n## Findings\n\n- Scope creep: f.go:1 — x\nUnnecessary complexity (hazard, a): g.go:2 — y\nStandards violations: none — checked\nAct On: a stray line outside a triage section\nsee Standards violations: not at the line start\n The Model: opus-in-prose\n\n## Verdict\n\n**YES**\n")
	put("t-0003", "review-notes.md", "# Review Notes\n\n## Findings\n\nDead code: none\n\n## Notes\n\nStandards violations: h.go:9 — named outside the findings section\n\n## Verdict\n\nMaybe\n")
	put("t-0004", "eval-report.md", "evaluator-run-id: 1-1\n\nModel: haiku\nEvaluated: 2026-11-02\n\npass: all good\n\n## Criteria\n\n| Criterion | Status | Evidence |\n|---|---|---|\n| a | pass | x |\n| b | pass — note | y |\n| c | fail | z |\n")
	put("t-0005", "eval-report.md", "Model: Sonnet (claude-sonnet-5)\nEvaluated: 2026-10-20\n\n## Criteria\n\n| Criterion | Status | Evidence |\n|---|---|---|\n| a | partial | x |\n| b | not-run | y |\n| c | waived | z |\n| d | PASS | w |\n\n## Verdict: partial\n")
	put("t-0006", "review-notes.md", "Model: sonnet\n"+strings.Repeat("x", 300<<10))
	put("t-0007", "ticket.md", "# t\n")
	if err := os.Symlink(filepath.Join(root, ".tickets", "t-0004", "eval-report.md"), filepath.Join(root, ".tickets", "t-0007", "eval-report.md")); err != nil {
		t.Skip("symlinks unavailable:", err)
	}
	put("t-0008", "review-notes.md", "Model: gpt-6 \x1b[31mred\x1b[0m "+strings.Repeat("M", 5000)+"\nReviewed: 2026-11-02\n\n## Triage\n\nAct On: "+strings.Repeat("A", 5000)+"\x1b]0;title\x07\n\n## Verdict\n\nyes\n")
	put("t-0009", "review-notes.md", "Model: claude-sonnet-5\nReviewed: 2026-10-15\n\n## Triage\n\nNoted: n.go:1 — only a note\nnote: Act On: mid-line, not a bucket\n\n## Verdict\n\nYES\n")
	exact := "Model: haiku\nReviewed: 2026-08-01\n## Triage\nNoted: x\n"
	put("t-0011", "review-notes.md", exact+strings.Repeat("x", gcoMaxFile-len(exact))) // exactly the cap: read, not unreadable
	if os.Geteuid() != 0 {
		put("t-0010", "eval-report.md", "Model: sonnet\n")
		if err := os.Chmod(filepath.Join(root, ".tickets", "t-0010", "eval-report.md"), 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(filepath.Join(root, ".tickets", "t-0010", "eval-report.md"), 0o644) })
	}
	put("notaticket", "review-notes.md", "## Triage\nAct On: ignored\n")
	put("T-0099", "review-notes.md", "## Triage\nAct On: ignored\n")
	return root
}

func TestGateCorpusCountsEqualAHandCount(t *testing.T) {
	r := gateCorpus(gcoSeed(t))
	if r.Tickets != 10+gcoUnreadable || r.Total.Reviews != 6 || r.Total.Evals != 2 {
		t.Fatalf("tickets %d reviews %d evals %d, want %d, 6, 2", r.Tickets, r.Total.Reviews, r.Total.Evals, 10+gcoUnreadable)
	}
	if r.Unreadable["larger than 256 KB"] != 1 || r.Unreadable["not a regular file"] != 1 || r.Unreadable["unreadable"] != gcoUnreadable || len(r.Unreadable) != 2+gcoUnreadable {
		t.Errorf("unreadable = %v", r.Unreadable)
	}
	tot := r.Total
	if tot.Verdicts["NO"] != 1 || tot.Verdicts["YES"] != 3 || tot.Verdicts["other"] != 2 {
		t.Errorf("reviewer verdicts = %v", tot.Verdicts) // t-0001 NO; t-0002 **YES**, t-0008 lower-case yes, t-0009 YES; t-0003 "Maybe" and t-0011 (none)
	}
	// t-0001, t-0008, t-0009 and t-0011 have a triage section; only t-0001 and t-0008 have an Act On line; the stray lines of t-0002 and t-0009 are not buckets
	if tot.Triaged != 4 || tot.WithActOn != 2 || tot.Lines["Act On"] != 3 || tot.Lines["Consider"] != 0 || tot.Lines["Noted"] != 3 || tot.Lines["Dismissed"] != 1 {
		t.Errorf("triaged %d with act on %d lines %v", tot.Triaged, tot.WithActOn, tot.Lines)
	}
	want := map[string]int{"Standards violations": 1, "Dead code": 1, "Scope creep": 1, "Unnecessary complexity": 1}
	for _, c := range gcoConcerns {
		if tot.Concerns[c] != want[c] {
			t.Errorf("concern %s = %d, want %d (%v)", c, tot.Concerns[c], want[c], tot.Concerns)
		}
	}
	if tot.EvalVerdicts["pass"] != 1 || tot.EvalVerdicts["partial"] != 1 || len(tot.EvalVerdicts) != 2 {
		t.Errorf("evaluator verdicts = %v", tot.EvalVerdicts) // t-0004 "pass:" line; t-0005 "## Verdict: partial" heading
	}
	if tot.Criteria["pass"] != 3 || tot.Criteria["fail"] != 1 || tot.Criteria["partial"] != 1 || tot.Criteria["not-run"] != 1 || tot.Criteria["other"] != 1 {
		t.Errorf("criteria = %v", tot.Criteria)
	}
	byModel := func(m string) *gcoSlice {
		s := r.ByModel[m]
		if s == nil {
			t.Fatalf("no model %q in %v", m, r.ByModel)
		}
		return s
	}
	if s := byModel("sonnet"); s.Reviews != 2 || s.Evals != 1 || s.WithActOn != 1 || s.Triaged != 2 {
		t.Errorf("sonnet = %+v", s)
	}
	if s := byModel("opus"); s.Reviews != 1 || s.Triaged != 0 || s.Lines["Act On"] != 0 {
		t.Errorf("opus = %+v", s)
	}
	if s := byModel("haiku"); s.Reviews != 1 || s.Evals != 1 || s.Triaged != 1 || s.Lines["Noted"] != 1 {
		t.Errorf("haiku = %+v", s)
	}
	if s := byModel("unknown"); s.Reviews != 1 {
		t.Errorf("unknown = %+v", s)
	}
	if s := byModel("other"); s.Reviews != 1 || s.Lines["Act On"] != 1 {
		t.Errorf("other = %+v", s)
	}
	if len(r.ByModel) != 5 || len(r.ByMonth) != 5 {
		t.Errorf("models = %v", r.ByModel)
	}
	byMonth := map[string][2]int{"2026-10": {2, 1}, "2026-09": {1, 0}, "2026-08": {1, 0}, "undated": {1, 0}, "2026-11": {1, 1}}
	for m, w := range byMonth {
		s := r.ByMonth[m]
		if s == nil || s.Reviews != w[0] || s.Evals != w[1] {
			t.Errorf("month %s = %+v, want reviews %d evals %d", m, s, w[0], w[1])
		}
	}
}

func TestGateCorpusPrintsNoFileText(t *testing.T) {
	root := gcoSeed(t)
	r := gateCorpus(root)
	var b bytes.Buffer
	gcoText(r, &b)
	for _, bad := range []string{"\x1b", "\x07", "AAAA", "MMMM", "gpt-6", "red", "finding", "Maybe"} {
		if strings.Contains(b.String(), bad) {
			t.Errorf("the report printed %q from a file:\n%s", bad, b.String())
		}
	}
	js, err := json.Marshal(r)
	if err != nil || strings.Contains(string(js), "AAAA") || strings.Contains(string(js), "\x1b") {
		t.Errorf("json: %v %s", err, js)
	}
	if !strings.Contains(b.String(), "tickets, 6 review-notes.md, 2 eval-report.md") {
		t.Errorf("text:\n%s", b.String())
	}
}

func TestGateCorpusEmptyAndMissingAndReadOnly(t *testing.T) {
	var b bytes.Buffer
	gcoText(gateCorpus(t.TempDir()), &b) // no .tickets at all
	if b.String() != "gate corpus: no tickets in this project's .tickets/\n" {
		t.Errorf("missing folder: %q", b.String())
	}
	empty := t.TempDir()
	os.MkdirAll(filepath.Join(empty, ".tickets"), 0o755)
	b.Reset()
	gcoText(gateCorpus(empty), &b)
	if !strings.Contains(b.String(), "no tickets") {
		t.Errorf("empty folder: %q", b.String())
	}
	root := gcoSeed(t)
	before := giHashTree(t, root)
	gateCorpus(root)
	if after := giHashTree(t, root); after != before {
		t.Errorf("a report changed the tickets folder")
	}
}

func TestGateCorpusCLI(t *testing.T) {
	root := gcoSeed(t)
	wd, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	var out, errb bytes.Buffer
	if rc := gateCorpusCLI([]string{"--json"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	var rep map[string]any
	if err := json.Unmarshal(out.Bytes(), &rep); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"tickets", "unreadable", "total", "by_model", "by_month"} {
		if _, ok := rep[k]; !ok {
			t.Errorf("json lacks %q: %s", k, out.String())
		}
	}
	if rep["tickets"] != float64(10+gcoUnreadable) {
		t.Errorf("tickets = %v", rep["tickets"])
	}
	tot := rep["total"].(map[string]any)
	for _, k := range []string{"reviews", "triaged_reviews", "reviews_with_act_on", "bucket_lines", "reviewer_verdicts", "concern_lines", "evaluations", "evaluator_verdicts", "criteria_rows"} {
		if _, ok := tot[k]; !ok {
			t.Errorf("total lacks %q", k)
		}
	}
	out.Reset()
	if rc := gateCorpusCLI(nil, &out, &errb); rc != 0 || !strings.HasPrefix(out.String(), "gate corpus, from the closed tickets' own reports") {
		t.Errorf("text: rc %d %q", rc, out.String())
	}
	errb.Reset()
	if rc := gateCorpusCLI([]string{"--days", "3"}, &out, &errb); rc != 2 || !strings.Contains(errb.String(), "usage: canon-go gate-corpus") {
		t.Errorf("usage: rc %d %q", rc, errb.String())
	}
}

// the whole text of the seeded folder, once, so a changed word, order or format is a failure (every number in it is also asserted above)
func TestGateCorpusTextOfTheSeededFolder(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("the seed holds an unreadable file only for a non-root user")
	}
	var b bytes.Buffer
	gcoText(gateCorpus(gcoSeed(t)), &b)
	want := `gate corpus, from the closed tickets' own reports (counts of fixed shapes only): 11 tickets, 6 review-notes.md, 2 eval-report.md
unreadable: 1 larger than 256 KB, 1 not a regular file, 1 unreadable

reviewer: YES 3, NO 1, other 2
  triaged reviews (with a ## Triage section): 4; with an Act On line: 2 (50%)
  bucket lines (not none): Act On 3, Consider 0, Noted 3, Dismissed 1
  template concern lines (not none, older reports): Scope creep 1, Visual regression 0, Dead code 1, Unnecessary complexity 1, Standards violations 1

evaluator: pass 1, fail 0, partial 1, not-run 0, other 0
  criteria rows: pass 3, fail 1, partial 1, not-run 1, other 1

by model: reviews (triaged, with Act On, Act On lines) | evaluations (pass, fail+partial)
  haiku        1 (1, 0, 0) |    1 (1, 0)
  opus         1 (0, 0, 0) |    0 (0, 0)
  other        1 (1, 1, 1) |    0 (0, 0)
  sonnet       2 (2, 1, 2) |    1 (0, 1)
  unknown      1 (0, 0, 0) |    0 (0, 0)

by month: reviews (triaged, with Act On, Act On lines) | evaluations (pass, fail+partial)
  2026-08      1 (1, 0, 0) |    0 (0, 0)
  2026-09      1 (0, 0, 0) |    0 (0, 0)
  2026-10      2 (2, 1, 2) |    1 (0, 1)
  2026-11      1 (1, 1, 1) |    1 (1, 0)
  undated      1 (0, 0, 0) |    0 (0, 0)
`
	if b.String() != want {
		t.Errorf("text differs:\n%s\nwant:\n%s", b.String(), want)
	}
}
