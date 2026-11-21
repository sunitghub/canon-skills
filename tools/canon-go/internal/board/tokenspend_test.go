package board

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"canon/internal/transcript"
)

// t-0829: `token-spend`. Every test names the prod path it protects: `sprint token-spend` (the table) or `sprint complete`'s
// `token-spend --ticket <id> --record` (the sprint.cost and gate.cost events and the cost line). The golden test against the bash
// version, and the shell-level checks, are tests/token-spend-golden.sh and tests/sprint-token-spend.sh.

// tsFix is a scratch project, Claude config dir, Copilot home and activity log, all pinned (never the real ones).
type tsFix struct {
	t                    *testing.T
	root, cfg, cop, home string
	n                    int
}

func newTSFix(t *testing.T) *tsFix {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &tsFix{t: t, root: filepath.Join(d, "proj"), cfg: filepath.Join(d, "claude"), cop: filepath.Join(d, "copilot"), home: filepath.Join(d, "canon")}
	for _, p := range []string{f.root, f.cfg, f.cop, f.home, filepath.Join(d, "home")} {
		os.MkdirAll(p, 0o755)
	}
	t.Setenv("HOME", filepath.Join(d, "home"))
	t.Setenv("CLAUDE_CONFIG_DIR", f.cfg)
	t.Setenv("COPILOT_HOME", f.cop)
	t.Setenv("CANON_HOME", f.home)
	t.Setenv("CANON_EVENTS_CLOCK", "2026-10-05T00:00:00Z")
	t.Setenv("CANON_EVENT_ACTOR", "")
	return f
}

