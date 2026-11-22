package board

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"canon/internal/common"
	"canon/internal/events"
	"canon/internal/transcript"
)

// t-0829: `sprint token-spend`, ported from the shell's awk (t-63a7, t-7e26, t-b6ad): where a closed sprint's tokens went, planning
// (sprint.started -> plan.md's Approved: stamp, the spec check included) / implementation (-> the first gate.started that is not the
// spec check) / close (-> sprint.completed), by model, plus the six context numbers per phase and per gate run (calls, input,
// cache-read, cache-write, output, peak context). Canon logs no session tokens, so the calls come from the harnesses' own records,
// read only: Claude Code's transcripts (main loop + subagents/) and Copilot's session record (session.usage_record). A call
// inside two sprints' windows counts once, as overlap. --record (sprint complete's call) writes the one sprint.cost event and one
// gate.cost per subagent run, and prints the cost line. Numbers, ids and model names are kept; never transcript text.

// tsCall is one call: one model request, from a transcript line or a Copilot usage record.
type tsCall struct {
	src             *tsSrc
	model, ts       string   // ts: the first 19 characters of the timestamp, compared as text
	cwd             string   // the cwd's path key
	in, cw, cr, out int64    // fresh input, cache written, cache read, output
	cw5, cw1h       int64    // t-0abe: the cache write's 5-minute and 1-hour parts, when the usage splits it
	tools           []string // t-0abe: the tool name of each distinct tool_use block of the call (its later lines included)
	hit             int      // the 1-based window it belongs to; 0 = overlap
	gate            bool     // a reviewer or evaluator subagent by its meta agentType: the legacy close-gate rule
}

func (c *tsCall) fresh() int64 { return c.in + c.cw } // the old table's "fresh input"

// tsSrc is one transcript file (a main session, a subagent) or one Copilot agent's calls.
type tsSrc struct {
	path      string
	sub       bool   // a subagent, not a main session
	agentType string // from the meta.json (Claude) or subagent.started (Copilot)
	desc      string
	evalDoc   bool   // a Plan agent that read reference/eval.md ran the evaluator
	agentID   string // the id gate.cost is keyed by
	copilot   bool   // a call from Copilot's session record
	floor     int64  // t-0abe: the context of the file's first call
	hasFloor  bool
}

// t-0abe: setFloor keeps a source's first call's context.
func (s *tsSrc) setFloor(c *tsCall) {
	if !s.hasFloor {
		s.floor, s.hasFloor = c.in+c.cr+c.cw, true
	}
}

// role names a subagent run: speccheck, reviewer, evaluator, other, or unknown when nothing says what it was; "" for a main session.
func (s *tsSrc) role() string {
	if !s.sub {
		return ""
	}
	switch s.agentType {
	case "canon-spec-checker":
		return "speccheck"
	case "canon-reviewer":
		return "reviewer"
	case "canon-evaluator":
		return "evaluator"
	case "":
		return "unknown"
	case "Plan":
		if s.evalDoc {
			return "evaluator"
		}
	}
	return "other"
}

func (s *tsSrc) legacyGate() bool {
	return s.agentType == "canon-reviewer" || s.agentType == "canon-evaluator"
}

// tsStat is the six numbers of a set of calls.
type tsStat struct{ calls, in, cr, cw, out, peak int64 }

func (s *tsStat) add(c *tsCall) {
	s.calls++
	s.in += c.in
	s.cr += c.cr
	s.cw += c.cw
	s.out += c.out
	if p := c.in + c.cr + c.cw; p > s.peak {
		s.peak = p
	}
}

type tsRunStat struct {
	src   *tsSrc
	model string // the first call's
	tsAgg
}

// tsWin is one closed sprint's window and what was measured in it.
type tsWin struct {
	ticket, project, raw string // project: the path key; raw: the events' own spelling
	start, gate, end     string
	approved, tier       string
	pre, build           bool
	turns                int
	pf                   map[string]int64 // phase -> fresh + output
	cacheRead            int64
	main                 map[string]*tsStat // plan, build, close: the main session's calls
	runs                 []*tsRunStat       // subagent runs with a call in the window
	spec, gateAgents     int64              // spec-check tokens inside planning; reviewer and evaluator tokens inside the close
	gateFiles            map[*tsSrc]bool
	cost                 *tsEventCost // the window's sprint.cost event, if recorded
	// t-0abe: apprEv is the first plan.approved event (planning's end; plan.md's last stamp moves on a re-approval at close);
	// closeStart the first close.started; revFins the reviewer's gate.finished times; secRow security-review's Wrapup Gates row
	apprEv, closeStart, secRow string
	revFins                    []string
	steps                      map[string]*tsAgg // plan, build, wrapup, security-review, close: the main session's calls
}

type tsEventCost struct{ planning, implementation, gates, cacheRead int64 }

type tsOpts struct {
	last  int
	only  string
	rec   bool
	root  string
	paths []string // the checkout first, then its worktrees
}

var tsTicketRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// tokenSpendCLI: token-spend --project <root> [--worktree <path>]... [--last N] [--ticket <id>] [--record]. The shell passes the physical
// project root and `git worktree list`'s paths.
func tokenSpendCLI(args []string, stdout, stderr io.Writer) int {
	o := tsOpts{last: 10}
	fail := func(m string) int { fmt.Fprintln(stderr, "Error: "+m); return 1 }
	for i := 0; i < len(args); i++ {
		a := args[i]
		val := func() (string, bool) {
			if i+1 >= len(args) {
				return "", false
			}
			i++
			return args[i], true
		}
		switch a {
		case "--last", "--ticket", "--project", "--worktree":
			v, ok := val()
			if !ok {
				return fail(a + " requires a value")
			}
			switch a {
			case "--last":
				n, err := strconv.Atoi(v)
				if err != nil || n < 1 || !regexp.MustCompile(`^[1-9][0-9]*$`).MatchString(v) {
					return fail("--last must be a positive whole number")
				}
				o.last = n
			case "--ticket":
				o.only = v
			case "--project":
				o.root = fromMSYS(v) // t-2986: Git Bash passes /c/...; the transcript folder is named from C:/...
			default:
				o.paths = append(o.paths, fromMSYS(v))
			}
		case "--record":
			o.rec = true
		case "-h", "--help":
			fmt.Fprintln(stdout, "Usage: sprint token-spend [--last N] [--ticket <id> [--record]]")
			return 0
		default:
			return fail("unknown argument: " + a)
		}
	}
	if o.rec && !tsTicketRe.MatchString(o.only) {
		return fail("--record needs --ticket <id>")
	}
	if o.root == "" {
		return fail("--project <root> is required")
	}
	o.paths = append([]string{o.root}, withoutPath(o.paths, o.root)...)
	tokenSpend(o, stdout)
	return 0
}

func withoutPath(ps []string, root string) []string {
	var out []string
	for _, p := range ps {
		if p != "" && p != root {
			out = append(out, p)
		}
	}
	return out
}

var tsNonAlnum = regexp.MustCompile(`[^A-Za-z0-9]`)

// tsEncode is Claude Code's name for a project's transcript folder: its native path, every other character a '-'.
func tsEncode(p string) string { return tsNonAlnum.ReplaceAllString(p, "-") }

func claudeHome() string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".claude")
}

func copilotHome() string {
	if d := os.Getenv("COPILOT_HOME"); d != "" {
		return d
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".copilot")
}

func isFile(p string) bool { st, err := os.Stat(p); return err == nil && st.Mode().IsRegular() }

// rawField is the first "name":"value" in a line of text, value up to the next quote; "" when absent. Events are matched as text, not
// decoded: a hostile line (a control byte in a project) is still read, as the awk did.
func rawField(s, name string) string {
	key := `"` + name + `":"`
	for from := 0; ; {
		i := strings.Index(s[from:], key)
		if i < 0 {
			return ""
		}
		start := from + i + len(key)
		if j := strings.IndexByte(s[start:], '"'); j >= 0 {
			return s[start : start+j]
		}
		from = start
	}
}

// rawNum is the first "name":N or "name":"N" in a line of text (the leading number of the value); 0 when absent.
func rawNum(s, name string) int64 {
	i := strings.Index(s, `"`+name+`":`)
	if i < 0 {
		return 0
	}
	v := strings.TrimPrefix(s[i+len(name)+3:], `"`)
	if j := strings.IndexAny(v, `",}`); j >= 0 {
		v = v[:j]
	}
	end := 0
	for end < len(v) && (v[end] >= '0' && v[end] <= '9' || end == 0 && (v[end] == '-' || v[end] == '+') || v[end] == '.') {
		end++
	}
	f, _ := strconv.ParseFloat(v[:end], 64)
	return int64(f)
}

var tsCtrl = regexp.MustCompile(`[\x01-\x1f\x7f]`)

func tsClean(x string) string {
	x = tsCtrl.ReplaceAllString(x, "?")
	if len(x) > 120 {
		return x[:120] + "..."
	}
	return x
}

func tsH(v int64) string {
	switch {
	case v >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(v)/1e6)
	case v >= 1000:
		return fmt.Sprintf("%.0fk", float64(v)/1e3)
	}
	return strconv.FormatInt(v, 10)
}

// tsEventFiles lists the activity log's day files, oldest first: *.jsonl and the gzipped rotated *.jsonl.gz.
func tsEventFiles(dir string) []string {
	var fs []string
	for _, pat := range []string{"*.jsonl", "*.jsonl.gz"} {
		m, _ := filepath.Glob(filepath.Join(dir, pat))
		for _, f := range m {
			if isFile(f) {
				fs = append(fs, f)
			}
		}
	}
	sort.Strings(fs)
	return fs
}

// tsReadEvents calls fn with each event line of the files; a file that cannot be read, or the rest of a corrupt gzip, is skipped.
func tsReadEvents(files []string, fn func(line string)) {
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			continue
		}
		var r io.Reader = fh
		if strings.HasSuffix(f, ".gz") {
			gz, err := gzip.NewReader(fh)
			if err != nil {
				fh.Close()
				continue
			}
			r = gz
		}
		br := bufio.NewReaderSize(r, 1<<20)
		for {
			line, more := transcript.NextLine(br)
			if !more {
				break
			}
			if line != nil {
				fn(string(line))
			}
		}
		fh.Close()
	}
}

