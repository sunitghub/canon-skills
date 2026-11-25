package walk

// Protects `sprint next` and `sprint approve`'s refusal (t-2bfe): which node is next, which earlier one was passed over,
// the ticket options and the project's off-list, and that unreadable input is exit 2, never "holds".

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const hex64 = "43d7c9469079310e0bfe31799a0170730f74a7137ad6882ac29f3d4849b2148e"

// row is one `resolve --full` line; on is "on" or "off".
func row(order, id, kind, on, skip, only, produces, note string) string {
	return rowWith(order, id, kind, on, skip, only, produces, note, "-")
}

func rowWith(order, id, kind, on, skip, only, produces, note, with string) string {
	return strings.Join([]string{order, id, kind, on, "open", "-", "-", "p/" + id + ".md", "-", skip, only, produces, note, with}, "\t")
}

// gate is a close node whose output is its own Wrapup Gates row.
func gate(order, id, skip, with string) string {
	return rowWith(order, id, "gate", "on", skip, "-", "acceptance.wrapup-row", "row "+id, with)
}

// pipe is canon's default (pipeline.yaml) in short, with the spec check on or off.
func pipe(spec string) string {
	return strings.Join([]string{
		row("10", "start", "step", "on", "-", "-", "-", "-"),
		row("20", "plan", "step", "on", "-", "-", "-", "-"),
		row("25", "spec-check", "agent", spec, "lite", "-", "spec.verdict", "run the spec check for <id>"),
		row("30", "approve-plan", "you", "on", "-", "-", "plan.approved-stamp", "run sprint approve <id>"),
		row("40", "build", "step", "on", "-", "-", "-", "-"),
		row("45", "your-test", "you", "on", "-", "manual", "-", "-"),
		gate("50", "code-simplifier", "lite", "-"),
		gate("54", "doc-audit", "lite", "-"),
		gate("60", "skill-eval", "lite", "reviewer"),
		row("70", "reviewer", "agent", "on", "lite,manual", "-", "review.done", "dispatch the reviewer"),
		gate("80", "security-review", "-", "-"),
		gate("90", "mutation-test", "lite,manual", "-"),
		row("95", "test-stamp", "step", "on", "manual", "-", "evidence.test-sh", "stamp the full suite"),
		row("100", "eval", "agent", "on", "-", "-", "eval.verdict", "dispatch the evaluator"),
		row("110", "close", "step", "on", "-", "-", "-", "-"),
	}, "\n") + "\n"
}

const (
	ticketMD = "---\nid: t-abcd\nstatus: in_progress\ntype: task\npriority: 1\n---\n# t\n"
	specMD   = "# Spec check: t-abcd\n\n## Verdict\nREADY — no gap\n"
	reviewMD = "# Review Notes\n\n## Verdict\nYES — fine\n"
	evalMD   = "evaluator-run-id: 1795556751-20092\ngraded-head: 0123456789abcdef0123456789abcdef01234567\nModel: sonnet\n\npass: proven\n"
	planMD   = "# Plan\n\n## Sign-off\nTier: normal | Risk: low\n- [x] Plan approved\nApproved: sha256:" + hex64 + " 2026-11-25T10:00:00Z\n\n## Approach\nx\n"
)

