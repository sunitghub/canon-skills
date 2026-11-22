package board

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"canon/internal/common"
)

// t-0abe: per-step cost. A main-session call's step is plan, build, wrapup (close.started -> the first reviewer/evaluator dispatch),
// security-review (the last reviewer gate.finished -> its Wrapup Gates row) or close (the rest of the close phase); a subagent run is
// its own row (gate.cost). Each carries the six context numbers plus tool calls by name, user turns, the floor (the context of the
// first call of the transcript file the step's first call is in: system prompt + tool schemas + always-on files), growth, an estimated
// $ from the Admin model registry's prices and wall minutes. Numbers, ids and tool and model names only: never transcript text.

var tsSteps = []string{"plan", "build", "wrapup", "security-review", "close"}

// tsAgg is tsStat plus what a step.cost or gate.cost row adds.
type tsAgg struct {
	tsStat
	claude           bool // a Claude Code call: tool and user-turn counts apply (Copilot's record has neither)
	toolCalls, turns int64
	tools            map[string]int64 // plain tool name -> uses
	models           []string         // first-seen order
	mcalls           map[string]int64
	floor            int64
	firstTS, lastTS  string
	usd              float64
	noPrice          bool     // a call with tokens had a model with no registry price: cost_usd is then absent, never a partial sum
	unpriced         []string // those models' plain ids
	unpricedSeen     map[string]bool
}

func (a *tsAgg) add(c *tsCall, p tsPrices) {
	a.tsStat.add(c)
	if a.firstTS == "" || c.ts < a.firstTS {
		a.firstTS, a.floor = c.ts, c.src.floor
	}
	if c.ts > a.lastTS {
		a.lastTS = c.ts
	}
	if a.mcalls == nil {
		a.mcalls, a.tools, a.unpricedSeen = map[string]int64{}, map[string]int64{}, map[string]bool{}
	}
	if _, ok := a.mcalls[c.model]; !ok {
		a.models = append(a.models, c.model)
	}
	a.mcalls[c.model]++
	if !c.src.copilot {
		a.claude = true
		for _, n := range c.tools {
			a.toolCalls++
			if n = tsPlainOr(n); n != "" {
				a.tools[n]++
			}
		}
	}
	if c.in+c.cr+c.cw+c.out == 0 {
		return // a call with no tokens costs nothing, priced or not
	}
	pr, ok := p.of(c.model)
	if !ok {
		a.noPrice = true
		if m := tsPlainOr(c.model); m != "" && !a.unpricedSeen[m] {
			a.unpricedSeen[m] = true
			a.unpriced = append(a.unpriced, m)
		}
		return
	}
	plain := c.cw - c.cw5 - c.cw1h // a write with no TTL split is priced as a 5-minute one
	if plain < 0 {
		plain = 0
	}
	a.usd += (float64(c.in)*pr[0] + float64(c.cr)*pr[0]*0.1 + float64(c.cw5+plain)*pr[0]*1.25 + float64(c.cw1h)*pr[0]*2 + float64(c.out)*pr[1]) / 1e6
}

// tsPairs is "name:n" pairs joined by commas, cut at a pair (never mid-name) to fit max bytes.
func tsPairs(keys []string, n map[string]int64, max int) string {
	l := make([]string, len(keys))
	for i, k := range keys {
		l[i] = k + ":" + strconv.FormatInt(n[k], 10)
	}
	return tsJoinCap(l, max)
}

// tsJoinCap joins items with commas, cut at an item to fit max bytes.
func tsJoinCap(l []string, max int) string {
	var b strings.Builder
	for _, k := range l {
		if b.Len() > 0 {
			k = "," + k
		}
		if b.Len()+len(k) > max {
			break
		}
		b.WriteString(k)
	}
	return b.String()
}

// toolsField: the plain tool names, most used first (ties by name).
func (a *tsAgg) toolsField() string {
	var ks []string
	for k := range a.tools {
		ks = append(ks, k)
	}
	sort.Slice(ks, func(i, j int) bool {
		if a.tools[ks[i]] != a.tools[ks[j]] {
			return a.tools[ks[i]] > a.tools[ks[j]]
		}
		return ks[i] < ks[j]
	})
	return tsPairs(ks, a.tools, 200)
}

func (a *tsAgg) growth() int64 {
	if g := a.peak - a.floor; g > 0 {
		return g
	}
	return 0 // a peak under the session's first request (after a /compact) is no growth
}

