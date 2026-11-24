package artifact

// Protects `sprint validate` and pre-gate's `artifacts` field (t-c2de): every rule accepts its well-formed line and
// names its broken one, prose is never checked, and no input panics.

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const hex40 = "c7eb956c55f08f95ea4bfdd5e336007b91e7d75c"
const hex64 = "43d7c9469079310e0bfe31799a0170730f74a7137ad6882ac29f3d4849b2148e"

// Well-formed artifacts in the shapes canon writes today (taken from t-ca0e's own files), with prose a reader skips.
var valid = map[string]string{
	"ticket.md":       "---\nid: t-abcd\nstatus: open\ncreated: 2026-11-24T00:00:00Z\ntype: feature\npriority: 1\neval_override: false\neval_fail_count: 0\ntags: [go, schema]\nrun_preset: economy\n---\n# A title\n\nstatus: a body line is prose\n",
	"acceptance.md":   "# Acceptance\n\nTicket: `t-abcd`\n\n## Criteria\n- [ ] one\n* [x] two\n  - [X] [manual] three\n\n## Test Plan\n- [ ] `go test ./...` (protects x)\n- [x] [manual] a person checks it\n\n## QA\n- [x] Tested locally\n\n## Wrapup Gates\n| Gate | Status | Notes |\n|---|---|---|\n| reviewer | ran | verdict: YES \\| ok (model: sonnet) |\n| mutation-test | skipped | no logic file changed |\n",
	"plan.md":         "# Plan\n\n## Sign-off\n**Tier**: Normal. | Risk: low | Gate model: haiku\n\n- [x] Plan approved — proceed to implementation\nApproved: sha256:" + hex64 + " 2026-11-24T22:40:44Z\nPipeline: sha256:1de8c9fc6b17 off=- wrapup=code-simplifier\n\n## Approach\nTier: a prose line outside Sign-off\nApproved: by the user\n```\n- [ ] Plan approved\n```\n",
	"eval-report.md":  "evaluator-run-id: 1795556751-20092\ngraded-head: " + hex40 + "\nModel: sonnet (Admin Evaluator default, claude)\n\npass: every criterion is proven\n\n```\nfail: a quoted log line\nevaluator-run-id: quoted\n```\n",
	"review-notes.md": "# Review\n\nAct On: none\n\n## Verdict\n\n**YES** — nothing to act on\n",
}

type refusal struct {
	file, old, new, rule string
	line                 int // 0: the line where `new` starts
}