func ticket(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "t-abcd")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for n, b := range files {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(b), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func run(dir, stdin string, args ...string) (string, int) {
	var out, errb bytes.Buffer
	code := Run(append([]string{dir}, args...), strings.NewReader(stdin), &out, &errb)
	return out.String() + errb.String(), code
}

func TestWalk(t *testing.T) {
	lite := strings.Replace(ticketMD, "priority: 1\n", "priority: 1\ndemo: true\n", 1)
	manual := strings.Replace(ticketMD, "priority: 1\n", "priority: 1\nmanual: true\n", 1)
	cases := []struct {
		name  string
		files map[string]string
		spec  string
		want  string
	}{
		{"fresh", map[string]string{"ticket.md": ticketMD}, "on",
			"next: spec-check (agent) — run the spec check for t-abcd\n"},
		{"spec done", map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD}, "on",
			"next: approve-plan (you) — run sprint approve t-abcd\n"},
		{"approved", map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD, "plan.md": planMD}, "on",
			"next: build (step) — p/build.md\nthen: code-simplifier (gate) — row code-simplifier\n"},
		{"approved, spec skipped", map[string]string{"ticket.md": ticketMD, "plan.md": planMD}, "on",
			"missed: spec-check — run the spec check for t-abcd\nnext: build (step) — p/build.md\nthen: code-simplifier (gate) — row code-simplifier\n"},
		{"ticked box, no pin", map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD,
			"plan.md": strings.Replace(planMD, "Approved: sha256:"+hex64+" 2026-11-25T10:00:00Z\n", "", 1)}, "on",
			"next: approve-plan (you) — run sprint approve t-abcd\n"},
		{"lite fresh", map[string]string{"ticket.md": lite}, "on",
			"next: approve-plan (you) — run sprint approve t-abcd\n"},
		{"project off", map[string]string{"ticket.md": ticketMD}, "off",
			"next: approve-plan (you) — run sprint approve t-abcd\n"},
		{"manual approved", map[string]string{"ticket.md": manual, "spec-review.md": specMD, "plan.md": planMD}, "on",
			"next: build (step) — p/build.md\nthen: code-simplifier (gate) — row code-simplifier\n"},
		{"wrapup started", map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD, "plan.md": planMD, "acceptance.md": acc("code-simplifier")}, "on",
			"next: doc-audit (gate) — row doc-audit\n"},
		{"reviewer done, skill-eval row missing", map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD, "plan.md": planMD,
			"acceptance.md": acc("code-simplifier", "doc-audit"), "review-notes.md": reviewMD}, "on",
			"missed: skill-eval — row skill-eval\nnext: security-review (gate) — row security-review\n"},
		{"evaluator ran before security-review (t-6x4z 8:07)", map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD, "plan.md": planMD,
			"acceptance.md": acc("code-simplifier", "doc-audit", "skill-eval"), "review-notes.md": reviewMD, "eval-report.md": evalMD}, "on",
			"missed: security-review — row security-review\nmissed: mutation-test — row mutation-test\nmissed: test-stamp — stamp the full suite\nnext: close (step) — p/close.md\n"},
		{"lite: no reviewer, no sweep", map[string]string{"ticket.md": lite, "plan.md": planMD, "acceptance.md": acc("security-review")}, "on",
			"next: test-stamp (step) — stamp the full suite\n"},
		{"manual: no reviewer, sweep or stamp", map[string]string{"ticket.md": manual, "spec-review.md": specMD, "plan.md": planMD,
			"acceptance.md": acc("code-simplifier", "doc-audit", "skill-eval", "security-review")}, "on",
			"next: eval (agent) — dispatch the evaluator\n"},
	}
	for _, c := range cases {
		got, code := run(ticket(t, c.files), pipe(c.spec))
		if code != 0 || got != c.want {
			t.Errorf("%s: exit %d\n got %q\nwant %q", c.name, code, got, c.want)
		}
	}
}

// acc is an acceptance.md whose Wrapup Gates table has a ran row for each node.
func acc(nodes ...string) string {
	s := "# Acceptance\n\n## Criteria\n- [ ] x\n\n## Test Plan\n- [ ] x\n\n## QA\n- [ ] x\n\n## Wrapup Gates\n| Gate | Status | Notes |\n|---|---|---|\n"
	for _, n := range nodes {
		s += "| " + n + " | ran | done |\n"
	}
	return s
}