var tsKinds = []string{`"kind":"sprint.started"`, `"kind":"gate.started"`, `"kind":"sprint.completed"`, `"kind":"sprint.cost"`, `"kind":"gate.cost"`,
	`"kind":"plan.approved"`, `"kind":"close.started"`, `"kind":"gate.finished"`, `"kind":"wrapup.gate_finished"`, `"kind":"step.cost"`} // t-0abe: step bounds

// tokenSpend prints the table, or with o.rec records the cost.
func tokenSpend(o tsOpts, out io.Writer) {
	cfg := claudeHome()
	evdir := filepath.Join(events.Home(), "events")
	ok := map[string]bool{} // the project's path keys
	for _, p := range o.paths {
		if p != "" {
			ok[common.PathKey(p)] = true
		}
	}
	// Claude Code's transcripts for the checkout and its worktrees; subagents first, so a message id seen in both is claimed by its subagent.
	var mains, subs []string
	for _, p := range o.paths {
		enc := filepath.Join(cfg, "projects", tsEncode(p))
		g, _ := filepath.Glob(filepath.Join(enc, "*", "subagents", "agent-*.jsonl"))
		for _, f := range g {
			if isFile(f) {
				subs = append(subs, f)
			}
		}
		g, _ = filepath.Glob(filepath.Join(enc, "*.jsonl"))
		for _, f := range g {
			if isFile(f) {
				mains = append(mains, f)
			}
		}
	}
	notr := ""
	if len(mains) == 0 && len(subs) == 0 {
		notr = "No Claude Code transcripts for " + o.root + " under " + filepath.Join(cfg, "projects") + ": token-spend reads only Claude Code's (other harnesses keep none it can read)."
	}
	evfiles := tsEventFiles(evdir)
	if len(evfiles) == 0 {
		if !o.rec {
			if notr != "" {
				fmt.Fprintln(out, notr)
			} else {
				fmt.Fprintln(out, "No canon events under "+evdir+": sprint start and complete times are unknown.")
			}
		}
		return
	}

	// Sprint windows from the events, oldest file first.
	var wins []*tsWin
	costs := map[string]*tsEventCost{}
	gateCosted := map[string]bool{}
	stepCosted := map[string]bool{} // t-0abe: ticket + project + step of each recorded step.cost
	var dropped []string
	droppedSeen := map[string]bool{}
	open := map[string]*tsWin{} // key: ticket + sep + project key
	tsReadEvents(evfiles, func(line string) {
		kind := ""
		for _, k := range tsKinds {
			if strings.Contains(line, k) {
				kind = k[len(`"kind":"`) : len(k)-1]
				break
			}
		}
		if kind == "" {
			return
		}
		if kind == "gate.cost" {
			if id := rawField(line, "agent_id"); id != "" {
				gateCosted[id] = true
			}
			return
		}
		rawp := rawField(line, "project")
		pr := common.PathKey(rawp)
		if !ok[pr] {
			// t-c8c6: a dropped project is kept (first 3, control bytes shown as ?) for the no-match message
			if rawp != "" && !droppedSeen[rawp] && len(droppedSeen) < 3 {
				droppedSeen[rawp] = true
				dropped = append(dropped, tsCtrl.ReplaceAllString(rawp, "?"))
			}
			return
		}
		t, ts := rawField(line, "ticket"), rawField(line, "ts")
		if len(ts) > 19 {
			ts = ts[:19]
		}
		key := t + "\x1c" + pr
		w := open[key]
		switch kind {
		case "step.cost":
			stepCosted[key+"\x1c"+rawField(line, "step")] = true
		case "plan.approved":
			if w != nil && w.apprEv == "" {
				w.apprEv = ts
			}
		case "close.started":
			if w != nil && w.closeStart == "" {
				w.closeStart = ts
			}
		case "gate.finished":
			if w != nil && rawField(line, "role") == "reviewer" {
				w.revFins = append(w.revFins, ts)
			}
		case "wrapup.gate_finished":
			if w != nil && rawField(line, "gate") == "security-review" && rawField(line, "result") == "ran" {
				w.secRow = ts
			}
		case "sprint.cost":
			costs[key] = &tsEventCost{rawNum(line, "planning"), rawNum(line, "implementation"), rawNum(line, "gates"), rawNum(line, "cache_read")}
		case "sprint.started":
			if open[key] == nil {
				open[key] = &tsWin{ticket: t, project: pr, raw: rawp, start: ts}
			}
		case "gate.started":
			if w := open[key]; w != nil && w.gate == "" && rawField(line, "role") != "speccheck" { // t-9b13: the spec check runs before approval, in planning
				w.gate = ts
			}
		default: // sprint.completed
			if w := open[key]; w != nil {
				w.end = ts
				wins = append(wins, w)
				delete(open, key)
			}
		}
	})
	if len(wins) == 0 {
		if o.rec {
			return
		}
		if notr == "" && len(dropped) > 0 {
			var pl []string
			for _, p := range o.paths {
				pl = append(pl, tsCtrl.ReplaceAllString(p, ""))
			}
			plist := strings.Join(pl, ", ")
			if len(plist) > 2000 {
				plist = plist[:2000]
			}
			fmt.Fprintf(out, "No completed sprints in %s for %s. Event projects that did not match: %s; path list: %s\n", evdir, o.root, strings.Join(dropped, ", "), plist)
		} else if notr != "" {
			fmt.Fprintln(out, notr)
		} else {
			fmt.Fprintf(out, "No completed sprints in %s for %s.\n", evdir, o.root)
		}
		return
	}
	for _, w := range wins {
		w.cost = costs[w.ticket+"\x1c"+w.project]
		w.pf, w.main, w.gateFiles, w.steps = map[string]int64{}, map[string]*tsStat{}, map[*tsSrc]bool{}, map[string]*tsAgg{}
	}

	// Approval time and tier from each window ticket's plan.md (the Approved: stamp exists since 0.30.6).
	plans := map[string][2]string{}
	for _, w := range wins {
		if _, seen := plans[w.ticket]; seen || !tsTicketRe.MatchString(w.ticket) {
			continue
		}
		if a, t, ok := tsPlan(filepath.Join(o.root, ".tickets", w.ticket, "plan.md")); ok {
			plans[w.ticket] = [2]string{a, t}
		}
	}
	for _, w := range wins {
		if p, ok := plans[w.ticket]; ok {
			w.approved = p[0]
			w.tier = p[1]
			if strings.HasPrefix(w.tier, "high") {
				w.tier = "high-risk"
			}
		}
	}

	for _, w := range wins {
		if w.apprEv != "" { // t-0abe: the first approval event wins over plan.md's stamp, which a re-approval at close rewrites
			w.approved = w.apprEv
		}
	}
	st := &tsState{o: o, out: out, wins: wins, seen: map[string]bool{}, first: map[string]string{}, byMsg: map[string]*tsCall{},
		toolSeen: map[string]bool{}, prices: tsLoadPrices()}
	for _, f := range subs {
		st.readClaude(f, true)
	}
	for _, f := range mains {
		st.readClaude(f, false)
	}
	st.readCopilot()
	st.assign()
	st.classify()
	st.countUsers()
	if o.rec {
		st.denied = tsDenied(o.root)
		st.record(gateCosted, stepCosted)
		return
	}
	st.print(out)
}

