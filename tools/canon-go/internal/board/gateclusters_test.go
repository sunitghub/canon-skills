package board

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
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
	good2 := strings.Replace(good, `"x1"`, `"x2"`, 1) // a second run, not the same one twice (one agent id is one run)
	gcWrite(t, filepath.Join(root, ".claude/subagent-runs.jsonl"), good+"{not json\n"+good2)
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

func TestGateClustersOutcomesAndNames(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	var b strings.Builder
	n := 0
	add := func(typ, ticket, outcome string) {
		n++
		b.WriteString(`{"ts":"2026-10-25T00:00:00Z","agent_id":"` + strings.Repeat("i", n) + `","agent_type":"` + typ + `","ticket":"` + ticket + `","outcome":"` + outcome + `"}` + "\n")
	}
	for _, o := range []string{"fail", "partial", "not-run", "budget"} {
		add("canon-evaluator", "t-aaaa", o)
		add("canon-evaluator", "t-bbbb", o)
	}
	add("evaluator", "t-aaaa", "pass")
	add("evaluator", "t-aaaa", "")
	add("Bad Type", "t-aaaa/../x", "fail")
	add("Bad Type", "T-AAAA", "fail")
	gcWrite(t, filepath.Join(root, ".claude/subagent-runs.jsonl"), b.String()+`{"ts":"bad","agent_type":"evaluator","outcome":"fail"}`+"\n")
	r := gateClusters(root, home, 30, now)
	got := map[string]int{}
	for _, c := range r.Clusters {
		got[c.Cause] = c.Count
		if c.Cause != "unknown fail" && len(c.Tickets) != 2 {
			t.Errorf("tickets %v", c.Tickets)
		}
	}
	want := map[string]int{"evaluator fail": 2, "evaluator partial": 2, "evaluator not-run": 2, "evaluator budget": 2, "unknown fail": 2}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: %d, want %d", k, got[k], v)
		}
	}
	for _, c := range r.Clusters {
		if c.Cause == "unknown fail" && (len(c.Tickets) != 0 || len(c.Runs) != 2) {
			t.Errorf("unknown: %+v", c)
		}
	}
	if len(r.SeenOnce) != 0 {
		t.Errorf("once: %+v", r.SeenOnce)
	}
}

func TestGateClustersOrderWindowAndCaps(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	ev := func(id, ts, reason string) string {
		return `{"id":"` + id + `","ts":"` + ts + `","kind":"gate.rejected","data":{"ticket":"t-aaaa","role":"reviewer","reason":"` + reason + `"}}` + "\n"
	}
	// "late" has 2 runs, "early" 2 runs but older, "many" 7 runs; an old day file and a wrong-type data value are ignored
	var many strings.Builder
	for i := 0; i < 7; i++ {
		many.WriteString(ev("m"+strconv.Itoa(i), "2026-10-24T0"+strconv.Itoa(i)+":00:00Z", "many"))
	}
	gcWrite(t, filepath.Join(home, "events/2026-10-24.jsonl"), many.String()+
		ev("l1", "2026-10-24T10:00:00Z", "late")+ev("l2", "2026-10-24T11:00:00Z", "late")+
		ev("e1", "2026-10-20T10:00:00Z", "early")+ev("e2", "2026-10-20T11:00:00Z", "early"))
	gcWrite(t, filepath.Join(home, "events/2026-09-01.jsonl"), ev("o1", "2026-09-01T10:00:00Z", "ancient")+ev("o2", "2026-09-01T10:00:01Z", "ancient"))
	gcWrite(t, filepath.Join(home, "events/notes.jsonl"), ev("x1", "2026-10-24T10:00:00Z", "ignored")+ev("x2", "2026-10-24T10:00:00Z", "ignored"))
	r := gateClusters(root, home, 30, now)
	var causes []string
	for _, c := range r.Clusters {
		causes = append(causes, c.Cause)
	}
	if strings.Join(causes, "|") != "rejected reviewer many|rejected reviewer late|rejected reviewer early" {
		t.Fatalf("order %v", causes)
	}
	var out bytes.Buffer
	gcText(r, &out)
	if !strings.Contains(out.String(), "7 x rejected reviewer many\n  tickets: t-aaaa\n  runs: m6 m5 m4 m3 m2 +2 more\n") {
		t.Errorf("text:\n%s", out.String())
	}
	if gcCapped(nil) != "-" || gcCapped([]string{"a", "b"}) != "a b" || gcCapped([]string{"1", "2", "3", "4", "5"}) != "1 2 3 4 5" {
		t.Error("gcCapped")
	}
	if got := gcClean("ab\x00cd\tef", 5); got != "ab cd" {
		t.Errorf("clean %q", got)
	}
	if gcID("a b") != "" || gcID(strings.Repeat("a", 65)) != "" || gcID(strings.Repeat("a", 64)) == "" || gcID("") != "" {
		t.Error("gcID")
	}
	if gcWord("Bad") != "unknown" || gcWord("ok-1") != "ok-1" || gcWord("a\nb") != "unknown" {
		t.Error("gcWord")
	}
}