func (f *tsFix) write(path string, lines ...string) {
	f.t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// events writes the sprint's day file: start, gate start (optional), end, in UTC on 2026-10-01.
func (f *tsFix) events(ticket, start, gate, end string) {
	f.t.Helper()
	ev := func(ts, kind string) string {
		return fmt.Sprintf(`{"schema":1,"ts":"2026-10-01T%s.000Z","kind":"%s","project":"%s","data":{"ticket":"%s"}}`, ts, kind, f.root, ticket)
	}
	lines := []string{ev(start, "sprint.started")}
	if gate != "" {
		lines = append(lines, ev(gate, "gate.started"))
	}
	lines = append(lines, ev(end, "sprint.completed"))
	p := filepath.Join(f.home, "events", "2026-10-01.jsonl")
	old, _ := os.ReadFile(p)
	f.write(p, strings.TrimSuffix(string(old), "\n"))
	b, _ := os.ReadFile(p)
	os.WriteFile(p, []byte(strings.TrimLeft(string(b), "\n")+strings.Join(lines, "\n")+"\n"), 0o644)
}

func (f *tsFix) plan(ticket, approved string) {
	f.t.Helper()
	body := "## Sign-off\nTier: normal | Risk: x\n"
	if approved != "" {
		body += "Approved: sha256:" + strings.Repeat("a", 64) + " 2026-10-01T" + approved + "Z\n"
	}
	f.write(filepath.Join(f.root, ".tickets", ticket, "plan.md"), body)
}

func claudeDir(root, cfg string) string {
	return filepath.Join(cfg, "projects", tsEncode(root))
}

// call is one assistant line: ts, id, model, input, cache write, cache read, output.
func call(ts, id, model string, in, cw, cr, out int, extra string) string {
	return fmt.Sprintf(`{"type":"assistant","message":{"model":"%s","id":"%s","role":"assistant","content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":%d}},"timestamp":"2026-10-01T%s.000Z","cwd":"CWD"}`,
		model, id, extra, in, cw, cr, out, ts)
}

// main writes a main-session transcript; CWD in the lines is the project.
func (f *tsFix) main(name string, lines ...string) {
	f.t.Helper()
	for i := range lines {
		lines[i] = strings.ReplaceAll(lines[i], `"CWD"`, `"`+f.root+`"`)
	}
	f.write(filepath.Join(claudeDir(f.root, f.cfg), name+".jsonl"), lines...)
}

// sub writes a subagent transcript and its meta ("" agentType: no meta file).
func (f *tsFix) sub(id, agentType, desc string, lines ...string) {
	f.t.Helper()
	dir := filepath.Join(claudeDir(f.root, f.cfg), "s1", "subagents")
	for i := range lines {
		lines[i] = strings.ReplaceAll(lines[i], `"CWD"`, `"`+f.root+`"`)
	}
	f.write(filepath.Join(dir, "agent-"+id+".jsonl"), lines...)
	if agentType != "" {
		f.write(filepath.Join(dir, "agent-"+id+".meta.json"), fmt.Sprintf(`{"agentType":"%s","description":"%s"}`, agentType, desc))
	}
}

// run runs token-spend; with record it returns the recorded events as kind -> list of field maps.
func (f *tsFix) run(args ...string) (string, int) {
	f.t.Helper()
	var out, errb bytes.Buffer
	rc := tokenSpendCLI(append([]string{"--project", f.root}, args...), &out, &errb)
	if rc != 0 {
		f.t.Logf("stderr: %s", errb.String())
	}
	return out.String(), rc
}

func (f *tsFix) recorded() map[string][]map[string]string {
	f.t.Helper()
	got := map[string][]map[string]string{}
	files, _ := filepath.Glob(filepath.Join(f.home, "events", "2026-10-05.jsonl"))
	for _, p := range files {
		b, _ := os.ReadFile(p)
		for _, l := range strings.Split(string(b), "\n") {
			if l == "" {
				continue
			}
			k := rawField(l, "kind")
			if k != "sprint.cost" && k != "gate.cost" {
				continue
			}
			// the data object's fields, by their quoted names
			data := map[string]string{}
			d := l[strings.Index(l, `"data":{`)+8:]
			for _, kv := range strings.Split(strings.TrimSuffix(d, "}}"), `","`) {
				kv = strings.Trim(kv, `"`)
				if i := strings.Index(kv, `":"`); i > 0 {
					data[kv[:i]] = kv[i+3:]
				}
			}
			got[k] = append(got[k], data)
		}
	}
	return got
}

func want(t *testing.T, got map[string]string, kv string) {
	t.Helper()
	for _, p := range strings.Fields(kv) {
		k, v, _ := strings.Cut(p, "=")
		if got[k] != v {
			t.Errorf("%s = %q, want %q (event %v)", k, got[k], v, got)
		}
	}
}

// Protects `sprint complete`'s cost record: the planning / build / close boundaries are the Approved: stamp (a call at that second is
// build) and the first non-speccheck gate.started (a call at that second is close); a call at the sprint's end second is not in it.
func TestTokenSpendPhaseBoundaries(t *testing.T) {
	f := newTSFix(t)
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	f.plan("t-aaaa", "10:30:00")
	f.main("s1",
		call("10:29:59", "msg_1", "m", 1, 0, 0, 1, ""),   // plan
		call("10:30:00", "msg_2", "m", 2, 0, 0, 2, ""),   // build: the approval second itself
		call("10:59:59", "msg_3", "m", 3, 0, 0, 3, ""),   // build
		call("11:00:00", "msg_4", "m", 4, 0, 0, 4, ""),   // close: the gate's first second
		call("12:00:00", "msg_5", "m", 99, 0, 0, 99, ""), // the sprint's end second: outside
	)
	if out, rc := f.run("--ticket", "t-aaaa", "--record"); rc != 0 || !strings.Contains(out, "cost: 20 tokens (close 8, 40%") {
		t.Fatalf("rc %d out %q", rc, out)
	}
	ev := f.recorded()["sprint.cost"]
	if len(ev) != 1 {
		t.Fatalf("sprint.cost events: %v", ev)
	}
	want(t, ev[0], "planning=2 implementation=10 gates=8 turns=4 plan_calls=1 plan_input=1 build_calls=2 build_input=5 close_calls=1 close_input=4")
}

// Protects the per-gate record and the table's refusal to print a 0 for nothing: a phase with no main-session call is n/a (no event fields).
func TestTokenSpendNoCallsIsNA(t *testing.T) {
	f := newTSFix(t)
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	f.plan("t-aaaa", "10:30:00")
	f.main("s1", call("10:40:00", "msg_1", "m", 1, 0, 0, 1, ""))
	out, _ := f.run("--ticket", "t-aaaa")
	if !strings.Contains(out, "plan (main)") || !strings.Contains(out, "n/a") {
		t.Fatalf("no n/a in the context table: %s", out)
	}
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "plan (main)") && strings.Contains(l, " 0 ") {
			t.Errorf("a phase with no calls printed a 0: %q", l)
		}
	}
	f.run("--ticket", "t-aaaa", "--record")
	ev := f.recorded()["sprint.cost"][0]
	for _, k := range []string{"plan_calls", "plan_peak", "close_calls", "close_peak"} {
		if _, ok := ev[k]; ok {
			t.Errorf("%s present for a phase with no calls: %v", k, ev)
		}
	}
	want(t, ev, "build_calls=1")
}

