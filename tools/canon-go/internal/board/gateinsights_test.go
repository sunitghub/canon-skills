package board

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Protects `canon-go gate-insights` (t-9113), the report on the activity log: every number of a seeded log equals a hand count, a machine
// is never blended with another, a log with no act_on says "not recorded", hostile values print as plain capped text, and a run writes nothing.

var giN int

// giEv is one valid v1 event line (16-char id, a source and fields the schema allows).
func giEv(ts, host, project, kind, source string, data map[string]string) string {
	giN++
	b, err := json.Marshal(map[string]any{"schema": 1, "id": fmt.Sprintf("%016x", giN), "ts": ts, "kind": kind, "source": source, "host": host, "project": project, "data": data})
	if err != nil {
		panic(err)
	}
	return string(b) + "\n"
}

func giHome(t *testing.T) string {
	home := t.TempDir()
	d := func(name string, lines ...string) {
		gcWrite(t, filepath.Join(home, "events", name+".jsonl"), strings.Join(lines, ""))
	}
	gf := func(ts, host, project, role, ticket, verdict, model, tokens, minutes, actOn string) string {
		m := map[string]string{"role": role, "ticket": ticket, "verdict": verdict, "model": model, "tokens": tokens, "minutes": minutes}
		if actOn != "" {
			m["act_on"] = actOn
		}
		return giEv(ts, host, project, "gate.finished", "subagent-log", m)
	}
	st := func(ts, host, project, ticket, name, exit, secs string) string {
		return giEv(ts, host, project, "evidence.stamped", "evidence", map[string]string{"ticket": ticket, "name": name, "exit": exit, "seconds": secs})
	}
	be := func(ts, host, project, capName string) string {
		return giEv(ts, host, project, "budget.exceeded", "sprint", map[string]string{"ticket": "t-aaaa", "cap": capName})
	}
	one, mac, vm := "/p/one", "mac", "vm"
	d("2026-11-05",
		gf("2026-11-05T10:00:00.000Z", mac, one, "evaluator", "t-aaaa", "fail", "m1", "1000", "2.5", ""),
		st("2026-11-05T10:05:00.000Z", mac, one, "t-aaaa", "suite", "0", "100"))
	d("2026-11-06",
		gf("2026-11-06T10:00:00.000Z", mac, one, "evaluator", "t-aaaa", "pass", "m1", "2000", "3.5", ""),
		gf("2026-11-06T10:10:00.000Z", mac, one, "evaluator", "t-bbbb", "pass", "m1", "500", "1", ""),
		gf("2026-11-06T10:20:00.000Z", mac, one, "evaluator", "t-cccc", "unknown", "m1", "", "", ""), // no verdict yet: not a pass or a fail
		gf("2026-11-06T11:00:00.000Z", mac, one, "reviewer", "t-aaaa", "NO", "m2", "100", "1", "2"),
		gf("2026-11-06T11:05:00.000Z", mac, one, "reviewer", "t-bbbb", "YES", "m2", "", "", ""), // an older event: no act_on
		st("2026-11-06T12:00:00.000Z", mac, one, "t-aaaa", "suite", "1", "50"),                  // the same ticket and name again: a rerun
		st("2026-11-06T12:10:00.000Z", mac, one, "t-aaaa", "mutant-sweep", "0", "20"),
		giEv("2026-11-06T12:20:00.000Z", mac, one, "gate.rejected", "sprint", map[string]string{"ticket": "t-aaaa", "role": "evaluator", "reason": "stale_evidence"}),
		giEv("2026-11-06T12:19:00.000Z", mac, "/p/noise", "ticket.created", "tkt", map[string]string{"ticket": "t-zzzz"}), // not this report's kind: no group, not counted
		giEv("2026-11-06T12:21:00.000Z", mac, one, "gate.rejected", "sprint", map[string]string{"ticket": "t-aaaa", "role": "evaluator", "reason": "stale_evidence"}),
		gf("2026-11-06T13:00:00.000Z", vm, one, "evaluator", "t-aaaa", "pass", "m1", "10", "0.5", ""), // another machine: its own group
	)
	d("2026-11-07",
		be("2026-11-07T09:00:00.000Z", mac, one, "HANDOFF.md"), be("2026-11-07T09:01:00.000Z", mac, one, "HANDOFF.md"), be("2026-11-07T09:02:00.000Z", mac, one, "HANDOFF.md"),
		gf("2026-11-07T10:00:00.000Z", mac, "/p/two", "reviewer", "t-dddd", "YES", "m2", "7", "0.5", ""))
	d("2026-11-08",
		be("2026-11-08T09:00:00.000Z", mac, one, "HANDOFF.md"), be("2026-11-08T09:01:00.000Z", mac, one, "LEARNINGS.md"),
		gf("2026-11-08T10:00:00.000Z", "h\x1b[2Jx\nz", "/p/three\x1b[31m", "evaluator", "t-ee\x1b[0mee", "pass", "m\x1b[2Jodel", "1", "1", ""))
	return home
}