func TestGateClustersFileKinds(t *testing.T) {
	d := t.TempDir()
	var un int
	seen := 0
	count := func([]byte) { seen++ }
	if e := gcLines(filepath.Join(d, "none"), "x", count, &un); e != "x: missing" {
		t.Errorf("missing: %q", e)
	}
	if e := gcLines(d, "x", count, &un); e != "x: not a regular file" {
		t.Errorf("dir: %q", e)
	}
	real := filepath.Join(d, "real")
	gcWrite(t, real, "a\n\n"+strings.Repeat("y", gcMaxLine+10)+"\nb")
	if e := gcLines(real, "x", count, &un); e != "" || seen != 2 || un != 1 {
		t.Errorf("real: %q seen %d unreadable %d", e, seen, un)
	}
	if err := os.Symlink(real, filepath.Join(d, "link")); err == nil {
		if e := gcLines(filepath.Join(d, "link"), "x", count, &un); e != "x: not a regular file" {
			t.Errorf("symlink: %q", e)
		}
	}
	for _, c := range []struct {
		notes string
		no    bool
	}{
		{"# n\n## Verdict\n\n**NO**\n", true},
		{"## Verdict\nNO — reasons\n", true},
		{"## Verdict\n\nYES\n", false},
		{"NO\n## Verdict\n\nYES\n", false},
		{"## Verdict\n", false},
	} {
		p := filepath.Join(d, "notes")
		gcWrite(t, p, c.notes)
		if gcReviewerNo(p) != c.no {
			t.Errorf("notes %q", c.notes)
		}
	}
	gcWrite(t, filepath.Join(d, "rep"), "| # | Criterion | Verdict |\n|---|---|---|\n| 1 | Okay | pass |\n| **2** | **Broken thing** | **fail** |\n| 3 | Later | fail |\n")
	if got := gcReportTitle(filepath.Join(d, "rep")); got != "Broken thing" {
		t.Errorf("title %q", got)
	}
	if gcReportTitle(filepath.Join(d, "nope")) != "" || gcReportTitle(d) != "" {
		t.Error("title of nothing")
	}
}

func TestGateClustersCLIRun(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("CANON_HOME", home)
	t.Chdir(root)
	day := time.Now().UTC().Format("2006-01-02")
	line := `{"id":"e","ts":"` + time.Now().UTC().Format(time.RFC3339) + `","kind":"gate.rejected","data":{"ticket":"t-aaaa","role":"evaluator","reason":"stale"}}` + "\n"
	gcWrite(t, filepath.Join(home, "events", day+".jsonl"), line+line)
	var o, e bytes.Buffer
	if code := gateClustersCLI([]string{"--days", "3650", "--json"}, &o, &e); code != 0 {
		t.Fatalf("code %d %s", code, e.String())
	}
	var rep gcReport
	if err := json.Unmarshal(o.Bytes(), &rep); err != nil || rep.Days != 3650 || len(rep.Clusters) != 1 || rep.Clusters[0].Count != 2 {
		t.Errorf("json %s (%v)", o.String(), err)
	}
	o.Reset()
	if code := gateClustersCLI(nil, &o, &e); code != 0 || !strings.HasPrefix(o.String(), "error: run log") || !strings.Contains(o.String(), "gate failure clusters, last 30 days\n2 x rejected evaluator stale") {
		t.Errorf("text %d:\n%s", code, o.String())
	}
	for _, bad := range [][]string{{"--days"}, {"--days", "x"}, {"--days", "3651"}, {"--days", "0"}, {"extra"}} {
		e.Reset()
		if gateClustersCLI(bad, &o, &e) != 2 || !strings.Contains(e.String(), "usage: sprint-check gate-clusters") {
			t.Errorf("args %v", bad)
		}
	}
	// one run, so no cluster: the text says so and lists it apart
	gcWrite(t, filepath.Join(home, "events", day+".jsonl"), line)
	o.Reset()
	gateClustersCLI(nil, &o, &e)
	if !strings.Contains(o.String(), "no cause seen in 2 or more runs\nseen once (not a pattern):\n1 x rejected evaluator stale") {
		t.Errorf("once:\n%s", o.String())
	}
}