// Protects the six numbers: calls once per message id (a message written as several lines counts once), input, cache read, cache write,
// output as recorded, and the peak = the largest single call's input + cache read + cache write.
func TestTokenSpendCacheFieldsAndPeak(t *testing.T) {
	f := newTSFix(t)
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	f.plan("t-aaaa", "10:30:00")
	f.main("s1",
		call("10:10:00", "msg_1", "m", 5, 700, 3000, 40, "first block"),
		call("10:10:00", "msg_1", "m", 5, 700, 3000, 40, "second block of the same message"),
		call("10:20:00", "msg_2", "m", 2, 100, 3700, 20, ""),
		call("10:25:00", "msg_3", "m", 1, 10, 100, 5, ""),
	)
	f.run("--ticket", "t-aaaa", "--record")
	ev := f.recorded()["sprint.cost"][0]
	want(t, ev, "plan_calls=3 plan_input=8 plan_cache_read=6800 plan_cache_write=810 plan_output=65 plan_peak=3802")
	for k, v := range ev {
		if strings.Contains(v, "first block") || strings.Contains(k, "text") {
			t.Errorf("transcript text reached the event: %s=%s", k, v)
		}
	}
}

// Protects the per-run attribution: gate.cost's role comes from the subagent's meta agentType (a Plan agent that read reference/eval.md
// is the evaluator), a subagent with no readable meta is unknown, and no subagent's calls enter the main session's numbers.
func TestTokenSpendGateAttribution(t *testing.T) {
	f := newTSFix(t)
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	f.plan("t-aaaa", "10:30:00")
	f.main("s1", call("10:40:00", "msg_main", "m", 1, 0, 0, 1, ""))
	f.sub("sp", "canon-spec-checker", "t-aaaa spec", call("10:10:00", "msg_sp", "m", 2, 0, 0, 1, ""))
	f.sub("rv", "canon-reviewer", "t-aaaa review", call("11:10:00", "msg_rv", "m", 3, 0, 0, 1, ""))
	f.sub("ev", "canon-evaluator", "t-aaaa eval", call("11:20:00", "msg_ev", "m", 4, 0, 0, 1, ""))
	f.sub("pe", "Plan", "t-aaaa plan agent", call("11:30:00", "msg_pe", "m", 5, 0, 0, 1, "reading skills/sprint/reference/eval.md"))
	f.sub("pn", "Plan", "t-aaaa planning", call("11:35:00", "msg_pn", "m", 6, 0, 0, 1, "thinking"))
	f.sub("gp", "general-purpose", "implement", call("10:45:00", "msg_gp", "m", 7, 0, 0, 1, ""))
	f.sub("nm", "", "", call("10:46:00", "msg_nm", "m", 8, 0, 0, 1, ""))
	f.run("--ticket", "t-aaaa", "--record")
	roles := map[string]string{}
	types := map[string]string{}
	for _, g := range f.recorded()["gate.cost"] {
		roles[g["agent_id"]] = g["role"]
		types[g["agent_id"]] = g["agent_type"]
	}
	for id, role := range map[string]string{"sp": "speccheck", "rv": "reviewer", "ev": "evaluator", "pe": "evaluator", "pn": "other", "gp": "other", "nm": "unknown"} {
		if roles[id] != role {
			t.Errorf("agent %s: role %q, want %q (all %v)", id, roles[id], role, roles)
		}
	}
	if types["pe"] != "Plan" || types["nm"] != "" {
		t.Errorf("agent types %v", types)
	}
	if len(roles) != 7 {
		t.Errorf("gate.cost events %d, want 7: %v", len(roles), roles)
	}
	ev := f.recorded()["sprint.cost"][0]
	want(t, ev, "build_calls=1 build_input=1 gate_runs=2")
	if _, ok := ev["plan_calls"]; ok {
		t.Errorf("the spec check's call is in the main session's plan numbers: %v", ev)
	}
}