// fields writes a step.cost or gate.cost row's numbers; a field a source cannot supply is absent, never 0.
func (a *tsAgg) fields(d map[string]string, denied string) {
	tsPhaseFields(d, "", &a.tsStat)
	d["floor"] = strconv.FormatInt(a.floor, 10)
	d["growth"] = strconv.FormatInt(a.growth(), 10)
	if a.claude {
		d["tool_calls"] = strconv.FormatInt(a.toolCalls, 10)
		if t := a.toolsField(); t != "" {
			d["tools"] = t
		}
	}
	if !a.noPrice {
		d["cost_usd"] = fmt.Sprintf("%.4f", a.usd)
	} else if len(a.unpriced) > 0 {
		d["unpriced"] = tsJoinCap(a.unpriced, 120)
	}
	d["denied_tools"] = denied
}

// tsPrices is the Admin model registry's price per million tokens (input, output), by id and by alias.
type tsPrices struct{ id, alias map[string][2]float64 }

func (p tsPrices) of(model string) ([2]float64, bool) {
	if v, ok := p.id[model]; ok {
		return v, true
	}
	v, ok := p.alias[model]
	return v, ok
}

func tsLoadPrices() tsPrices {
	seed := modelTiersPath
	if seed == "" { // the CLI path: the seed beside the installed tools, as the board resolves it
		exe, _ := os.Executable()
		seed = filepath.Join(installToolsDir(exe), "sprint-check-app", "model-tiers.json")
	}
	p := tsPrices{id: map[string][2]float64{}, alias: map[string][2]float64{}}
	models, _ := common.LoadModelTiers(common.ModelTiersUserFile(), seed)["models"].(map[string]any)
	for _, list := range models {
		for _, e := range anySlice(list) {
			m, _ := e.(map[string]any)
			id, _ := m["id"].(string)
			in, _ := m["input_price"].(float64)
			out, _ := m["output_price"].(float64)
			if id == "" || in <= 0 && out <= 0 || in < 0 || out < 0 {
				continue
			}
			p.id[id] = [2]float64{in, out}
			if al, _ := m["alias"].(string); al != "" {
				if _, taken := p.alias[al]; !taken {
					p.alias[al] = [2]float64{in, out}
				}
			}
		}
	}
	return p
}

// tsDenied is the tool names Claude Code's permissions.deny lists (user, project and local settings), read now: an approximation of
// what the sprint's sessions ran with. Only the name before "(" is kept, as a plain id: a pattern's argument can be a path.
func tsDenied(root string) string {
	seen := map[string]bool{}
	for _, f := range []string{filepath.Join(claudeHome(), "settings.json"), filepath.Join(root, ".claude", "settings.json"), filepath.Join(root, ".claude", "settings.local.json")} {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var doc struct {
			Permissions struct {
				Deny []any `json:"deny"`
			} `json:"permissions"`
		}
		if json.Unmarshal(b, &doc) != nil {
			continue
		}
		for _, v := range doc.Permissions.Deny {
			s, _ := v.(string)
			name, _, _ := strings.Cut(s, "(")
			if name = tsPlainOr(strings.TrimSpace(name)); name != "" {
				seen[name] = true
			}
		}
	}
	if len(seen) == 0 {
		return "none"
	}
	var l []string
	for k := range seen {
		l = append(l, k)
	}
	sort.Strings(l)
	return tsJoinCap(l, 200)
}

// closeAt is where the close phase starts: the first close.started, or the first close-gate dispatch when that is earlier or there is
// no close.started (sprints before t-985c).
func (w *tsWin) closeAt() string {
	if w.closeStart != "" && (w.gate == "" || w.closeStart < w.gate) {
		return w.closeStart
	}
	return w.gate
}

// secFrom is where the security-review step starts: the last reviewer gate.finished before its row, inside the close; "" when
// either is missing or out of order.
func (w *tsWin) secFrom() string {
	ca, from := w.closeAt(), ""
	if w.secRow == "" || ca == "" {
		return ""
	}
	for _, f := range w.revFins {
		if f >= ca && f < w.secRow && f > from {
			from = f
		}
	}
	return from
}

// stepOf is a main-session call's step, from its phase and time.
func (w *tsWin) stepOf(ph, ts string) string {
	switch ph {
	case "planning":
		return "plan"
	case "implementation", "build":
		return "build"
	}
	if from := w.secFrom(); from != "" && ts > from && ts <= w.secRow {
		return "security-review"
	}
	if w.closeStart != "" && ts >= w.closeStart && (w.gate == "" || ts < w.gate) {
		return "wrapup"
	}
	return "close"
}