// --at reviewer / eval is what `sprint gate-prompt` runs (t-a4e8): the reviewer waits for the wrapup rows but not for the
// nodes dispatched with it (skill-eval), the evaluator waits for every earlier ON node, the stamp from --evidence only.
func TestAtClose(t *testing.T) {
	base := map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD, "plan.md": planMD}
	with := func(extra map[string]string) map[string]string {
		m := map[string]string{}
		for k, v := range base {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	all := acc("code-simplifier", "doc-audit", "skill-eval", "security-review", "mutation-test")
	bugfix := strings.Replace(planMD, "Tier: normal", "Tier: bugfix", 1)
	cases := []struct {
		name  string
		files map[string]string
		args  []string
		code  int
		want  string
	}{
		{"reviewer: doc-audit row missing", with(map[string]string{"acceptance.md": acc("code-simplifier")}), []string{"--at", "reviewer"}, 1, "missed: doc-audit — row doc-audit\n"},
		{"reviewer: skill-eval goes with it", with(map[string]string{"acceptance.md": acc("code-simplifier", "doc-audit")}), []string{"--at", "reviewer"}, 0, ""},
		{"eval: skill-eval row missing", with(map[string]string{"acceptance.md": acc("code-simplifier", "doc-audit", "security-review", "mutation-test"), "review-notes.md": reviewMD}),
			[]string{"--at", "eval", "--evidence", "test-sh"}, 1, "missed: skill-eval — row skill-eval\n"},
		{"eval: no stamp", with(map[string]string{"acceptance.md": all, "review-notes.md": reviewMD}), []string{"--at", "eval", "--evidence", "pre-gate,mutant-sweep"}, 1, "missed: test-stamp — stamp the full suite\n"},
		{"eval: no review, no security-review", with(map[string]string{"acceptance.md": acc("code-simplifier", "doc-audit", "skill-eval", "mutation-test")}),
			[]string{"--evidence", "test-sh", "--at", "eval"}, 1, "missed: reviewer — dispatch the reviewer\nmissed: security-review — row security-review\n"},
		{"eval: all hold", with(map[string]string{"acceptance.md": all, "review-notes.md": reviewMD}), []string{"--at", "eval", "--evidence", "test-sh"}, 0, ""},
		{"eval: bugfix needs no review", with(map[string]string{"acceptance.md": all, "plan.md": bugfix}), []string{"--at", "eval", "--evidence", "test-sh"}, 0, ""},
	}
	for _, c := range cases {
		got, code := run(ticket(t, c.files), pipe("on"), c.args...)
		if code != c.code || got != c.want {
			t.Errorf("%s: exit %d %q, want %d %q", c.name, code, got, c.code, c.want)
		}
	}
	lite := with(map[string]string{"ticket.md": strings.Replace(ticketMD, "priority: 1\n", "priority: 1\ndemo: true\n", 1)})
	if got, code := run(ticket(t, lite), pipe("on"), "--at", "reviewer"); code != 2 || !strings.Contains(got, "not ON") {
		t.Errorf("reviewer on a Lite ticket: exit %d %q, want 2 naming it not ON", code, got)
	}
}

// --at is what `sprint approve` runs: 1 and the missed line while an earlier ON node's produces fails.
func TestAt(t *testing.T) {
	lite := strings.Replace(ticketMD, "priority: 1\n", "priority: 1\ndemo: true\n", 1)
	cases := []struct {
		name  string
		files map[string]string
		spec  string
		code  int
		want  string
	}{
		{"no spec check", map[string]string{"ticket.md": ticketMD}, "on", 1, "missed: spec-check — run the spec check for t-abcd\n"},
		{"template verdict", map[string]string{"ticket.md": ticketMD, "spec-review.md": strings.Replace(specMD, "READY — no gap", "READY | GAPS — <one sentence>", 1)}, "on", 1, "missed: spec-check — run the spec check for t-abcd\n"},
		{"spec check done", map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD}, "on", 0, ""},
		{"lite", map[string]string{"ticket.md": lite}, "on", 0, ""},
		{"project off", map[string]string{"ticket.md": ticketMD}, "off", 0, ""},
	}
	for _, c := range cases {
		got, code := run(ticket(t, c.files), pipe(c.spec), "--at", "approve-plan")
		if code != c.code || got != c.want {
			t.Errorf("%s: exit %d %q, want %d %q", c.name, code, got, c.code, c.want)
		}
	}
}