// Protects the cost record's once-only rule: a second close writes nothing; a sprint.cost lost after its gate.cost events were written
// is written again, and a gate.cost for an agent id already recorded is never written twice.
func TestTokenSpendRecordOnce(t *testing.T) {
	f := newTSFix(t)
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	f.plan("t-aaaa", "10:30:00")
	f.main("s1", call("10:40:00", "msg_1", "m", 1, 0, 0, 1, ""))
	f.sub("rv", "canon-reviewer", "t-aaaa review", call("11:10:00", "msg_rv", "m", 3, 0, 0, 1, ""))
	if out, _ := f.run("--ticket", "t-aaaa", "--record"); !strings.HasPrefix(out, "cost: ") {
		t.Fatalf("first record printed %q", out)
	}
	if out, _ := f.run("--ticket", "t-aaaa", "--record"); out != "" {
		t.Errorf("a second record printed %q", out)
	}
	if ev := f.recorded(); len(ev["sprint.cost"]) != 1 || len(ev["gate.cost"]) != 1 {
		t.Fatalf("after two records: %v", ev)
	}
	p := filepath.Join(f.home, "events", "2026-10-05.jsonl")
	b, _ := os.ReadFile(p)
	var keep []string
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if !strings.Contains(l, `"kind":"sprint.cost"`) {
			keep = append(keep, l)
		}
	}
	os.WriteFile(p, []byte(strings.Join(keep, "\n")+"\n"), 0o644)
	f.run("--ticket", "t-aaaa", "--record")
	if ev := f.recorded(); len(ev["sprint.cost"]) != 1 || len(ev["gate.cost"]) != 1 {
		t.Errorf("after a lost sprint.cost: sprint.cost %d gate.cost %d, want 1 and 1", len(ev["sprint.cost"]), len(ev["gate.cost"]))
	}
}

// Protects `sprint token-spend` and the close's record against files others write: an unreadable path, a line that is not JSON, a
// usage of the wrong shape and a line over the cap are skipped, and the lines after them still count.
func TestTokenSpendSkipsWhatItCannotRead(t *testing.T) {
	old := transcript.MaxLine
	transcript.MaxLine = 4096
	defer func() { transcript.MaxLine = old }()
	f := newTSFix(t)
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	f.plan("t-aaaa", "10:30:00")
	f.main("s1",
		"this is not json {\"type\":\"assistant\"",
		`{"type":"assistant","message":{"id":"msg_bad","usage":"x"},"timestamp":"2026-10-01T10:40:00.000Z"}`,
		call("10:40:00", "msg_over", "m", 1000, 0, 0, 1, strings.Repeat("x", 5000)), // over the cap
		call("10:41:00", "msg_1", "m", 1, 0, 0, 1, ""),
		call("10:42:00", "msg_just_under", "m", 2, 0, 0, 1, strings.Repeat("y", 3500)),
	)
	os.MkdirAll(filepath.Join(claudeDir(f.root, f.cfg), "folder.jsonl"), 0o755) // a folder named like a transcript
	locked := filepath.Join(claudeDir(f.root, f.cfg), "locked.jsonl")           // a transcript that cannot be opened, holding an in-window call
	f.main("locked", call("10:43:00", "msg_locked", "m", 7777, 0, 0, 1, ""))
	os.Chmod(locked, 0)
	t.Cleanup(func() { os.Chmod(locked, 0o644) })
	if os.Geteuid() == 0 {
		t.Skip("root reads a file with no permissions: nothing to skip")
	}
	out, rc := f.run("--ticket", "t-aaaa", "--record")
	if rc != 0 || !strings.HasPrefix(out, "cost: ") {
		t.Fatalf("rc %d out %q", rc, out)
	}
	want(t, f.recorded()["sprint.cost"][0], "build_calls=2 build_input=3")
}

