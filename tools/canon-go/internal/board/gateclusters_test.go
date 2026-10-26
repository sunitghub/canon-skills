package board

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Protects `sprint-check gate-clusters` (t-b874): the exact clusters of a fixture with 3 known causes, and the error lines
// and caps for untrusted logs.

func gcWrite(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func gcFixture(t *testing.T) (root, home string, now time.Time) {
	root, home = t.TempDir(), t.TempDir()
	now = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	run := func(ts, id, typ, ticket, outcome string) string {
		return `{"ts":"` + ts + `","agent_id":"` + id + `","agent_type":"` + typ + `","ticket":"` + ticket + `","outcome":"` + outcome + `"}` + "\n"
	}
	gcWrite(t, filepath.Join(root, ".claude/subagent-runs.jsonl"),
		run("2026-10-20T10:00:00Z", "a1", "evaluator", "t-aaaa", "fail")+
			run("2026-10-21T10:00:00Z", "a2", "evaluator", "t-bbbb", "fail")+
			run("2026-10-22T10:00:00Z", "a3", "evaluator", "t-cccc", "pass")+ // not a failure
			run("2026-10-22T11:00:00Z", "a4", "evaluator", "t-dddd", "budget")+ // seen once
			run("2026-01-01T10:00:00Z", "old", "evaluator", "t-aaaa", "fail")) // outside the window
	rep := "| # | Criterion | Verdict |\n|---|---|---|\n| 1 | Test plan item | pass |\n| 2 | Safe reading | fail |\n"
	gcWrite(t, filepath.Join(root, ".tickets/t-aaaa/eval-report.md"), rep)
	gcWrite(t, filepath.Join(root, ".tickets/t-bbbb/eval-report.md"), rep)
	ev := func(id, ts, ticket, reason string) string {
		return `{"schema":1,"id":"` + id + `","ts":"` + ts + `","kind":"gate.rejected","source":"sprint","project":"p","data":{"ticket":"` + ticket + `","role":"evaluator","reason":"` + reason + `"}}` + "\n"
	}
	gcWrite(t, filepath.Join(home, "events/2026-10-23.jsonl"),
		ev("e1", "2026-10-23T09:00:00Z", "t-eeee", "stale-eval")+
			ev("e2", "2026-10-23T10:00:00Z", "t-ffff", "stale-eval")+
			ev("e3", "2026-10-23T11:00:00Z", "t-aaaa", "stale-eval")+
			`{"schema":1,"id":"e4","ts":"2026-10-23T12:00:00Z","kind":"gate.started","source":"sprint","project":"p","data":{}}`+"\n")
	return
}

func TestGateClustersExact(t *testing.T) {
	root, home, now := gcFixture(t)
	r := gateClusters(root, home, 30, now)
	if len(r.Errors) != 0 || r.Unreadable != 0 {
		t.Fatalf("errors %v unreadable %d", r.Errors, r.Unreadable)
	}
	if len(r.Clusters) != 2 {
		t.Fatalf("clusters: %+v", r.Clusters)
	}
	c0, c1 := r.Clusters[0], r.Clusters[1]
	if c0.Cause != "rejected evaluator stale-eval" || c0.Count != 3 || strings.Join(c0.Runs, ",") != "e3,e2,e1" || strings.Join(c0.Tickets, ",") != "t-aaaa,t-ffff,t-eeee" {
		t.Errorf("c0: %+v", c0)
	}
	if c1.Cause != "evaluator fail: Safe reading" || c1.Count != 2 || strings.Join(c1.Runs, ",") != "a2,a1" || c1.Example != "evaluator fail: Safe reading t-bbbb" {
		t.Errorf("c1: %+v", c1)
	}
	if len(r.SeenOnce) != 1 || r.SeenOnce[0].Cause != "evaluator budget" || r.SeenOnce[0].Count != 1 {
		t.Errorf("seen once: %+v", r.SeenOnce)
	}
	var out bytes.Buffer
	gcText(r, &out)
	if !strings.Contains(out.String(), "3 x rejected evaluator stale-eval") || !strings.Contains(out.String(), "seen once (not a pattern):\n1 x evaluator budget") {
		t.Errorf("text:\n%s", out.String())
	}
	b, _ := json.Marshal(r)
	if !strings.Contains(string(b), `"seen_once":[{"cause":"evaluator budget"`) {
		t.Errorf("json: %s", b)
	}
}

func TestGateClustersReviewerNoAndEmpty(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	now := time.Now()
	gcWrite(t, filepath.Join(root, ".tickets/t-1111/review-notes.md"), "## Verdict\n\n**NO**\n")
	gcWrite(t, filepath.Join(root, ".tickets/t-2222/review-notes.md"), "## Verdict\n\nNO — x\n")
	gcWrite(t, filepath.Join(root, ".tickets/t-3333/review-notes.md"), "## Verdict\n\nYES\n")
	r := gateClusters(root, home, 30, now)
	if len(r.Clusters) != 1 || r.Clusters[0].Cause != "reviewer NO" || r.Clusters[0].Count != 2 {
		t.Fatalf("%+v", r)
	}
	empty := gateClusters(t.TempDir(), t.TempDir(), 7, now)
	var out bytes.Buffer
	gcText(empty, &out)
	if !strings.Contains(out.String(), "error: run log .claude/subagent-runs.jsonl: missing") || !strings.HasSuffix(out.String(), "no gate failures in the last 7 days\n") {
		t.Errorf("empty:\n%s", out.String())
	}
}

func TestGateClustersUntrustedInput(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	good := `{"ts":"2026-10-25T00:00:00Z","agent_id":"x1","agent_type":"evaluator","ticket":"t-aaaa","outcome":"fail"}` + "\n"
	gcWrite(t, filepath.Join(root, ".claude/subagent-runs.jsonl"), good+"{not json\n"+good)
	// a criterion title with control characters and a long tail is cleaned and capped
	gcWrite(t, filepath.Join(root, ".tickets/t-aaaa/eval-report.md"), "| 1 | Bad\x1b[31m title "+strings.Repeat("z", 300)+" | fail |\n")
	// a day file over the byte cap
	gcWrite(t, filepath.Join(home, "events/2026-10-25.jsonl"), strings.Repeat("x", 5<<20))
	r := gateClusters(root, home, 30, now)
	if r.Unreadable < 1 {
		t.Errorf("unreadable %d", r.Unreadable)
	}
	if len(r.Errors) != 1 || !strings.Contains(r.Errors[0], "larger than 4 MiB") {
		t.Errorf("errors %v", r.Errors)
	}
	if len(r.Clusters) != 1 {
		t.Fatalf("%+v", r.Clusters)
	}
	if ex := r.Clusters[0].Example; len(ex) > gcExampleMax || strings.ContainsRune(ex, 0x1b) {
		t.Errorf("example %q", ex)
	}
	var out bytes.Buffer
	gcText(r, &out)
	if !strings.Contains(out.String(), "unreadable lines") {
		t.Errorf("text:\n%s", out.String())
	}
}

func TestGateClustersCLIUsage(t *testing.T) {
	var o, e bytes.Buffer
	if gateClustersCLI([]string{"--days", "0"}, &o, &e) != 2 || gateClustersCLI([]string{"--bogus"}, &o, &e) != 2 {
		t.Error("bad args must exit 2")
	}
}