// tsPlan reads the Approved: stamp's time and the tier word of a plan.md; ok is false when the file cannot be read.
func tsPlan(path string) (approved, tier string, ok bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
	gotTier := false
	for sc.Scan() {
		l := sc.Text()
		if strings.HasPrefix(l, "Approved: sha256:") {
			if fs := strings.Fields(l); len(fs) >= 3 {
				approved = fs[2]
			} else {
				approved = ""
			}
		}
		if !gotTier && strings.HasPrefix(l, "Tier:") {
			gotTier = true
			v := strings.TrimLeft(strings.TrimPrefix(l, "Tier:"), " ")
			if i := strings.IndexFunc(v, func(r rune) bool { return !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r == '-') }); i >= 0 {
				v = v[:i]
			}
			tier = v
		}
	}
	return approved, tier, true
}

// tsState is one token-spend run.
type tsState struct {
	o     tsOpts
	out   io.Writer
	pk    []string // the path keys of o.paths
	wins  []*tsWin
	calls []*tsCall // in read order, with the ones that match no sprint dropped by assign
	seen  map[string]bool
	first map[string]string // project path key -> the oldest Claude Code call
	nread int
	cwl   []string // the first three distinct cwd keys read, and their spelling
	cwr   []string
	cwset map[string]bool
	// results
	groups      []string // (hit, phase, model) in first-seen order
	gn, gf      map[string]int64
	gc, go_     map[string]int64
	bph         map[string]int64 // (hit, phase, model) -> fresh + output, for the builder
	models      map[int][]string // hit -> models in first-seen order
	modelTk     map[string]int64 // (hit, model) -> fresh + output
	kept        []*tsCall
	copilotUsed bool // a Copilot call fell inside a sprint
	// t-0abe
	byMsg    map[string]*tsCall // msg_ id -> its call, for the tool_use blocks on the id's later lines
	toolSeen map[string]bool    // tool_use ids counted
	users    []tsUser           // the person's prompts in main sessions
	prices   tsPrices
	denied   string
}

type tsUser struct{ ts, cwd string }

func (s *tsState) winpath(c string) string {
	best := ""
	if s.pk == nil {
		for _, q := range s.o.paths {
			s.pk = append(s.pk, common.PathKey(q))
		}
	}
	for _, k := range s.pk {
		if (c == k || strings.HasPrefix(c, k+"/")) && len(k) > len(best) {
			best = k
		}
	}
	return best
}