// Anything the walker cannot read is exit 2: a failed resolve or a guessed option must never pass approve.
func TestUnreadableIsExit2(t *testing.T) {
	ok := map[string]string{"ticket.md": ticketMD}
	cases := []struct {
		name, stdin string
		files       map[string]string
		args        []string
	}{
		{"empty stdin", "", ok, nil},
		{"short row", "10\tstart\tstep\ton\tlocked\t-\t-\t-\tr\t-\t-\n", ok, nil},
		{"bad order", strings.Replace(pipe("on"), "10\tstart", "x\tstart", 1), ok, nil},
		{"bad on", strings.Replace(pipe("on"), "\tagent\ton\t", "\tagent\tmaybe\t", 1), ok, nil},
		{"unknown rule", strings.Replace(pipe("on"), "spec.verdict", "review.verdict", 1), ok, nil},
		{"unknown skip_on", strings.Replace(pipe("on"), "\tlite\t", "\tfast\t", 1), ok, nil},
		{"unknown only", strings.Replace(pipe("on"), "\tmanual\t", "\tdemo\t", 1), ok, nil},
		{"no ticket.md", pipe("on"), map[string]string{}, nil},
		{"no frontmatter", pipe("on"), map[string]string{"ticket.md": "# t\n"}, nil},
		{"demo: yes", pipe("on"), map[string]string{"ticket.md": strings.Replace(ticketMD, "priority: 1\n", "priority: 1\ndemo: yes\n", 1)}, nil},
		{"demo twice", pipe("on"), map[string]string{"ticket.md": strings.Replace(ticketMD, "priority: 1\n", "priority: 1\ndemo: false\ndemo: true\n", 1)}, nil},
		{"--at a node that is off", pipe("off"), ok, []string{"--at", "spec-check"}},
		{"--at bad id", pipe("on"), ok, []string{"--at", "Bad"}},
		{"extra arg", pipe("on"), ok, []string{"x"}},
		{"--at twice", pipe("on"), ok, []string{"--at", "eval", "--at", "eval"}},
		{"--evidence bad name", pipe("on"), ok, []string{"--evidence", "Test sh"}},
		{"--evidence empty", pipe("on"), ok, []string{"--evidence", ""}},
		{"--evidence no value", pipe("on"), ok, []string{"--at", "eval", "--evidence"}},
		{"--evidence trailing junk", pipe("on"), ok, []string{"--evidence", "test-sh;x"}},
		{"--evidence over the cap", pipe("on"), ok, []string{"--evidence", strings.Repeat("a", 4097)}},
		{"unknown flag", pipe("on"), ok, []string{"--bogus", "test-sh"}},
		{"bad with", strings.Replace(pipe("on"), "\treviewer\n", "\tReviewer\n", 1), ok, nil},
	}
	for _, c := range cases {
		runs := [][]string{nil, {"--at", "approve-plan"}}
		if c.args != nil {
			runs = [][]string{c.args}
		}
		for _, args := range runs {
			got, code := run(ticket(t, c.files), c.stdin, args...)
			if code != 2 || strings.Contains(got, "next:") {
				t.Errorf("%s %v: exit %d %q, want 2 and no next line", c.name, args, code, got)
			}
		}
	}
	dir := ticket(t, map[string]string{"ticket.md": ticketMD})
	target := filepath.Join(t.TempDir(), "spec.md")
	if err := os.WriteFile(target, []byte(specMD), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "spec-review.md")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	if got, code := run(dir, pipe("on"), "--at", "approve-plan"); code != 2 {
		t.Errorf("a linked spec-review.md: exit %d %q, want 2", code, got)
	}
}

// A bad argument shape names the usage, and a flag never stands in for the ticket dir; --evidence at the cap is still read.
func TestArgShapes(t *testing.T) {
	dir := ticket(t, map[string]string{"ticket.md": ticketMD})
	for _, args := range [][]string{{dir, "--bogus", "x"}, {"--evidence", "test-sh", "x"}, {"-x"}} {
		var out, errb bytes.Buffer
		if code := Run(args, strings.NewReader(pipe("on")), &out, &errb); code != 2 || !strings.HasPrefix(errb.String(), "usage: canon-go walk <ticket dir>") {
			t.Errorf("%v: exit %d %q, want 2 and the usage line", args, code, errb.String())
		}
	}
	if got, code := run(dir, pipe("on"), "--evidence", strings.Repeat("a", 4096)); code != 0 || !strings.Contains(got, "next:") {
		t.Errorf("--evidence at the cap: exit %d %q, want 0 and a next line", code, got)
	}
}

