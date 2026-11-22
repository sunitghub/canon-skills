package board

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"canon/internal/events"
	"canon/internal/transcript"
)

// t-7e26 / t-0829: `token-spend --ticket <id> --record`, sprint complete's call. It writes one step.cost per main-session step (t-0abe,
// keyed by ticket + project + step), one gate.cost event per subagent run (keyed
// by its agent id; a run that already has one is skipped, so a re-run close never writes it twice), then the ticket's one sprint.cost
// event, then prints the cost line. Numbers, ids, role and model names only: never transcript text. Nothing is written or printed when
// there are no calls in the sprint's window or the cost is already recorded (the sprint.cost event is the once-guard, written last).

var tsPlainID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// tsPlainOr keeps a transcript-supplied name only when it is a plain id.
func tsPlainOr(v string) string {
	if tsPlainID.MatchString(v) {
		return v
	}
	return ""
}

// tsPhaseFields are the per-phase numbers the sprint.cost event carries for the main session: <phase>_calls, _input, _cache_read,
// _cache_write, _output, _peak. A phase with no calls has no fields (n/a, never 0).
func tsPhaseFields(data map[string]string, prefix string, st *tsStat) {
	if st == nil || st.calls == 0 {
		return
	}
	for _, f := range []struct {
		name string
		v    int64
	}{{"calls", st.calls}, {"input", st.in}, {"cache_read", st.cr}, {"cache_write", st.cw}, {"output", st.out}, {"peak", st.peak}} {
		data[prefix+f.name] = strconv.FormatInt(f.v, 10)
	}
}

func (s *tsState) record(gateCosted, stepCosted map[string]bool) {
	L := s.shown()
	if len(L) == 0 {
		return
	}
	hi := L[0]
	w := s.wins[hi-1]
	if w.turns == 0 || w.cost != nil {
		return
	}
	planning, impl := w.pf["planning"], w.pf["implementation"]
	bph := "implementation"
	if w.build {
		planning, impl, bph = 0, w.pf["build"], "build"
	}
	gates := w.pf["gates"]
	var models []string
	builder, bv := "", int64(0)
	for _, m := range s.models[hi] {
		models = append(models, m+":"+strconv.FormatInt(s.modelTk[fmt.Sprintf("%d\x1c%s", hi, m)], 10))
		if v := s.bph[fmt.Sprintf("%d\x1c%s\x1c%s", hi, bph, m)]; v > bv {
			bv, builder = v, m
		}
	}
	// t-b6ad: the builder is the model with the most implementation (or build) tokens, gates and planning excluded. If that top model
	// is not a plain id (it came from a transcript), there is no builder: never the runner-up, which would be a guess.
	if !tsPlainID.MatchString(builder) {
		builder = ""
	}
	same := tsSameModelGates(s.o.root, w.ticket, builder)
	data := map[string]string{
		"ticket": w.ticket, "planning": strconv.FormatInt(planning, 10), "implementation": strconv.FormatInt(impl, 10),
		"gates": strconv.FormatInt(gates, 10), "cache_read": strconv.FormatInt(w.cacheRead, 10), "turns": strconv.Itoa(w.turns),
		"gate_runs": strconv.Itoa(len(w.gateFiles)), "models": strings.Join(models, ","),
	}
	if builder != "" {
		data["builder"] = builder
	}
	if same != "" {
		data["same_model"] = same
	}
	for _, p := range []string{"plan", "build", "close"} {
		tsPhaseFields(data, p+"_", w.main[p])
	}
	home, actor := events.Home(), os.Getenv("CANON_EVENT_ACTOR")
	// t-0abe: one step.cost per main-session step with calls, keyed by ticket + project + step, so a close that stopped before
	// sprint.cost (the once-guard below) never writes a step twice on its re-run.
	for _, st := range tsSteps {
		a, key := w.steps[st], w.ticket+"\x1c"+w.project+"\x1c"+st
		if a == nil || stepCosted[key] { // a step exists only once a call is added
			continue
		}
		stepCosted[key] = true
		events.EmitActor(home, "step.cost", "sprint", actor, s.o.root, s.stepFields(w, st, a))
	}
	for _, r := range w.runs {
		// Fields read from transcripts go into the events log only as plain ids (as builder above); an id the once-guard's
		// raw read could miss (a quote, over 64 bytes) is not recorded, so it can never be written twice.
		id := r.src.agentID
		if !tsPlainID.MatchString(id) || len(id) > 64 || gateCosted[id] {
			continue
		}
		gateCosted[id] = true
		g := map[string]string{"ticket": w.ticket, "agent_id": id, "role": r.src.role(), "agent_type": tsPlainOr(r.src.agentType), "model": tsPlainOr(r.model)}
		r.fields(g, s.denied)
		if m, ok := r.runMinutes(); ok {
			g["minutes"] = strconv.FormatFloat(m, 'f', 1, 64)
		}
		events.EmitActor(home, "gate.cost", "sprint", actor, s.o.root, g)
	}
	events.EmitActor(home, "sprint.cost", "sprint", actor, s.o.root, data)
	total := planning + impl + gates
	if total <= 0 {
		return
	}
	fmt.Fprintf(s.out, "cost: %s tokens (close %s, %d%% — gate agents %s), cache reads %s, %d gate runs\n",
		tsH(total), tsH(gates), 100*gates/total, tsH(w.gateAgents), tsH(w.cacheRead), len(w.gateFiles))
	switch {
	case same == "":
	case strings.Contains(same, ","):
		fmt.Fprintf(s.out, "note: the reviewer and the evaluator ran on %s, the model that built this change, so neither is independent of it (advisory, never a block).\n", builder)
	default:
		fmt.Fprintf(s.out, "note: the %s ran on %s, the model that built this change, so it is not independent of it (advisory, never a block).\n", same, builder)
	}
}

// tsSameModelGates is "reviewer", "evaluator" or "reviewer,evaluator" for the gates whose logged model is builder (a plain id: an
// odd or alias model in a row can never equal it); "" when the builder is unknown, there is no match or the log cannot be read. The
// log is .claude/subagent-runs.jsonl (subagent-log.sh); each role's LAST row for the ticket counts (t-b6ad).
func tsSameModelGates(root, ticket, builder string) string {
	if builder == "" {
		return ""
	}
	f, err := os.Open(filepath.Join(root, ".claude", "subagent-runs.jsonl"))
	if err != nil {
		return ""
	}
	defer f.Close()
	last := map[string]string{}
	br := bufio.NewReaderSize(f, 1<<20)
	for {
		line, more := transcript.NextLine(br)
		if !more {
			break
		}
		if l := string(line); line != nil && strings.Contains(l, `"ticket":"`+ticket+`"`) {
			if role := rawField(l, "agent_type"); role == "reviewer" || role == "evaluator" {
				last[role] = rawField(l, "model")
			}
		}
	}
	var out []string
	for _, r := range []string{"reviewer", "evaluator"} {
		if m, ok := last[r]; ok && m == builder {
			out = append(out, r)
		}
	}
	return strings.Join(out, ",")
}