var refusals = []refusal{
	{"ticket.md", "---\nid", "--\nid", "ticket.frontmatter", 1},
	{"ticket.md", "run_preset: economy\n---\n", "run_preset: economy\n", "ticket.frontmatter", 1},
	{"ticket.md", "status: open\n", "status: open\nstatus: closed\n", "ticket.key-duplicate", 4},
	{"ticket.md", "type: feature", "type:feature", "ticket.field-shape", 0},
	{"ticket.md", "id: t-abcd", "id: t-abce", "ticket.id", 0},
	{"ticket.md", "id: t-abcd", "id: ticket-1", "ticket.id", 0},
	{"ticket.md", "status: open", "status: done", "ticket.status", 0},
	{"ticket.md", "status: open\n", "", "ticket.status", 1},
	{"ticket.md", "type: feature", "type: feat", "ticket.type", 0},
	{"ticket.md", "priority: 1", "priority: p1", "ticket.priority", 0},
	{"ticket.md", "eval_override: false", "eval_override: yes", "ticket.flag", 0},
	{"ticket.md", "eval_fail_count: 0", "eval_fail_count: -1", "ticket.eval-fail-count", 0},
	{"acceptance.md", "## QA\n", "## Q A\n", "acceptance.section", 1},
	{"acceptance.md", "## QA\n", "## Criteria\n", "acceptance.section", 14},
	{"acceptance.md", "- [ ] `go test", "- [ ]`go test", "acceptance.box", 0},
	{"acceptance.md", "- [ ] one", "- [] one", "acceptance.box", 0},
	{"acceptance.md", "* [x] two", "* [y] two", "acceptance.box", 0},
	{"acceptance.md", "- [x] Tested locally", "- [x]", "acceptance.box", 15},
	{"acceptance.md", "| skipped | no logic", "| skip | no logic", "acceptance.wrapup-row", 0},
	{"acceptance.md", "| no logic file changed |", "| — |", "acceptance.wrapup-row", 0},
	{"acceptance.md", "| mutation-test | skipped | no logic file changed |", "| mutation-test | ran |", "acceptance.wrapup-row", 0},
	{"plan.md", "## Sign-off\n", "## Signoff\n", "plan.signoff", 1},
	{"plan.md", "**Tier**: Normal.", "Tier: trivial-adjacent", "plan.tier", 0},
	{"plan.md", "- [x] Plan approved", "tier: bugfix\n- [x] Plan approved", "plan.tier", 0},
	{"plan.md", "- [x] Plan approved", "- [v] Plan approved", "plan.approval-box", 0},
	{"plan.md", "- [x] Plan approved", "- Plan approved", "plan.approval-box", 1},
	{"plan.md", "\n## Approach", "- [ ] Plan approved\n\n## Approach", "plan.approval-box", 0},
	{"plan.md", "2026-11-24T22:40:44Z", "2026-11-24 22:40", "plan.approved-stamp", 7},
	{"plan.md", "Pipeline: sha256:1de8", "Pipeline: 1de8", "plan.pipeline-stamp", 0},
	{"eval-report.md", "1795556751-20092", "1795556751", "eval.run-id", 1},
	{"eval-report.md", "evaluator-run-id: 1795556751-20092\n", "", "eval.run-id", 1},
	{"eval-report.md", "\npass:", "\nevaluator-run-id: 1-2\npass:", "eval.run-id", 0},
	{"eval-report.md", "Model: sonnet (Admin Evaluator default, claude)", "Model:", "eval.model", 0},
	{"eval-report.md", "Model: sonnet", "Modl: sonnet", "eval.model", 1},
	{"eval-report.md", "graded-head: " + hex40 + "\nModel", "graded-head: c7eb956\nModel", "eval.graded-head", 0},
	{"eval-report.md", "Model: sonnet", "graded-head: " + strings.Repeat("a", 40) + "\nModel: sonnet", "eval.graded-head", 0},
	{"eval-report.md", "graded-head: " + hex40 + "\nModel", "Model", "eval.graded-head", 1},
	{"eval-report.md", "pass: every criterion is proven", "pass:", "eval.verdict", 0},
	{"eval-report.md", "pass: every", "PASS: every", "eval.verdict", 1},
	{"eval-report.md", "pass: every criterion is proven\n", "pass: every criterion is proven\nfail: and another\n", "eval.verdict", 6},
	{"review-notes.md", "**YES** — nothing to act on", "Maybe — later", "review.verdict", 0},
	{"review-notes.md", "## Verdict\n", "Verdict: YES\n", "review.verdict", 1},
}

func lineOf(text, needle string) int {
	i := strings.Index(text, needle)
	if i < 0 {
		return -1
	}
	return strings.Count(text[:i], "\n") + 1
}

func TestValidArtifactsHaveNoFindings(t *testing.T) {
	for name, body := range valid {
		if fs := Check(name, []byte(body), "t-abcd"); len(fs) != 0 {
			t.Errorf("%s: want no finding, got %v", name, fs)
		}
	}
}