func TestGateClustersJSONShapeAndReviewerIDs(t *testing.T) {
	root := t.TempDir()
	gcWrite(t, filepath.Join(root, ".tickets/t-1111/review-notes.md"), "## Verdict\n\nNO\n")
	gcWrite(t, filepath.Join(root, ".tickets/t-2222/review-notes.md"), "## Verdict\n\nNO\n")
	r := gateClusters(root, "", 30, time.Now())
	if len(r.Errors) != 2 || r.Errors[1] != "events folder: no CANON_HOME and no home folder" {
		t.Errorf("errors %v", r.Errors)
	}
	if r2 := gateClusters(root, t.TempDir(), 30, time.Now()); r2.Errors[1] != "events folder: missing" {
		t.Errorf("errors %v", r2.Errors)
	}
	c := r.Clusters[0]
	if c.Example != "reviewer NO t-2222" && c.Example != "reviewer NO t-1111" {
		t.Errorf("example %q", c.Example)
	}
	if !gcHas(c.Runs, "review:t-1111") || !gcHas(c.Runs, "review:t-2222") {
		t.Errorf("runs %v", c.Runs)
	}
	b, _ := json.Marshal(r)
	for _, k := range []string{`"days":`, `"clusters":`, `"seen_once":`, `"unreadable_lines":`, `"errors":`, `"cause":`, `"count":`, `"tickets":`, `"runs":`, `"example":`, `"last":`} {
		if !strings.Contains(string(b), k) {
			t.Errorf("json lacks %s: %s", k, b)
		}
	}
}