func tsMinutes(from, to string) (float64, bool) {
	a, e1 := time.Parse("2006-01-02T15:04:05", from)
	b, e2 := time.Parse("2006-01-02T15:04:05", to)
	if from == "" || to == "" || e1 != nil || e2 != nil || b.Before(a) {
		return 0, false
	}
	return b.Sub(a).Minutes(), true
}

// stepMinutes is a step's wall time from its bounding events; ok is false when one is missing (planning ended by plan.md's stamp).
func (w *tsWin) stepMinutes(step string) (float64, bool) {
	ca := w.closeAt()
	switch step {
	case "plan":
		if w.apprEv == "" {
			return 0, false
		}
		return tsMinutes(w.start, w.apprEv)
	case "build":
		if w.apprEv == "" {
			return 0, false
		}
		if ca == "" {
			return tsMinutes(w.apprEv, w.end)
		}
		return tsMinutes(w.apprEv, ca)
	case "wrapup":
		if w.gate != "" && w.gate > w.closeStart {
			return tsMinutes(w.closeStart, w.gate)
		}
		return tsMinutes(w.closeStart, w.end)
	case "security-review":
		return tsMinutes(w.secFrom(), w.secRow)
	}
	from := ca
	if w.closeStart != "" {
		from = w.gate
	}
	m, ok := tsMinutes(from, w.end)
	if sec, sok := tsMinutes(w.secFrom(), w.secRow); ok && sok {
		m -= sec
	}
	return m, ok
}

// stepFields is one step.cost event's data.
func (s *tsState) stepFields(w *tsWin, step string, a *tsAgg) map[string]string {
	d := map[string]string{"ticket": w.ticket, "step": step}
	a.fields(d, s.denied)
	if a.claude {
		d["user_turns"] = strconv.FormatInt(a.turns, 10)
	}
	var ms []string
	for _, m := range a.models {
		if tsPlainID.MatchString(m) {
			ms = append(ms, m)
		}
	}
	if v := tsPairs(ms, a.mcalls, 120); v != "" {
		d["models"] = v
	}
	if m, ok := w.stepMinutes(step); ok {
		d["minutes"] = strconv.FormatFloat(m, 'f', 1, 64)
	}
	return d
}

// runMinutes: a subagent run's first to last call.
func (a *tsAgg) runMinutes() (float64, bool) { return tsMinutes(a.firstTS, a.lastTS) }

func tsUSD(a *tsAgg) string {
	if a.noPrice {
		return "n/a"
	}
	return fmt.Sprintf("%.2f", a.usd)
}

func tsMinCell(m float64, ok bool) string {
	if !ok {
		return "n/a"
	}
	return strconv.FormatFloat(m, 'f', 1, 64)
}

// printSteps prints each shown sprint's per-step (main session) and per-run cost.
func (s *tsState) printSteps(out io.Writer, L []int) {
	fmt.Fprintln(out, "Cost per step (main session) and per subagent run, the sprints above (est $ from Admin > Model tiers prices; n/a: unpriced or unknown):")
	fmt.Fprintf(out, "%-22s %-8s %6s %6s %9s %9s %9s %8s %8s\n", "step / run", "ticket", "calls", "tools", "floor", "peak", "growth", "est $", "minutes")
	row := func(t, name string, a *tsAgg, m float64, mok bool) {
		tools := "n/a"
		if a.claude {
			tools = strconv.FormatInt(a.toolCalls, 10)
		}
		fmt.Fprintf(out, "%-22s %-8s %6d %6s %9s %9s %9s %8s %8s\n", name, t, a.calls, tools, tsH(a.floor), tsH(a.peak), tsH(a.growth()), tsUSD(a), tsMinCell(m, mok))
	}
	for i := len(L) - 1; i >= 0; i-- {
		w := s.wins[L[i]-1]
		if w.turns == 0 {
			continue
		}
		for _, st := range tsSteps {
			if a := w.steps[st]; a != nil && a.calls > 0 {
				m, ok := w.stepMinutes(st)
				row(w.ticket, st, a, m, ok)
			}
		}
		for _, r := range w.runs {
			id := r.src.agentID
			if len(id) > 8 {
				id = id[:8]
			}
			m, ok := r.runMinutes()
			row(w.ticket, r.src.role()+" "+id, &r.tsAgg, m, ok)
		}
	}
	fmt.Fprintln(out, "security-review: from the reviewer's finish to its Wrapup Gates row, any reviewer fixes made in between included.")
	fmt.Fprintln(out)
}