// readClaude reads one transcript file. A line that is not an assistant line, has no msg_ id or no usage, or repeats an id, is not a call.
func (s *tsState) readClaude(path string, sub bool) {
	src := &tsSrc{path: path, sub: sub}
	if sub {
		src.agentID = strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "agent-"), ".jsonl")
		if b, err := os.ReadFile(strings.TrimSuffix(path, ".jsonl") + ".meta.json"); err == nil {
			m := strings.ReplaceAll(string(b), "\n", "")
			src.agentType, src.desc = metaField(m, "agentType"), metaField(m, "description")
			if src.agentType == "Plan" { // the close check's own test (tools/sprint, the Plan fallback): reference/eval.md anywhere in its transcript
				transcript.EachLine(path, func(line []byte) {
					src.evalDoc = src.evalDoc || bytes.Contains(line, []byte("reference/eval.md"))
				})
			}
		}
	}
	var mine []*tsCall
	transcript.EachLine(path, func(line []byte) {
		if !bytes.Contains(line, []byte(`"type":"assistant"`)) {
			if !sub && bytes.Contains(line, []byte(`"type":"user"`)) {
				if u, ok := transcript.ParseUser(line); ok && u.Prompt {
					ts := u.TS
					if len(ts) > 19 {
						ts = ts[:19]
					}
					s.users = append(s.users, tsUser{ts, common.PathKey(u.CWD)})
				}
			}
			return
		}
		a, ok := transcript.ParseAssistant(line)
		if !ok || !strings.HasPrefix(a.ID, "msg_") {
			return
		}
		if s.seen[a.ID] { // t-0abe: each content block is its own line under the same id: its tool_use blocks belong to the first line's call
			if c := s.byMsg[a.ID]; c != nil {
				s.addTools(c, a)
			}
			return
		}
		if !a.HasUsage {
			return
		}
		s.seen[a.ID] = true
		ts := a.TS
		if len(ts) > 19 {
			ts = ts[:19]
		}
		cw := common.PathKey(a.CWD)
		s.nread++
		if !s.cwset[cw] && len(s.cwl) < 3 {
			if s.cwset == nil {
				s.cwset = map[string]bool{}
			}
			s.cwset[cw] = true
			s.cwl = append(s.cwl, cw)
			s.cwr = append(s.cwr, a.CWD)
		}
		if pr := s.winpath(cw); pr != "" && (s.first[pr] == "" || ts < s.first[pr]) {
			s.first[pr] = ts
		}
		c := &tsCall{src: src, model: a.Model, ts: ts, cwd: cw, in: a.In, cw: a.CacheWrite, cr: a.CacheRead, out: a.Out, cw5: a.CacheWrite5m, cw1h: a.CacheWrite1h}
		src.setFloor(c)
		s.byMsg[a.ID] = c
		s.addTools(c, a)
		mine = append(mine, c)
	})
	s.calls = append(s.calls, mine...)
}

// addTools adds a line's tool_use blocks to its call, each tool_use id once.
func (s *tsState) addTools(c *tsCall, a transcript.Assistant) {
	for i, id := range a.ToolUses {
		if id != "" {
			if s.toolSeen[id] {
				continue
			}
			s.toolSeen[id] = true
		}
		c.tools = append(c.tools, a.ToolNames[i])
	}
}

// readCopilot adds Copilot's calls: <COPILOT_HOME>/session-state/<sid>/events.jsonl, for the sessions whose recorded working folder is
// the project or one of its worktrees and that were written after the oldest shown sprint began (t-4fc7: not the oldest in the whole
// log, so a close reads only its own sprint's sessions). A usage_record with an agentId is that subagent's call (subagent.started
// names its agent type); one without is the main session's. Copilot's inputTokens holds the cache counts, so the fresh input is what
// is left.
func (s *tsState) readCopilot() {
	minStart := ""
	for _, i := range s.shown() {
		if w := s.wins[i-1]; minStart == "" || w.start < minStart {
			minStart = w.start
		}
	}
	if minStart == "" {
		return // no sprint is shown or recorded: no Copilot call can count
	}
	since, err := time.Parse("2006-01-02T15:04:05", minStart)
	dirs, derr := os.ReadDir(filepath.Join(copilotHome(), "session-state"))
	if derr != nil {
		return
	}
	for _, d := range dirs {
		p := filepath.Join(copilotHome(), "session-state", d.Name(), "events.jsonl")
		fi, lerr := os.Lstat(p)
		if !d.IsDir() || lerr != nil || !fi.Mode().IsRegular() {
			continue
		}
		if err == nil && fi.ModTime().Before(since.Add(-time.Minute)) {
			continue // last written before the oldest sprint began
		}
		s.readCopilotFile(p)
	}
}