// The caps and the file rules the sweep found unguarded: more than gcMaxFiles day files, an oversized file read only to its cap, a
// symlinked review-notes.md and look-alike folder names are never followed or counted.
func TestGateClustersCapsAndLookAlikes(t *testing.T) {
	root, home, now := gcFixture(t)
	for i := 0; i < gcMaxFiles+1; i++ { // 401 day files, all older than the window except none: the cap is on the count, not the date
		gcWrite(t, filepath.Join(home, "events", time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC).AddDate(0, 0, i).Format("2006-01-02")+".jsonl"), "")
	}
	r := gateClusters(root, home, 30, now)
	found := false
	for _, e := range r.Errors {
		if strings.Contains(e, "more than 400 day files") {
			found = true
		}
	}
	if !found {
		t.Errorf("no cap message for %d day files: %v", gcMaxFiles+1, r.Errors)
	}
	// an oversized day file is read to the cap and says so
	big := filepath.Join(home, "events", "2026-10-25.jsonl")
	if err := os.WriteFile(big, bytes.Repeat([]byte("x"), gcMaxBytes+10), 0o644); err != nil {
		t.Fatal(err)
	}
	r = gateClusters(root, home, 30, now)
	over := false
	for _, e := range r.Errors {
		if strings.Contains(e, "larger than 4 MiB") {
			over = true
		}
	}
	if !over {
		t.Errorf("an oversized file was not reported: %v", r.Errors)
	}
	// look-alike ticket folders and a symlinked review-notes.md are not counted as reviewer NOs; one real folder is (the control)
	gcWrite(t, filepath.Join(root, ".tickets/t-beef/review-notes.md"), "## Verdict\n\nNO\n")
	for _, n := range []string{"xt-aaaa", "t-aaaa-evil", "t-zz"} {
		gcWrite(t, filepath.Join(root, ".tickets", n, "review-notes.md"), "## Verdict\n\nNO\n")
	}
	real := filepath.Join(root, "elsewhere-notes.md")
	gcWrite(t, real, "## Verdict\n\nNO\n")
	if err := os.MkdirAll(filepath.Join(root, ".tickets/t-abcd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(root, ".tickets/t-abcd/review-notes.md")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	r = gateClusters(root, home, 30, now)
	var no []gcCluster
	for _, c := range append(append([]gcCluster{}, r.Clusters...), r.SeenOnce...) {
		if c.Cause == "reviewer NO" {
			no = append(no, c)
		}
	}
	if len(no) != 1 || no[0].Count != 1 || len(no[0].Tickets) != 1 || no[0].Tickets[0] != "t-beef" {
		t.Errorf("only the real t-beef notes count as a reviewer NO (not a look-alike folder or a symlink): %+v", no)
	}
}

// The run log is untrusted: thousands of failing lines for one ticket must read that ticket's 1 MiB eval-report.md once, not once per
// line (the reviewer measured 217 s for 46k lines before the cache).
func TestGateClustersReadsEachReportOnce(t *testing.T) {
	root, home, now := gcFixture(t)
	pad := strings.Repeat("filler row of text in the report that is never a table row\n", 17000) + "| 2 | Safe reading | fail |\n" // the failing row is last: a read has to scan the whole file
	gcWrite(t, filepath.Join(root, ".tickets/t-9999/eval-report.md"), "| # | Criterion | Verdict |\n|---|---|---|\n"+pad)
	var b strings.Builder
	for i := 0; i < 20000; i++ {
		b.WriteString(`{"ts":"2026-10-25T10:00:00Z","agent_id":"x` + strconv.Itoa(i) + `","agent_type":"evaluator","ticket":"t-9999","outcome":"fail"}` + "\n")
	}
	gcWrite(t, filepath.Join(root, ".claude/subagent-runs.jsonl"), b.String())
	start := time.Now()
	r := gateClusters(root, home, 30, now)
	if d := time.Since(start); d > 3*time.Second {
		t.Errorf("20000 failing lines for one ticket took %v: the report is being re-read per line", d)
	}
	found := false
	for _, c := range r.Clusters {
		if c.Cause == "evaluator fail: Safe reading" && c.Count == 20000 {
			found = true
		}
	}
	if !found {
		t.Errorf("the 20000 failures did not form one titled cluster: %+v", r.Clusters)
	}
}

// One run is one agent id. The log can hold two lines for it (a bare hook line, then the line with its cost): that is one failure, not a
// two-run pattern (found on the real log by the evaluator: 29 lines for 24 runs).
func TestGateClustersCountsOneRunPerAgentID(t *testing.T) {
	root, home, now := gcFixture(t)
	line := func(id, ticket string) string {
		return `{"ts":"2026-10-25T10:00:00Z","agent_id":"` + id + `","agent_type":"reviewer","ticket":"` + ticket + `","outcome":"fail"}` + "\n"
	}
	gcWrite(t, filepath.Join(root, ".claude/subagent-runs.jsonl"), line("dup-1", "t-1111")+line("dup-1", "t-1111")+line("two-2", "t-2222")+line("two-3", "t-3333"))
	r := gateClusters(root, home, 30, now)
	var fail []gcCluster
	for _, c := range append(append([]gcCluster{}, r.Clusters...), r.SeenOnce...) {
		if c.Cause == "reviewer fail" {
			fail = append(fail, c)
		}
	}
	if len(fail) != 1 || fail[0].Count != 3 || len(fail[0].Runs) != 3 {
		t.Fatalf("three distinct agent ids, one of them logged twice, are three runs: %+v", fail)
	}
	gcWrite(t, filepath.Join(root, ".claude/subagent-runs.jsonl"), line("same-1", "t-1111")+line("same-1", "t-1111"))
	r = gateClusters(root, home, 30, now)
	for _, c := range r.Clusters {
		if c.Cause == "reviewer fail" {
			t.Errorf("one run logged twice is a pattern: %+v", c)
		}
	}
	if len(r.SeenOnce) == 0 || r.SeenOnce[0].Count != 1 {
		t.Errorf("one run logged twice must be seen once: %+v", r.SeenOnce)
	}
}

// The day-file cap keeps the NEWEST gcMaxFiles files: a gate.rejected event in the oldest file is not read.
func TestGateClustersDayFileCapKeepsTheNewest(t *testing.T) {
	root, home, now := gcFixture(t)
	dir := filepath.Join(home, "events")
	rej := func(id string) string {
		return `{"schema":1,"id":"` + id + `","ts":"2026-10-24T09:00:00Z","kind":"gate.rejected","source":"sprint","project":"p","data":{"ticket":"t-7777","role":"evaluator","reason":"oldest-only"}}` + "\n"
	}
	// 401 consecutive day files from 2026-10-24: the cap is on the count, and it must keep the newest 400
	first := time.Date(2026, 10, 24, 0, 0, 0, 0, time.UTC)
	for i := 0; i < gcMaxFiles+1; i++ {
		name := first.AddDate(0, 0, i).Format("2006-01-02") + ".jsonl"
		body := ""
		if i == 0 {
			body = rej("old") // the OLDEST file of the 401 holds the only oldest-only event
		}
		gcWrite(t, filepath.Join(dir, name), body)
	}
	r := gateClusters(root, home, 30, now)
	for _, c := range append(append([]gcCluster{}, r.Clusters...), r.SeenOnce...) {
		if strings.Contains(c.Cause, "oldest-only") {
			t.Errorf("the cap read the oldest file instead of dropping it: %+v", c)
		}
	}
}