func TestEachRuleRefusesItsBrokenLine(t *testing.T) {
	covered := map[string]bool{}
	for _, r := range refusals {
		body := valid[r.file]
		if !strings.Contains(body, r.old) {
			t.Fatalf("case %s: fixture %s has no %q", r.rule, r.file, r.old)
		}
		broken := strings.Replace(body, r.old, r.new, 1)
		want := r.line
		if want == 0 {
			want = lineOf(broken, r.new)
			if r.new == "" || strings.HasPrefix(r.new, "\n") {
				want = lineOf(broken, strings.TrimLeft(r.new, "\n"))
			}
		}
		fs := Check(r.file, []byte(broken), "t-abcd")
		ok := false
		for _, f := range fs {
			if f.Rule == r.rule && f.Line == want {
				ok = true
				if f.Allowed == "" || f.Problem == "" {
					t.Errorf("%s: finding without problem or allowed shape: %+v", r.rule, f)
				}
			}
		}
		if !ok {
			t.Errorf("%s (%q -> %q): want a finding on line %d, got %v", r.rule, r.old, r.new, want, fs)
		}
		covered[r.rule] = true
	}
	for _, r := range Rules {
		if !covered[r.ID] {
			t.Errorf("rule %s has no refusal case", r.ID)
		}
	}
}

// The user's picks (2026-11-24): a duplicate key names both lines; a body `status:` is not read; Tier ignores case and `*`.
func TestUserPicks(t *testing.T) {
	dup := strings.Replace(valid["ticket.md"], "status: open\n", "status: open\nstatus: closed\n", 1)
	fs := Check("ticket.md", []byte(dup), "t-abcd")
	if len(fs) != 1 || !strings.Contains(fs[0].Problem, "line 3") || fs[0].Line != 4 {
		t.Errorf("duplicate status: want one finding on line 4 naming line 3, got %v", fs)
	}
	body := strings.Replace(valid["ticket.md"], "status: open\n", "", 1) + "status: open\n"
	if fs := Check("ticket.md", []byte(body), "t-abcd"); len(fs) != 1 || fs[0].Rule != "ticket.status" {
		t.Errorf("a body status line must not count as the field: got %v", fs)
	}
	same := valid["eval-report.md"] + "graded-head: " + hex40 + "\n"
	if fs := Check("eval-report.md", []byte(same), ""); len(fs) != 0 {
		t.Errorf("graded-head repeated with the same value must be accepted (sprint sorts -u): got %v", fs)
	}
	// The strip is what makes a bold line a Tier line at all: a bold one with a bad word, or a second bold one, is refused.
	for _, l := range []string{"**Tier**: trivial-adjacent", "**Tier:** planned", "Tier: normal\n**Tier**: bugfix"} {
		p := strings.Replace(valid["plan.md"], "**Tier**: Normal.", l, 1)
		if fs := Check("plan.md", []byte(p), ""); len(fs) != 1 || fs[0].Rule != "plan.tier" {
			t.Errorf("%q: want one plan.tier finding, got %v", l, fs)
		}
	}
	for _, l := range []string{"Tier: normal", "**tier**: High-Risk | Risk: x", "TIER : bugfix.", "  Tier:trivial"} {
		p := strings.Replace(valid["plan.md"], "**Tier**: Normal.", l, 1)
		if fs := Check("plan.md", []byte(p), ""); len(fs) != 0 {
			t.Errorf("%q: want accepted, got %v", l, fs)
		}
	}
}

func TestProseIsNeverChecked(t *testing.T) {
	long := strings.Repeat("word ", 2000)
	extra := map[string]string{
		"ticket.md":       strings.Replace(valid["ticket.md"], "tags:", "worktree_preference: \"x\"\ngithub: 12\nfuture_key: anything at all\n  - an indented list item\ntags:", 1) + "\n## Any heading\n" + long + "\n",
		"acceptance.md":   valid["acceptance.md"] + "\n## Notes\n- [y not a box under Notes\n### Criteria\n_italic_ **bold** " + long + "\n",
		"plan.md":         valid["plan.md"] + "\n## Decisions\n- Tier: normal, high-risk or trivial-adjacent are words here\n" + long + "\n",
		"eval-report.md":  valid["eval-report.md"] + "\n## Per criterion\n- pass: a bullet, not a verdict line\n**Model:** in bold is prose\n" + long + "\n",
		"review-notes.md": valid["review-notes.md"] + "\n## Notes\nVerdict: anything\n" + long + "\n",
	}
	for name, body := range extra {
		if fs := Check(name, []byte(body), "t-abcd"); len(fs) != 0 {
			t.Errorf("%s: prose produced findings: %v", name, fs)
		}
	}
}