// Protects the Copilot side of the record: a session found by its recorded working folder, its calls inside the sprint's window,
// split by the usage_record's agentId (the agent type from subagent.started), with inputTokens read as the whole prompt.
func TestTokenSpendCopilot(t *testing.T) {
	f := newTSFix(t)
	f.events("t-cplt", "20:00:00", "20:06:17", "20:30:00")
	use := func(ts, agent string, in, out, cr, cw int, id string) string {
		a := ""
		if agent != "" {
			a = `"agentId":"` + agent + `",`
		}
		return fmt.Sprintf(`{"type":"session.usage_record","data":{"usage":{"model":"claude-sonnet-5.5","responseModel":"claude-sonnet-5-5","inputTokens":%d,"outputTokens":%d,"cacheReadTokens":%d,"cacheWriteTokens":%d,"apiCallId":"%s"}},%s"timestamp":"2026-10-01T%sZ"}`, in, out, cr, cw, id, a, ts)
	}
	session := func(id, cwd string, lines ...string) {
		f.write(filepath.Join(f.cop, "session-state", id, "events.jsonl"), append([]string{
			fmt.Sprintf(`{"type":"session.start","data":{"context":{"cwd":"%s","gitRoot":"%s"}},"timestamp":"2026-10-01T20:00:00.000Z"}`, cwd, cwd),
			`{"type":"subagent.started","data":{"agentType":"canon-evaluator"},"agentId":"ag-1","timestamp":"2026-10-01T20:06:16.477Z"}`,
		}, lines...)...)
	}
	session("mine", f.root,
		use("20:06:16.463", "", 31087, 328, 0, 31083, "c1"),
		use("20:06:17.813", "ag-1", 6900, 127, 0, 6896, "c2"),
		"not json",
		use("20:06:19.411", "ag-1", 7155, 215, 6896, 257, "c3"),
		use("20:06:35.421", "", 32077, 659, 31083, 992, "c4"),
		use("21:00:00.000", "", 5000, 5, 0, 0, "c5")) // after the sprint's end: not in its window
	session("other", "/somewhere/else", use("20:06:20.000", "", 99999, 9, 0, 0, "c6"))
	out, _ := f.run("--ticket", "t-cplt", "--record")
	if !strings.HasPrefix(out, "cost: ") {
		t.Fatalf("no cost line: %q", out)
	}
	ev := f.recorded()
	want(t, ev["sprint.cost"][0], "build_calls=1 build_input=4 build_cache_write=31083 build_output=328 build_peak=31087 close_calls=1 close_input=2 close_cache_read=31083 close_cache_write=992 close_output=659 close_peak=32077 gate_runs=1")
	if len(ev["gate.cost"]) != 1 {
		t.Fatalf("gate.cost events: %v", ev["gate.cost"])
	}
	want(t, ev["gate.cost"][0], "agent_id=ag-1 role=evaluator agent_type=canon-evaluator model=claude-sonnet-5-5 calls=2 input=6 cache_read=6896 cache_write=7153 output=342 peak=7155")
}