func (s *tsState) readCopilotFile(path string) {
	cwd, started := "", false
	srcs := map[string]*tsSrc{}
	main := &tsSrc{path: path, copilot: true}
	types := map[string]string{}
	var recs []copilotLine
	transcript.EachLine(path, func(line []byte) {
		isStart := bytes.Contains(line, []byte(`"type":"session.start"`))
		isSub := bytes.Contains(line, []byte(`"type":"subagent.started"`))
		isUse := bytes.Contains(line, []byte(`"type":"session.usage_record"`))
		if !isStart && !isSub && !isUse {
			return
		}
		l, ok := parseCopilotLine(line)
		if !ok {
			return
		}
		switch {
		case isStart && l.Type == "session.start" && !started:
			started = true
			cwd = l.Data.Context.CWD
			if s.winpath(common.PathKey(cwd)) == "" {
				cwd = l.Data.Context.GitRoot
			}
		case isSub && l.Type == "subagent.started" && l.AgentID != "":
			types[l.AgentID] = l.Data.AgentType
		case isUse && l.Type == "session.usage_record" && l.Data.Usage != nil:
			recs = append(recs, l)
		}
	})
	key := common.PathKey(cwd)
	if !started || s.winpath(key) == "" {
		return
	}
	for _, l := range recs {
		u := l.Data.Usage
		if u.APICallID != "" {
			if s.seen["c:"+u.APICallID] {
				continue
			}
			s.seen["c:"+u.APICallID] = true
		}
		src := main
		if l.AgentID != "" {
			if srcs[l.AgentID] == nil {
				srcs[l.AgentID] = &tsSrc{path: path, sub: true, agentID: l.AgentID, agentType: types[l.AgentID], copilot: true}
			}
			src = srcs[l.AgentID]
		}
		ts := l.Timestamp
		if len(ts) > 19 {
			ts = ts[:19]
		}
		model := u.ResponseModel
		if model == "" {
			model = u.Model
		}
		fresh := u.InputTokens - u.CacheReadTokens - u.CacheWriteTokens
		if fresh < 0 {
			fresh = 0
		}
		c := &tsCall{src: src, model: model, ts: ts, cwd: key, in: fresh, cw: u.CacheWriteTokens, cr: u.CacheReadTokens, out: u.OutputTokens}
		src.setFloor(c)
		s.calls = append(s.calls, c)
	}
}

var tsTicketInDesc = regexp.MustCompile(`t-[0-9a-z]+`)

// assign gives each call its window: a gate names its ticket in its description, any other call belongs to the one window of its
// project it falls in; a call in none is dropped, a call in two is overlap. Kept calls are given a phase by classify.
func (s *tsState) assign() {
	for _, c := range s.calls {
		pr := s.winpath(c.cwd)
		c.gate = c.src.legacyGate()
		hit := 0
		if c.gate {
			if tk := tsTicketInDesc.FindString(c.src.desc); tk != "" {
				for w := len(s.wins); w >= 1; w-- {
					if s.wins[w-1].ticket == tk && s.wins[w-1].project == pr {
						hit = w
						break
					}
				}
			}
		}
		if hit == 0 {
			var n int
			if hit, n = s.winOf(pr, c.ts); n == 0 {
				continue
			}
		}
		c.hit = hit
		s.kept = append(s.kept, c)
		// A gate dispatched before its gate.started event moves the close's start back.
		if hit > 0 && c.gate {
			if w := s.wins[hit-1]; w.gate == "" || c.ts < w.gate {
				w.gate = c.ts
			}
		}
	}
}

// winOf is the one window of project pr that ts falls in (n 1); n 0 for none, n > 1 (hit 0) for overlap.
func (s *tsState) winOf(pr, ts string) (hit, n int) {
	for i, w := range s.wins {
		if w.project == pr && w.start <= ts && ts < w.end {
			n++
			hit = i + 1
		}
	}
	if n > 1 {
		hit = 0
	}
	return hit, n
}

// phaseOf: the old table's phases: planning, implementation, gates ("close" in the labels), build (no Approved: time), overlap.
func (s *tsState) phaseOf(c *tsCall) string {
	if c.hit == 0 {
		return "overlap"
	}
	w := s.wins[c.hit-1]
	a := w.approved
	if len(a) > 19 {
		a = a[:19]
	}
	if a > w.end {
		a = ""
	} else if a != "" && a < w.start {
		w.pre = true
	}
	if a == "" {
		w.build = true
	}
	switch ca := w.closeAt(); { // t-0abe: the close begins at close.started (the inline Wrapup gates are close, not build)
	case c.gate || (ca != "" && c.ts >= ca):
		return "gates"
	case a == "":
		return "build"
	case c.ts < a:
		return "planning"
	}
	return "implementation"
}

var tsMainKey = map[string]string{"planning": "plan", "implementation": "build", "build": "build", "gates": "close"}