func giGroupOf(t *testing.T, r giReport, project, host string) giGroup {
	for _, g := range r.Groups {
		if g.Project == project && g.Host == host {
			return g
		}
	}
	t.Fatalf("no group %s on %s in %+v", project, host, r.Groups)
	return giGroup{}
}

func TestGateInsightsCountsEqualAHandCount(t *testing.T) {
	home := giHome(t)
	r := gateInsights(home, 30, time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC))
	if r.Events != 19 || r.DaysRead != 4 {
		t.Fatalf("events %d days %d, want 19 and 4", r.Events, r.DaysRead)
	}
	if len(r.Groups) != 4 {
		t.Fatalf("groups = %d, want 4 (one/mac, one/vm, two/mac, the hostile one)", len(r.Groups))
	}
	g := giGroupOf(t, r, "/p/one", "mac")
	// evaluator m1: 4 runs (the unknown one counts as a run), 2.5+3.5+1 min, 1000+2000+500 tokens; reviewer m2: 2 runs, 1 min, 100 tokens
	if len(g.Runs) != 2 || g.Runs[0] != (giRun{"evaluator", "m1", 4, 7, 3500}) || g.Runs[1] != (giRun{"reviewer", "m2", 2, 1, 100}) {
		t.Errorf("runs = %+v", g.Runs)
	}
	// t-aaaa failed then passed, t-bbbb passed first time, t-cccc has no verdict: 1 of 2 tickets first pass, 1 retry
	if g.EvalTickets != 2 || g.EvalFirstPass != 1 || g.EvalRetries != 1 {
		t.Errorf("evaluator = %d tickets, %d first pass, %d retries", g.EvalTickets, g.EvalFirstPass, g.EvalRetries)
	}
	if g.Reviewer != (giReviewer{Yes: 1, No: 1, ActOnRecorded: 1, ActOn: 2}) {
		t.Errorf("reviewer = %+v", g.Reviewer)
	}
	// t-aaaa suite twice (a rerun, one failing) and mutant-sweep once: 3 stamps, 170 s
	if g.Evidence != (giEvidence{Stamps: 3, Reruns: 1, Failing: 1, Seconds: 170}) {
		t.Errorf("evidence = %+v", g.Evidence)
	}
	if g.Rejected["evaluator stale_evidence"] != 2 || len(g.Rejected) != 1 {
		t.Errorf("rejected = %v", g.Rejected)
	}
	// HANDOFF.md 3 events on one day and 1 on the next, LEARNINGS.md 1: 5 events, 3 file-days
	if g.BudgetExceededEvents != 5 || g.BudgetExceededFileDays != 3 {
		t.Errorf("budget = %d events, %d file-days", g.BudgetExceededEvents, g.BudgetExceededFileDays)
	}
	vm := giGroupOf(t, r, "/p/one", "vm") // a Mac and a VM are never added together
	if vm.EvalTickets != 1 || vm.EvalFirstPass != 1 || vm.EvalRetries != 0 || len(vm.Runs) != 1 || vm.Runs[0].Minutes != 0.5 {
		t.Errorf("vm = %+v", vm)
	}
}

