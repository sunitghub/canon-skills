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
	"sort"
	"strings"
	"testing"
	"time"

	"canon/internal/events"
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
		gf("2026-11-06T11:10:00.000Z", mac, one, "evaluator", "t-ffff", "unknown", "a0", "5", "0.5", ""),                  // a second evaluator model, listed before m1
		gf("2026-11-06T11:15:00.000Z", mac, one, "reviewer", "t-gggg", "unknown", "a0", "", "", ""),                       // a reviewer model that sorts before the evaluator's m1: role, then model
		giEv("2026-11-06T12:22:00.000Z", mac, one, "gate.rejected", "sprint", map[string]string{"ticket": "t-aaaa", "role": "evaluator", "reason": "unverified_run"}),
		giEv("2026-11-06T12:23:00.000Z", mac, one, "gate.rejected", "sprint", map[string]string{"ticket": "t-aaaa", "role": "reviewer", "reason": "review_shape"}),
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
	if r.Events != 23 || r.DaysRead != 4 {
		t.Fatalf("events %d days %d, want 23 and 4", r.Events, r.DaysRead)
	}
	if len(r.Groups) != 4 {
		t.Fatalf("groups = %d, want 4 (one/mac, one/vm, two/mac, the hostile one)", len(r.Groups))
	}
	g := giGroupOf(t, r, "/p/one", "mac")
	// evaluator m1: 4 runs (the unknown one counts as a run), 2.5+3.5+1 min, 1000+2000+500 tokens; reviewer m2: 2 runs, 1 min, 100 tokens
	// plus evaluator a0 (1 run, 0.5 min, 5 tokens) and reviewer a0 (1 run): sorted by role, then model
	if len(g.Runs) != 4 || g.Runs[0] != (giRun{"evaluator", "a0", 1, 0.5, 5}) || g.Runs[1] != (giRun{"evaluator", "m1", 4, 7, 3500}) || g.Runs[2] != (giRun{"reviewer", "a0", 1, 0, 0}) || g.Runs[3] != (giRun{"reviewer", "m2", 2, 1, 100}) {
		t.Errorf("runs = %+v", g.Runs)
	}
	// t-aaaa failed then passed, t-bbbb passed first time, t-cccc has no verdict: 1 of 2 tickets first pass, 1 retry
	if g.EvalTickets != 2 || g.EvalFirstPass != 1 || g.EvalRetries != 1 {
		t.Errorf("evaluator = %d tickets, %d first pass, %d retries", g.EvalTickets, g.EvalFirstPass, g.EvalRetries)
	}
	if g.Reviewer != (giReviewer{Yes: 1, No: 1, Unknown: 1, ActOnRecorded: 1, ActOn: 2}) {
		t.Errorf("reviewer = %+v", g.Reviewer)
	}
	// t-aaaa suite twice (a rerun, one failing) and mutant-sweep once: 3 stamps, 170 s
	if g.Evidence != (giEvidence{Stamps: 3, Reruns: 1, Failing: 1, Seconds: 170}) {
		t.Errorf("evidence = %+v", g.Evidence)
	}
	if g.Rejected["evaluator stale_evidence"] != 2 || g.Rejected["evaluator unverified_run"] != 1 || g.Rejected["reviewer review_shape"] != 1 || len(g.Rejected) != 3 {
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
	if !strings.Contains(out, "act_on items: 2 (recorded on 1 of 3 runs)") {
		t.Errorf("a partly recorded project must say how many runs carry it:\n%s", out)
	}
	if !strings.Contains(out, "evaluator first pass: 1 of 2 tickets (50%); retries: 1") || !strings.Contains(out, "evidence stamps: 3 (1 reruns, 1 failing), 170 s") {
		t.Errorf("text lacks the first-pass or evidence line:\n%s", out)
	}
	for _, bad := range []string{" verified", "authenticated"} { // not the reason word `unverified_run`
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
	if b.String() != "gate insights, last 30 days (2026-10-09 to 2026-11-08): as recorded in the activity log\nno events in this window\n" {
		t.Errorf("an empty log must say so and print nothing else:\n%s", b.String())
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

var giFixedNow = time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)

// the whole text of the seeded log, once: formats, order (project, host, role, model), the no-host and no-reviewer shapes
func TestGateInsightsTextOfTheSeededLog(t *testing.T) {
	home := giHome(t)
	want := `gate insights, last 30 days (2026-10-09 to 2026-11-08): as recorded in the activity log
days read: 4 (4 unsealed); events: 23

/p/one on mac
  evaluator a0                         1 runs     0.5 min          5 tokens
  evaluator m1                         4 runs     7.0 min       3500 tokens
  reviewer  a0                         1 runs     0.0 min          0 tokens
  reviewer  m2                         2 runs     1.0 min        100 tokens
  evaluator first pass: 1 of 2 tickets (50%); retries: 1
  reviewer: YES 1, NO 1, no verdict 1; act_on items: 2 (recorded on 1 of 3 runs)
  evidence stamps: 3 (1 reruns, 1 failing), 170 s
  rejected evaluator stale_evidence: 2
  rejected evaluator unverified_run: 1
  rejected reviewer review_shape: 1
  budget exceeded: 3 file-days (5 events)

/p/one on vm
  evaluator m1                         1 runs     0.5 min         10 tokens
  evaluator first pass: 1 of 1 tickets (100%); retries: 0

/p/three [31m on h [2Jx z
  evaluator m [2Jodel                  1 runs     1.0 min          1 tokens
  evaluator first pass: 1 of 1 tickets (100%); retries: 0

/p/two on mac
  reviewer  m2                         1 runs     0.5 min          7 tokens
  reviewer: YES 1, NO 0, no verdict 0; act_on: not recorded
`
	for i := 0; i < 20; i++ { // Go randomises map order: an unsorted report would differ in some run
		var b bytes.Buffer
		giText(gateInsights(home, 30, giFixedNow), &b)
		if b.String() != want {
			t.Fatalf("run %d: text differs:\n%s\nwant:\n%s", i, b.String(), want)
		}
	}
}

// numbers the report must refuse or read strictly: partial and not-run are evaluator verdicts, an unnamed reviewer verdict is "no verdict",
// act_on 0 is recorded (not absent), a negative or non-numeric value is ignored, and a line with no host reads "(no host recorded)"
func TestGateInsightsStrictReading(t *testing.T) {
	home := t.TempDir()
	ev := func(ts, kind, source string, data map[string]string) string {
		return giEv(ts, "", "/p/x", kind, source, data)
	}
	gcWrite(t, filepath.Join(home, "events", "2026-11-08.jsonl"), strings.Join([]string{
		ev("2026-11-08T01:00:00.000Z", "gate.finished", "subagent-log", map[string]string{"role": "evaluator", "ticket": "t-aaaa", "verdict": "partial", "model": "m", "minutes": "-5", "tokens": "x"}),
		ev("2026-11-08T02:00:00.000Z", "gate.finished", "subagent-log", map[string]string{"role": "evaluator", "ticket": "t-bbbb", "verdict": "not-run", "model": "m", "minutes": "0", "tokens": "-9"}),
		ev("2026-11-08T03:00:00.000Z", "gate.finished", "subagent-log", map[string]string{"role": "reviewer", "ticket": "t-aaaa", "verdict": "unknown", "model": "m", "act_on": "0"}),
		ev("2026-11-08T04:00:00.000Z", "gate.finished", "subagent-log", map[string]string{"role": "reviewer", "ticket": "t-bbbb", "verdict": "NO", "model": "m", "act_on": "-1"}),
		ev("2026-11-08T05:00:00.000Z", "gate.finished", "subagent-log", map[string]string{"role": "reviewer", "ticket": "t-cccc", "verdict": "NO", "model": "m", "act_on": "many"}),
		ev("2026-11-08T06:00:00.000Z", "evidence.stamped", "evidence", map[string]string{"ticket": "t-aaaa", "name": "suite", "exit": "0", "seconds": "-3"}),
	}, ""))
	r := gateInsights(home, 30, giFixedNow)
	if len(r.Groups) != 1 {
		t.Fatalf("groups = %+v", r.Groups)
	}
	g := r.Groups[0]
	if g.Host != "" || g.EvalTickets != 2 || g.EvalFirstPass != 0 || g.EvalRetries != 0 {
		t.Errorf("evaluator = %+v", g)
	}
	if g.Runs[0].Minutes != 0 || g.Runs[0].Tokens != 0 || g.Runs[0].Runs != 2 {
		t.Errorf("a negative or non-numeric minutes/tokens must add nothing: %+v", g.Runs[0])
	}
	if g.Reviewer != (giReviewer{No: 2, Unknown: 1, ActOnRecorded: 1, ActOn: 0}) {
		t.Errorf("reviewer = %+v (act_on 0 recorded; -1 and 'many' ignored)", g.Reviewer)
	}
	if g.Evidence.Seconds != 0 || g.Evidence.Stamps != 1 {
		t.Errorf("a negative seconds must add nothing: %+v", g.Evidence)
	}
	var b bytes.Buffer
	giText(r, &b)
	for _, want := range []string{"/p/x on (no host recorded)", "act_on items: 0 (recorded on 1 of 3 runs)", "no verdict 1", "evaluator first pass: 0 of 2 tickets (0%); retries: 0"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("text lacks %q:\n%s", want, b.String())
		}
	}
}

// the seal word for each day read: sealed and intact, inside the grace period (unsealed), broken, and "not checked" when the seals cannot be read
func TestGateInsightsSealState(t *testing.T) {
	home := giHome(t)
	if n, err := events.Seal(home, giFixedNow); err != nil || n != 3 {
		t.Fatalf("seal: %d days, %v (want 11-05, 11-06, 11-07 sealed; 11-08 is inside the grace hour rules of its own day)", n, err)
	}
	r := gateInsights(home, 30, giFixedNow)
	if r.DaysSealed["intact"] != 3 || r.DaysSealed["unsealed"] != 1 || len(r.DaysSealed) != 2 {
		t.Errorf("sealed log: %v", r.DaysSealed)
	}
	var b bytes.Buffer
	giText(r, &b)
	if !strings.Contains(b.String(), "days read: 4 (3 intact, 1 unsealed); events: 23") {
		t.Errorf("text:\n%s", b.String())
	}
	f, _ := os.OpenFile(filepath.Join(home, "events", "2026-11-06.jsonl"), os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString("tampered\n")
	f.Close()
	r = gateInsights(home, 30, giFixedNow)
	if r.DaysSealed["broken"] != 1 || r.DaysSealed["intact"] != 2 {
		t.Errorf("after an edit to a sealed day: %v", r.DaysSealed)
	}
	b.Reset()
	giText(r, &b)
	if !strings.Contains(b.String(), "days read: 4 (2 intact, 1 unsealed, 1 broken); events: 23") {
		t.Errorf("text:\n%s", b.String())
	}
	seals := filepath.Join(home, "events", "seals.jsonl")
	os.Remove(seals)
	if err := os.Mkdir(seals, 0o755); err != nil {
		t.Fatal(err)
	}
	r = gateInsights(home, 30, giFixedNow)
	if r.DaysSealed["not checked"] != 4 || len(r.DaysSealed) != 1 {
		t.Errorf("seals that cannot be read give no day a verdict: %v", r.DaysSealed)
	}
	b.Reset()
	giText(r, &b)
	if !strings.Contains(b.String(), "days read: 4 (4 not checked)") {
		t.Errorf("text:\n%s", b.String())
	}
}

func TestGateInsightsCLI(t *testing.T) {
	home := giHome(t)
	t.Setenv("CANON_HOME", home)
	giNow = func() time.Time { return giFixedNow }
	defer func() { giNow = time.Now }()
	var out, errb bytes.Buffer
	if rc := gateInsightsCLI([]string{"--json"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	var rep map[string]any
	if err := json.Unmarshal(out.Bytes(), &rep); err != nil {
		t.Fatal(err)
	}
	keys := func(m map[string]any) string {
		var k []string
		for x := range m {
			k = append(k, x)
		}
		sort.Strings(k)
		return strings.Join(k, ",")
	}
	if keys(rep) != "days,days_by_seal,days_read,events,groups,window" || rep["days"] != float64(30) || rep["window"] != "2026-10-09 to 2026-11-08" {
		t.Errorf("json top level: %s", out.String())
	}
	g := rep["groups"].([]any)[0].(map[string]any)
	if keys(g) != "budget_exceeded_events,budget_exceeded_file_days,evaluator_first_pass,evaluator_retries,evaluator_tickets,evidence,host,project,reviewer,rejected,runs" && keys(g) != "budget_exceeded_events,budget_exceeded_file_days,evaluator_first_pass,evaluator_retries,evaluator_tickets,evidence,host,project,rejected,reviewer,runs" {
		t.Errorf("json group keys: %s", keys(g))
	}
	if keys(g["reviewer"].(map[string]any)) != "act_on_runs_recorded,act_on_total,no,no_verdict,yes" || keys(g["evidence"].(map[string]any)) != "failing,reruns,seconds,stamps" ||
		keys(g["runs"].([]any)[0].(map[string]any)) != "minutes,model,role,runs,tokens" {
		t.Errorf("json nested keys: %s", out.String())
	}
	out.Reset()
	if rc := gateInsightsCLI([]string{"--days", "3650"}, &out, &errb); rc != 0 {
		t.Errorf("--days 3650 is the largest window: rc %d %s", rc, errb.String())
	}
	out.Reset()
	if rc := gateInsightsCLI([]string{"--days", "1"}, &out, &errb); rc != 0 || !strings.Contains(out.String(), "last 1 days") || !strings.Contains(out.String(), "events: 3") {
		t.Errorf("--days 1: rc %d\n%s", rc, out.String())
	}
	for _, args := range [][]string{{"--days", "0"}, {"--days", "3651"}, {"--days", "x"}, {"--days"}, {"--bogus"}} {
		errb.Reset()
		if rc := gateInsightsCLI(args, &out, &errb); rc != 2 || !strings.Contains(errb.String(), "usage: canon-go gate-insights") {
			t.Errorf("%v: rc %d, %q", args, rc, errb.String())
		}
	}
	// a canon home that cannot be read is an error, not an empty report
	locked := filepath.Join(t.TempDir(), "locked")
	os.Mkdir(locked, 0o755)
	t.Setenv("CANON_HOME", filepath.Join(locked, "home"))
	os.Chmod(locked, 0)
	defer os.Chmod(locked, 0o755)
	errb.Reset()
	if os.Geteuid() != 0 {
		if rc := gateInsightsCLI(nil, &out, &errb); rc != 1 || !strings.Contains(errb.String(), "cannot read the canon home") {
			t.Errorf("unreadable home: rc %d, %q", rc, errb.String())
		}
	}
}