// canon's own default parses: each `produces:` in pipeline.yaml is a rule the walker knows (tools/pipeline.sh is the reader).
func TestCanonDefaultParses(t *testing.T) {
	sh, err := filepath.Abs("../../../pipeline.sh")
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("bash", sh, "resolve", "--full").Output()
	if err != nil {
		t.Fatalf("pipeline.sh resolve --full: %v", err)
	}
	nodes, err := Parse(bytes.NewReader(out))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, n := range nodes {
		got[n.ID] = n.Produces
	}
	want := map[string]string{"start": "-", "plan": "-", "spec-check": "spec.verdict", "approve-plan": "plan.approved-stamp", "build": "-",
		"code-simplifier": "acceptance.wrapup-row", "code-reviewer": "acceptance.wrapup-row", "doc-audit": "acceptance.wrapup-row",
		"skill-eval": "acceptance.wrapup-row", "break-it": "acceptance.wrapup-row", "reviewer": "review.done",
		"security-review": "acceptance.wrapup-row", "mutation-test": "acceptance.wrapup-row", "test-stamp": "evidence.test-sh",
		"eval": "eval.verdict", "close": "-"}
	for id, p := range want {
		if got[id] != p {
			t.Errorf("canon's default: %s produces %q, want %q", id, got[id], p)
		}
	}
}

// --at reads only the nodes before its own: a linked plan.md (approve's own output) is not approve's business.
func TestAtReadsOnlyEarlierNodes(t *testing.T) {
	dir := ticket(t, map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD})
	target := filepath.Join(t.TempDir(), "plan.md")
	if err := os.WriteFile(target, []byte(planMD), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "plan.md")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	if got, code := run(dir, pipe("on"), "--at", "approve-plan"); code != 0 || got != "" {
		t.Fatalf("exit %d %q, want 0 and nothing", code, got)
	}
	if got, code := run(dir, pipe("on")); code != 2 {
		t.Fatalf("a full walk reads plan.md: exit %d %q, want 2", code, got)
	}
}

// The ticket's options decide which nodes are ON (Lite skips spec-check, Manual adds your-test); slice 1's output stops at the
// build, so a Manual ticket is checked here, where its option is read and applied (mutation sweep, t-2bfe close).
func TestOptionsDecideActive(t *testing.T) {
	manual := strings.Replace(ticketMD, "priority: 1\n", "priority: 1\nmanual: true\n", 1)
	tk, err := ReadTicket(ticket(t, map[string]string{"ticket.md": manual}))
	if err != nil || tk != (Ticket{Manual: true}) {
		t.Fatalf("manual: true read as %+v, %v", tk, err)
	}
	if _, err := ReadTicket(ticket(t, map[string]string{"ticket.md": strings.Replace(ticketMD, "priority: 1\n", "priority: 1\nmanual: yes\n", 1)})); err == nil {
		t.Error("manual: yes was read, want an error (a guess could switch a node on or off)")
	}
	yourTest := Node{ID: "your-test", On: "on", SkipOn: "-", Only: "manual"}
	skipManual := Node{ID: "x", On: "on", SkipOn: "lite,manual", Only: "-"}
	cases := []struct {
		name string
		n    Node
		t    Ticket
		want bool
	}{
		{"only manual, manual ticket", yourTest, Ticket{Manual: true}, true},
		{"only manual, plain ticket", yourTest, Ticket{}, false},
		{"skip_on manual, manual ticket", skipManual, Ticket{Manual: true}, false},
		{"skip_on manual, plain ticket", skipManual, Ticket{}, true},
	}
	for _, c := range cases {
		if got, err := Active(c.n, c.t); err != nil || got != c.want {
			t.Errorf("%s: %v, %v; want %v", c.name, got, err, c.want)
		}
	}
}

// When every ON node the walk reaches holds and none follows, there is no next node: an error (exit 2), never a guess.
func TestNothingAfterTheLastHoldingNode(t *testing.T) {
	stdin := strings.Join(strings.Split(pipe("on"), "\n")[2:4], "\n") + "\n" // spec-check, approve-plan only
	got, code := run(ticket(t, map[string]string{"ticket.md": ticketMD, "spec-review.md": specMD, "plan.md": planMD}), stdin)
	if code != 2 || !strings.Contains(got, "no ON node after the last one that holds") {
		t.Errorf("exit %d %q, want 2 and the no-next-node error", code, got)
	}
}