func TestGateInsightsNoActOnIsNotRecordedNotZero(t *testing.T) {
	home := giHome(t)
	r := gateInsights(home, 30, time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC))
	var b bytes.Buffer
	giText(r, &b)
	out := b.String()
	two := out[strings.Index(out, "/p/two on mac"):]
	if i := strings.Index(two, "\n\n"); i >= 0 { // the last group has no blank line after it
		two = two[:i+1]
	}
	if !strings.Contains(two, "act_on: not recorded") || strings.Contains(two, "act_on items") {
		t.Errorf("a project whose reviewer events have no act_on must say not recorded:\n%s", two)
	}
	if !strings.Contains(out, "act_on items: 2 (recorded on 1 of 2 runs)") {
		t.Errorf("a partly recorded project must say how many runs carry it:\n%s", out)
	}
	if !strings.Contains(out, "evaluator first pass: 1 of 2 tickets (50%); retries: 1") || !strings.Contains(out, "evidence stamps: 3 (1 reruns, 1 failing), 170 s") {
		t.Errorf("text lacks the first-pass or evidence line:\n%s", out)
	}
	for _, bad := range []string{"verified", "authenticated"} {
		if strings.Contains(out, bad) {
			t.Errorf("the report says %q; the log is recorded, never verified", bad)
		}
	}
}

func TestGateInsightsHostileValuesPrintAsPlainText(t *testing.T) {
	home := giHome(t)
	r := gateInsights(home, 30, time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC))
	var b bytes.Buffer
	giText(r, &b)
	for _, bad := range []string{"\x1b", "\r", "\x00"} {
		if strings.Contains(b.String(), bad) {
			t.Fatalf("the text carries %q:\n%q", bad, b.String())
		}
	}
	// a newline inside a host or project would start a fake line: every line is a known shape
	for _, ln := range strings.Split(strings.TrimSpace(b.String()), "\n") {
		if ln != "" && !strings.HasPrefix(ln, "gate insights") && !strings.HasPrefix(ln, "days read") && !strings.HasPrefix(ln, "  ") && !strings.Contains(ln, " on ") {
			t.Errorf("unexpected line %q", ln)
		}
	}
	if !strings.Contains(b.String(), "/p/three [31m on h [2Jx z") {
		t.Errorf("the hostile project and host were not neutralised in place:\n%s", b.String())
	}
}

func TestGateInsightsWindowAndEmpty(t *testing.T) {
	home := giHome(t)
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	r := gateInsights(home, 1, now) // 2026-11-07 12:00 on: only the 11-08 day's events
	if r.Events != 3 || r.DaysRead != 1 {
		t.Errorf("1 day window: events %d, days %d, want 3 and 1", r.Events, r.DaysRead)
	}
	var b bytes.Buffer
	giText(gateInsights(t.TempDir(), 30, now), &b)
	if !strings.Contains(b.String(), "no events in this window") {
		t.Errorf("an empty log must say so:\n%s", b.String())
	}
	var out, errb bytes.Buffer
	t.Setenv("CANON_HOME", t.TempDir())
	if rc := gateInsightsCLI([]string{"--days", "0"}, &out, &errb); rc != 2 || !strings.Contains(errb.String(), "usage:") {
		t.Errorf("--days 0: rc %d, %q", rc, errb.String())
	}
	if rc := gateInsightsCLI(nil, &out, &errb); rc != 0 || !strings.Contains(out.String(), "no events in this window") {
		t.Errorf("an empty home must exit 0 and say so: rc %d, %q", rc, out.String())
	}
}

func TestGateInsightsWritesNothing(t *testing.T) {
	home := giHome(t)
	before := giHashTree(t, home)
	gateInsights(home, 30, time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC))
	if after := giHashTree(t, home); after != before {
		t.Errorf("a report changed the canon home:\nbefore %s\nafter  %s", before, after)
	}
}

func giHashTree(t *testing.T, root string) string {
	h := sha256.New()
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		rel, _ := filepath.Rel(root, p)
		h.Write([]byte(rel + "\n"))
		if err == nil && d.Type().IsRegular() {
			b, _ := os.ReadFile(p)
			h.Write(b)
		}
		return nil
	})
	return hex.EncodeToString(h.Sum(nil))
}