// Protects `sprint token-spend`'s refusals: the table says nothing when no sprint matches, and a sprint with no calls reads as such.
func TestTokenSpendNoSprintOrNoCalls(t *testing.T) {
	f := newTSFix(t)
	if out, _ := f.run(); !strings.Contains(out, "No Claude Code transcripts for "+f.root) {
		t.Errorf("no transcripts and no events: %q", out)
	}
	f.main("s1", call("10:40:00", "msg_1", "m", 1, 0, 0, 1, ""))
	if out, _ := f.run(); !strings.Contains(out, "No canon events under") {
		t.Errorf("no events: %q", out)
	}
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	if out, _ := f.run("--ticket", "t-zzzz"); out != "No completed sprint for t-zzzz.\n" {
		t.Errorf("unknown ticket: %q", out)
	}
	for _, bad := range [][]string{{"--last", "0"}, {"--last", "x"}, {"--last"}, {"--ticket"}, {"--bogus"}, {"--record"}} {
		if _, rc := f.run(bad...); rc != 1 {
			t.Errorf("%v: rc %d, want 1", bad, rc)
		}
	}
}

// Protects the table's label (t-e200): the close window reads "close", and planning names its spec-check share.
func TestTokenSpendLabels(t *testing.T) {
	f := newTSFix(t)
	f.events("t-aaaa", "10:00:00", "11:00:00", "12:00:00")
	f.plan("t-aaaa", "10:30:00")
	f.main("s1", call("10:10:00", "msg_1", "m", 10000, 0, 0, 1000, ""), call("11:10:00", "msg_2", "m", 1, 0, 0, 1, ""))
	f.sub("sp", "canon-spec-checker", "t-aaaa spec", call("10:12:00", "msg_sp", "m", 30000, 0, 0, 400, ""))
	out, _ := f.run("--ticket", "t-aaaa")
	if !strings.Contains(out, "implementation      close  cache-read") || strings.Contains(out, "gates") {
		t.Errorf("header: %s", out)
	}
	if !strings.Contains(out, " 41k (spec 30k) ") {
		t.Errorf("the planning cell does not name the spec-check share: %s", out)
	}
	line, _ := f.run("--ticket", "t-aaaa", "--record")
	if !strings.HasPrefix(line, "cost: 41k tokens (close 2, 0% — gate agents 0), cache reads 0, 0 gate runs") {
		t.Errorf("cost line: %q", line)
	}
}

// TestOracle: the reader's per-file numbers against ctx.js's (evidence of t-0829's "check against reality"). Set T0829_BASELINE to the
// saved bench transcripts and T0829_ORACLE to a TSV of ctx.js's per-file sums (path relative to the baseline, calls, cache_read,
// cache_write, output, peak); skipped otherwise.
func TestOracle(t *testing.T) {
	base, tsv := os.Getenv("T0829_BASELINE"), os.Getenv("T0829_ORACLE")
	if base == "" || tsv == "" {
		t.Skip("T0829_BASELINE / T0829_ORACLE not set")
	}
	raw, err := os.ReadFile(tsv)
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, l := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		c := strings.Split(l, "\t")
		if len(c) != 6 {
			t.Fatalf("bad oracle row %q", l)
		}
		s := &tsState{o: tsOpts{paths: []string{"/nowhere"}}, seen: map[string]bool{}, first: map[string]string{}}
		s.readClaude(filepath.Join(base, c[0]), strings.Contains(c[0], "/subagents/"))
		var st tsStat
		for _, k := range s.calls {
			st.add(k)
		}
		got := []int64{st.calls, st.cr, st.cw, st.out, st.peak}
		for i, g := range got {
			w, _ := strconv.ParseInt(c[i+1], 10, 64)
			if g != w {
				t.Errorf("%s: field %d = %d, ctx.js says %d", c[0], i+1, g, w)
			}
		}
		checked++
	}
	t.Logf("%d transcript files checked against ctx.js", checked)
}