func (s *tsState) classify() {
	s.gn, s.gf, s.gc, s.go_, s.bph, s.modelTk = map[string]int64{}, map[string]int64{}, map[string]int64{}, map[string]int64{}, map[string]int64{}, map[string]int64{}
	s.models = map[int][]string{}
	runs := map[*tsSrc]*tsRunStat{}
	seenGroup := map[string]bool{}
	for _, c := range s.kept {
		ph := s.phaseOf(c)
		k := fmt.Sprintf("%d\x1c%s\x1c%s", c.hit, ph, c.model)
		if !seenGroup[k] {
			seenGroup[k] = true
			s.groups = append(s.groups, k)
		}
		s.gn[k]++
		s.gf[k] += c.fresh()
		s.gc[k] += c.cr
		s.go_[k] += c.out
		if c.hit == 0 {
			continue
		}
		w := s.wins[c.hit-1]
		w.pf[ph] += c.fresh() + c.out
		w.cacheRead += c.cr
		w.turns++
		if c.src.copilot {
			s.copilotUsed = true
		}
		mk := fmt.Sprintf("%d\x1c%s", c.hit, c.model)
		if _, ok := s.modelTk[mk]; !ok {
			s.models[c.hit] = append(s.models[c.hit], c.model)
		}
		s.modelTk[mk] += c.fresh() + c.out
		s.bph[k] += c.fresh() + c.out
		if c.gate {
			w.gateFiles[c.src] = true
		}
		role := c.src.role()
		switch {
		case role == "":
			m := w.main[tsMainKey[ph]]
			if m == nil {
				m = &tsStat{}
				w.main[tsMainKey[ph]] = m
			}
			m.add(c)
			st := w.stepOf(ph, c.ts)
			if w.steps[st] == nil {
				w.steps[st] = &tsAgg{}
			}
			w.steps[st].add(c, s.prices)
		default:
			r := runs[c.src]
			if r == nil || !hasRun(w, r) {
				r = &tsRunStat{src: c.src, model: c.model}
				runs[c.src] = r
				w.runs = append(w.runs, r)
			}
			r.add(c, s.prices)
			if role == "speccheck" && ph == "planning" {
				w.spec += c.fresh() + c.out
			}
			if c.gate { // the legacy rule (agentType canon-reviewer or canon-evaluator), the one gate_runs counts by
				w.gateAgents += c.fresh() + c.out
			}
		}
	}
}

// countUsers gives each prompt of a main session the step its time falls in (a step with no call keeps no prompt).
func (s *tsState) countUsers() {
	for _, u := range s.users {
		hit, n := s.winOf(s.winpath(u.cwd), u.ts)
		if n != 1 {
			continue
		}
		w := s.wins[hit-1]
		if a := w.steps[w.stepOf(s.phaseOf(&tsCall{src: &tsSrc{}, ts: u.ts, hit: hit}), u.ts)]; a != nil {
			a.turns++
		}
	}
}

func hasRun(w *tsWin, r *tsRunStat) bool {
	for _, x := range w.runs {
		if x == r {
			return true
		}
	}
	return false
}

// shown: the last N windows, or the one ticket asked for, newest first.
func (s *tsState) shown() []int {
	var l []int
	for w := len(s.wins); w >= 1 && len(l) < s.o.last; w-- {
		if s.o.only == "" || s.wins[w-1].ticket == s.o.only {
			l = append(l, w)
		}
	}
	return l
}

func tsTierOf(w *tsWin) string {
	if w.tier == "" {
		return "-"
	}
	return w.tier
}