func TestLineEndingsAndBOM(t *testing.T) {
	for name, body := range valid {
		crlf := "\xef\xbb\xbf" + strings.ReplaceAll(body, "\n", "\r\n")
		if fs := Check(name, []byte(crlf), "t-abcd"); len(fs) != 0 {
			t.Errorf("%s with BOM + CRLF: %v", name, fs)
		}
	}
}

// Malformed input gives findings, never a panic, and every finding points at a real line.
func TestMalformedInputNeverPanics(t *testing.T) {
	shapes := []string{"", "\x00\x00\x00", "---", "---\n", "---\nid: t-", " ## Criteria \n- [ ] x", "   \n\t\n  ", "---\nstatus: \x00\n---", "## Verdict", "## Sign-off\nTier:", "| a", "|", "evaluator-run-id:", "graded-head:"}
	for _, name := range Files {
		for _, s := range shapes {
			n := len(lines([]byte(s)))
			for _, f := range Check(name, []byte(s), "t-abcd") {
				if f.Line < 1 || f.Line > n || f.Allowed == "" {
					t.Errorf("%s %q: bad finding %+v", name, s, f)
				}
			}
		}
	}
}

func TestValidateFolderAndFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "t-abcd")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if fs, n, err := Validate(dir); err != nil || n != 0 || len(fs) != 0 {
		t.Fatalf("empty folder: want 0 files ok, got %v %d %v", fs, n, err)
	}
	for name, body := range valid {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if fs, n, err := Validate(dir); err != nil || n != 5 || len(fs) != 0 {
		t.Fatalf("valid folder: got %v %d %v", fs, n, err)
	}
	bad := filepath.Join(dir, "ticket.md")
	if err := os.WriteFile(bad, []byte(strings.Replace(valid["ticket.md"], "status: open", "status: done", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	fs, _, err := Validate(dir)
	if err != nil || len(fs) != 1 || fs[0].Path != bad || fs[0].String() != bad+":3: ticket.status: `status` is `done`; allowed: "+ruleByID["ticket.status"].Allowed {
		t.Fatalf("one bad field: got %v %v", fs, err)
	}
	if fs, n, err := Validate(bad); err != nil || n != 1 || len(fs) != 1 {
		t.Fatalf("one file: got %v %d %v", fs, n, err)
	}
	other := filepath.Join(dir, "summary.md")
	if err := os.WriteFile(other, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Validate(other); !errors.Is(err, ErrNotArtifact) {
		t.Fatalf("summary.md: want ErrNotArtifact, got %v", err)
	}
	if _, _, err := Validate(filepath.Join(dir, "nope")); err == nil {
		t.Fatal("a missing path must be an error")
	}
}

func TestValidateRefusesLinksAndHugeFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "t-abcd")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "elsewhere.md")
	if err := os.WriteFile(target, []byte(valid["plan.md"]), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "plan.md")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	if _, _, err := Validate(dir); err == nil || !strings.Contains(err.Error(), "not a regular file") {
		t.Fatalf("symlinked plan.md: want a refusal, got %v", err)
	}
	if err := os.Remove(filepath.Join(dir, "plan.md")); err != nil {
		t.Fatal(err)
	}
	huge := filepath.Join(dir, "eval-report.md")
	if err := os.WriteFile(huge, []byte(strings.Repeat("x", 5<<20)), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Validate(huge); err == nil || !strings.Contains(err.Error(), "cap") {
		t.Fatalf("5 MiB file: want the size refusal, got %v", err)
	}
}