func (s *tsState) print(out io.Writer) {
	L := s.shown()
	if len(L) == 0 {
		if s.o.only == "" {
			fmt.Fprintln(out, "No completed sprints.")
		} else {
			fmt.Fprintln(out, "No completed sprint for "+s.o.only+".")
		}
		return
	}
	any := false
	for _, w := range L {
		if s.wins[w-1].turns > 0 || s.wins[w-1].cost != nil {
			any = true
		}
	}
	if !any {
		fmt.Fprintln(out, "No transcript turns inside these sprints (Claude Code keeps about 9 days of transcripts).")
		// t-134b: when turns were read but none matched a sprint, say what was compared: a spelling bug (a Windows drive path) names itself
		if s.nread > 0 {
			var cl, rl, pl, el, gl []string
			for i := range s.cwl {
				cl = append(cl, tsClean(s.cwl[i]))
				rl = append(rl, tsClean(s.cwr[i]))
			}
			pseen, eseen := map[string]bool{}, map[string]bool{}
			for _, w := range s.wins {
				if !pseen[w.project] && len(pseen) < 3 {
					pseen[w.project] = true
					pl = append(pl, tsClean(w.project))
				}
				if !eseen[w.raw] && len(eseen) < 3 {
					eseen[w.raw] = true
					el = append(el, tsClean(w.raw))
				}
			}
			for i, p := range s.o.paths {
				if i < 3 {
					gl = append(gl, tsClean(p))
				}
			}
			fmt.Fprintf(out, "  read %d turns in %s; the sprints ran in %s\n", s.nread, strings.Join(cl, ", "), strings.Join(pl, ", "))
			fmt.Fprintf(out, "  raw spellings: cwd %s; matched event project %s; path list %s\n", strings.Join(rl, ", "), strings.Join(el, ", "), strings.Join(gl, ", "))
		}
		return
	}
	from := "Claude Code transcripts"
	if s.copilotUsed {
		from += " and Copilot's session record"
	}
	fmt.Fprintln(out, "Token spend per closed sprint (fresh input + output; cache reads apart), from "+from+":")
	fmt.Fprintf(out, "%-8s %-10s %10s %15s %10s %11s\n", "ticket", "tier", "planning", "implementation", "close", "cache-read")
	for i := len(L) - 1; i >= 0; i-- {
		w := s.wins[L[i]-1]
		if w.turns == 0 && w.cost != nil {
			c := w.cost
			fmt.Fprintf(out, "%-8s %-10s %10s %15s %10s %11s  (from the sprint.cost event)\n", w.ticket, tsTierOf(w), tsH(c.planning), tsH(c.implementation), tsH(c.gates), tsH(c.cacheRead))
			continue
		}
		if w.turns == 0 {
			fmt.Fprintf(out, "%-8s %-10s  no transcript turns (older than the transcripts kept)\n", w.ticket, tsTierOf(w))
			continue
		}
		pl, im := "-", ""
		if w.build {
			im = tsH(w.pf["build"]) + "*"
		} else {
			pl = tsH(w.pf["planning"])
			if w.pre {
				pl += "^"
			}
			if w.spec > 0 {
				pl += " (spec " + tsH(w.spec) + ")"
			}
			im = tsH(w.pf["implementation"])
		}
		partial := ""
		if f := s.first[w.project]; f != "" && w.start < f {
			partial = "  ~ partial"
		}
		fmt.Fprintf(out, "%-8s %-10s %10s %15s %10s %11s%s\n", w.ticket, tsTierOf(w), pl, im, tsH(w.pf["gates"]), tsH(w.cacheRead), partial)
	}
	fmt.Fprintln(out)
	// Overlap calls belong to no one sprint; they show only in the full listing.
	in := map[int]bool{}
	for _, w := range L {
		in[w] = true
	}
	var gorder []string
	bn, bf, bc, bo := map[string]int64{}, map[string]int64{}, map[string]int64{}, map[string]int64{}
	for _, k := range s.groups {
		p := strings.Split(k, "\x1c")
		h, _ := strconv.Atoi(p[0])
		if !in[h] && !(h == 0 && s.o.only == "") {
			continue
		}
		g := p[1] + "\x1c" + p[2]
		if _, ok := bn[g]; !ok {
			gorder = append(gorder, g)
		}
		bn[g] += s.gn[k]
		bf[g] += s.gf[k]
		bc[g] += s.gc[k]
		bo[g] += s.go_[k]
	}
	fmt.Fprintln(out, "By phase and model, the sprints above:")
	fmt.Fprintf(out, "%-15s %-22s %6s %10s %11s %9s\n", "phase", "model", "turns", "fresh-in", "cache-read", "output")
	for _, g := range gorder {
		p := strings.Split(g, "\x1c")
		ph := p[0]
		if ph == "gates" {
			ph = "close"
		}
		fmt.Fprintf(out, "%-15s %-22s %6d %10s %11s %9s\n", ph, p[1], bn[g], tsH(bf[g]), tsH(bc[g]), tsH(bo[g]))
	}
	fmt.Fprintln(out)
	s.printContext(out, L)
	s.printSteps(out, L)
	fmt.Fprintln(out, "* build: no Approved: time in plan.md (before 0.30.6), so planning and implementation are one number.")
	fmt.Fprintln(out, "^ approved before sprint start: the plan was written outside this sprint.")
	fmt.Fprintln(out, "~ partial: the sprint began before the oldest transcript kept. overlap: a turn inside two sprints, counted once.")
}

func tsCell(st *tsStat, f func(*tsStat) int64) string {
	if st == nil || st.calls == 0 {
		return "n/a"
	}
	return tsH(f(st))
}

// printContext prints each shown sprint's per-phase (main session) and per-run context cost.
func (s *tsState) printContext(out io.Writer, L []int) {
	fmt.Fprintln(out, "Context cost per phase (main session) and per subagent run, the sprints above (n/a: no calls):")
	fmt.Fprintf(out, "%-22s %-8s %6s %9s %11s %12s %9s %9s\n", "phase / run", "ticket", "calls", "input", "cache-read", "cache-write", "output", "peak")
	row := func(t, name string, st *tsStat) {
		fmt.Fprintf(out, "%-22s %-8s %6s %9s %11s %12s %9s %9s\n", name, t, tsCell(st, func(x *tsStat) int64 { return x.calls }),
			tsCell(st, func(x *tsStat) int64 { return x.in }), tsCell(st, func(x *tsStat) int64 { return x.cr }),
			tsCell(st, func(x *tsStat) int64 { return x.cw }), tsCell(st, func(x *tsStat) int64 { return x.out }), tsCell(st, func(x *tsStat) int64 { return x.peak }))
	}
	for i := len(L) - 1; i >= 0; i-- {
		w := s.wins[L[i]-1]
		if w.turns == 0 {
			continue
		}
		for _, p := range []string{"plan", "build", "close"} {
			row(w.ticket, p+" (main)", w.main[p])
		}
		for _, r := range w.runs {
			id := r.src.agentID
			if len(id) > 8 {
				id = id[:8]
			}
			row(w.ticket, r.src.role()+" "+id, &r.tsStat)
		}
	}
	fmt.Fprintln(out)
}

var tsMetaRe = map[string]*regexp.Regexp{}

// metaField is a string field of a subagent's meta.json, with the spacing the close check's grep tolerates around the colon.
func metaField(meta, name string) string {
	re, ok := tsMetaRe[name]
	if !ok {
		re = regexp.MustCompile(`"` + name + `"\s*:\s*"([^"]*)"`)
		tsMetaRe[name] = re
	}
	if m := re.FindStringSubmatch(meta); m != nil {
		return m[1]
	}
	return ""
}
