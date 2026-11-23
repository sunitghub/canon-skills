package board

import (
	"bufio"
	"canon/internal/common"
	"canon/internal/transcript"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// t-4084: a close gate under Copilot CLI has no write tool (Copilot maps a custom agent's tools through aliases, and canon's
// gates list none that writes), so it returns its report as its final message. Copilot keeps that message in its own session
// record, <COPILOT_HOME>/session-state/<sid>/events.jsonl: the dispatch is a `task` tool call (tool.execution_start, with
// arguments.agent_type and arguments.prompt), subagent.started names the agent for the same toolCallId, and the gate's final
// message is that toolCallId's tool.execution_complete result.content. copilot-report prints the report from that record, as
// transcript-report does from Claude Code's (t-ff14): `sprint relay-report` writes it, and the close check verifies a report
// against it. It only reads Copilot's files.

// copilotLine is the part of an events.jsonl line the reader needs; everything else is ignored.
type copilotLine struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	AgentID   string `json:"agentId"` // set on every event a subagent produces, and on its subagent.started
	Data      struct {
		ToolCallID string `json:"toolCallId"`
		ToolName   string `json:"toolName"`
		AgentType  string `json:"agentType"`
		Content    string `json:"content"` // assistant.message text
		Success    *bool  `json:"success"`
		Arguments  struct {
			AgentType string `json:"agent_type"`
			Prompt    string `json:"prompt"`
		} `json:"arguments"`
		Result struct {
			Content string `json:"content"`
		} `json:"result"`
		// t-0829 (token-spend): session.start's working folder, and one model call's tokens in session.usage_record. inputTokens
		// is the whole prompt: it already holds the cache read and write counts.
		Context struct {
			CWD     string `json:"cwd"`
			GitRoot string `json:"gitRoot"`
		} `json:"context"`
		Usage *struct {
			Model            string `json:"model"`
			ResponseModel    string `json:"responseModel"`
			InputTokens      int64  `json:"inputTokens"`
			OutputTokens     int64  `json:"outputTokens"`
			CacheReadTokens  int64  `json:"cacheReadTokens"`
			CacheWriteTokens int64  `json:"cacheWriteTokens"`
			APICallID        string `json:"apiCallId"`
		} `json:"usage"`
	} `json:"data"`
}

// parseCopilotLine decodes one events.jsonl line; ok is false for a line that is not JSON (skipped, never fatal).
func parseCopilotLine(b []byte) (copilotLine, bool) {
	var l copilotLine
	if json.Unmarshal(b, &l) != nil {
		return copilotLine{}, false
	}
	return l, true
}

// copilotQuery says which gate result to find.
type copilotQuery struct {
	Agent  string // canon-evaluator or canon-reviewer
	Ticket string
	Proto  string // reference/eval.md or reference/review.md
	Prefix string // the report's first line: evaluator-run-id: or # Review Notes
	Second bool   // the second evaluator: its prompt names .tickets/<id>/eval-report-2.md
	Record bool   // the close check: the gate's whole record (its raw lines), not the report
	Usage  bool   // t-46df: the gate's tokens and minutes ("<tokens>\t<minutes>"), for `sprint subagent-log` under Copilot
	From   time.Time
	To     time.Time
}

// copilotTruncated is Copilot's notice when it saved a long tool output to a file instead of keeping it: such a text is not the whole report.
const copilotTruncated = "Output too large"

// copilotFind returns the report (or, with Record, the gate's raw record) from the newest matching task (by its result event's own
// timestamp) in every session file under home/session-state. recognised is false when no session-state folder holds an events.jsonl.
// When nothing is found, why says which check failed (t-2986): the newest matching task's, else the closest miss (copilotMiss).
func copilotFind(home string, q copilotQuery) (out string, found, recognised bool, why string) {
	dirs, err := os.ReadDir(filepath.Join(home, "session-state"))
	if err != nil {
		return "", false, false, ""
	}
	var best time.Time
	seen := false
	miss := copilotMiss{why: fmt.Sprintf("no finished %s task in the window", q.Agent)}
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		p := filepath.Join(home, "session-state", d.Name(), "events.jsonl")
		fi, err := os.Lstat(p)
		if err != nil || !fi.Mode().IsRegular() {
			continue
		}
		recognised = true
		// The newest matching dispatch decides, whatever it returned: an older run's report never stands in for a newer run
		// that failed or returned only a summary (it would overwrite a fresh report with a stale one).
		r, at, cand, ok, m := copilotFindIn(p, q)
		if cand && (!seen || at.After(best)) {
			out, best, found, seen = r, at, ok, true
			if !ok {
				why = m.why
			}
		}
		if !cand && m.closer(miss) {
			miss = m
		}
	}
	if found {
		return out, true, recognised, ""
	}
	if !seen {
		why = miss.why
	}
	return "", false, recognised, why
}

// copilotMiss is why a task of the wanted agent was not taken. The closest miss names the reason: a task that matches but finished
// outside the window (rank 3), then one that names the ticket (2), then any other (1); on a tie, the newest. So a session holding
// other tickets' gates still names the check this ticket's own task failed.
type copilotMiss struct {
	why  string
	rank int
	at   time.Time
}

func (m copilotMiss) closer(o copilotMiss) bool {
	return m.rank > o.rank || (m.rank == o.rank && m.rank > 0 && !m.at.Before(o.at))
}

type copilotTask struct {
	agentType, prompt string
	started           string // t-46df: the dispatch's own timestamp (tool.execution_start)
	subagent, agentID string // what subagent.started named for this call
	done              *copilotLine
	doneRaw           string
}

// copilotFindIn scans one session file. A task counts only when it was a `task` dispatch of the wanted canon agent, subagent.started
// names that same agent, the prompt names the ticket and the protocol,
// and the call succeeded inside the window: never the main session's own messages. The report is taken from the task's result,
// else the gate's own newest message that holds it; the record is the gate's own commands and messages (never its tool outputs) plus
// the result line.
// miss is set when ok is false: the candidate's failure, else this file's closest miss.
func copilotFindIn(path string, q copilotQuery) (out string, at time.Time, candidate, ok bool, miss copilotMiss) {
	f, err := os.Open(path)
	if err != nil {
		return "", time.Time{}, false, false, miss
	}
	defer f.Close()
	tasks := map[string]*copilotTask{}
	var order []string
	raw := map[string][]string{}  // agentId -> its raw lines
	used := map[string]int64{}    // t-46df: agentId -> its model calls' input + output tokens (input holds the cache counts)
	usedSeen := map[string]bool{} // apiCallId already counted
	usedAny := map[string]bool{}
	msgs := map[string][]string{} // agentId -> its assistant.message texts, in order
	br := bufio.NewReaderSize(f, 1<<20)
	for {
		line, more := transcript.NextLine(br)
		if !more {
			break
		}
		if line == nil {
			continue // longer than transcript.MaxLine: skipped, never fatal
		}
		text := string(line)
		l, ok := parseCopilotLine(line)
		if !ok {
			continue
		}
		if l.AgentID != "" && l.Type != "subagent.started" {
			// Only what the gate authored counts: its commands (tool.execution_start arguments) and its messages. The outputs of its
			// tool calls do not: a gate that merely read a report someone typed (cat eval-report.md) must not back that report.
			switch l.Type {
			case "session.usage_record":
				if u := l.Data.Usage; u != nil && (u.APICallID == "" || !usedSeen[u.APICallID]) {
					usedSeen[u.APICallID] = u.APICallID != ""
					used[l.AgentID] += u.InputTokens + u.OutputTokens
					usedAny[l.AgentID] = true
				}
			case "tool.execution_start":
				raw[l.AgentID] = append(raw[l.AgentID], text)
			case "assistant.message":
				raw[l.AgentID] = append(raw[l.AgentID], text)
				if l.Data.Content != "" {
					msgs[l.AgentID] = append(msgs[l.AgentID], l.Data.Content)
				}
			}
			continue // a subagent's own tool calls are never a task dispatch of the main session
		}
		id := l.Data.ToolCallID
		if id == "" {
			continue
		}
		switch l.Type {
		case "tool.execution_start":
			if l.Data.ToolName == "task" {
				tasks[id] = &copilotTask{agentType: l.Data.Arguments.AgentType, prompt: l.Data.Arguments.Prompt, started: l.Timestamp}
				order = append(order, id)
			}
		case "subagent.started":
			if t := tasks[id]; t != nil {
				t.subagent, t.agentID = l.Data.AgentType, l.AgentID
			}
		case "tool.execution_complete":
			if t := tasks[id]; t != nil {
				lc := l
				t.done, t.doneRaw = &lc, text
			}
		}
	}
	// the newest matching dispatch (by its result event's time) in this file, then whether it holds a usable report or record
	var newest *copilotTask
	for _, id := range order {
		t := tasks[id]
		// Only the canon gate agent: no general-purpose fallback. The main session writes a task's prompt, and general-purpose has
		// write tools, so accepting it would let the session produce its own report (the Claude path's only fallback, Plan, cannot write).
		if t.done == nil || t.agentType != q.Agent {
			continue
		}
		when, err := time.Parse(time.RFC3339Nano, t.done.Timestamp) // on a tie the later line in the file wins
		if err != nil {
			continue
		}
		m, namesTicket := copilotMismatch(t, q)
		outside := when.Before(q.From) || when.After(q.To)
		if m != "" || outside {
			c := copilotMiss{why: m, rank: 1, at: when}
			switch {
			case m == "":
				c.why, c.rank = fmt.Sprintf("the newest matching %s task finished at %s, outside the window %s to %s", q.Agent,
					when.UTC().Format(time.RFC3339), q.From.UTC().Format(time.RFC3339), q.To.UTC().Format(time.RFC3339)), 3
			case outside:
				continue // a mismatch outside the window says nothing about this close
			case namesTicket:
				c.rank = 2
			}
			if c.closer(miss) {
				miss = c
			}
			continue
		}
		if newest != nil && when.Before(at) {
			continue
		}
		newest, at = t, when
	}
	if newest == nil {
		return "", time.Time{}, false, false, miss
	}
	if newest.done.Data.Success == nil || !*newest.done.Data.Success {
		return "", at, true, false, copilotMiss{why: fmt.Sprintf("the newest matching %s task failed", q.Agent)}
	}
	if q.Usage {
		return copilotUsageLine(newest, at, used, usedAny), at, true, true, copilotMiss{}
	}
	if q.Record {
		return strings.Join(append(append([]string{}, raw[newest.agentID]...), newest.doneRaw), "\n") + "\n", at, true, true, copilotMiss{}
	}
	cands := []string{newest.done.Data.Result.Content}
	for i := len(msgs[newest.agentID]) - 1; i >= 0; i-- {
		cands = append(cands, msgs[newest.agentID][i])
	}
	for _, c := range cands {
		if i := reportStart(c, q.Prefix); i >= 0 && !strings.Contains(c, copilotTruncated) {
			r := c[i:]
			if q.Agent == "canon-reviewer" {
				r = cutAfterVerdict(r)
			}
			return strings.TrimRight(r, "\n") + "\n", at, true, true, copilotMiss{}
		}
	}
	return "", at, true, false, copilotMiss{why: fmt.Sprintf("the newest matching %s task's result has no whole line starting %q", q.Agent, q.Prefix)}
}

// copilotUsageLine (t-46df) is "<tokens>\t<minutes>\n" for one gate task: tokens = its agent's usage_record input + output (Copilot's
// input already holds the cache reads and writes, as Claude Code's total does), minutes = dispatch to result, rounded up. A part the
// record does not hold is empty, never 0.
func copilotUsageLine(t *copilotTask, done time.Time, used map[string]int64, usedAny map[string]bool) string {
	tokens, minutes := "", ""
	if t.agentID != "" && usedAny[t.agentID] {
		tokens = strconv.FormatInt(used[t.agentID], 10)
	}
	if st, err := time.Parse(time.RFC3339Nano, t.started); err == nil && !done.Before(st) {
		minutes = strconv.Itoa(int(math.Ceil(done.Sub(st).Minutes())))
		if minutes == "0" {
			minutes = "1"
		}
	}
	return tokens + "\t" + minutes + "\n"
}

// cutAfterVerdict ends a review at its verdict line (t-2986: a Copilot reviewer appended commentary after YES, which a relay would have
// written into review-notes.md). The verdict line is the one the close reads (tools/sprint's review check): the first non-blank line
// under ## Verdict, bold stripped, its first word YES or NO in any case. A report with no such line is returned unchanged.
func cutAfterVerdict(r string) string {
	inVerdict := false
	for i := 0; i < len(r); {
		end := len(r)
		if j := strings.IndexByte(r[i:], '\n'); j >= 0 {
			end = i + j
		}
		line := strings.TrimRight(r[i:end], "\r")
		if inVerdict && strings.TrimSpace(line) != "" {
			if f := strings.Fields(strings.ReplaceAll(line, "*", "")); len(f) > 0 && (strings.ToUpper(f[0]) == "YES" || strings.ToUpper(f[0]) == "NO") {
				return r[:end]
			}
			return r
		}
		if verdictHeadRe.MatchString(line) {
			inVerdict = true
		}
		i = end + 1
	}
	return r
}

var verdictHeadRe = regexp.MustCompile(`^##[[:space:]]+Verdict`)

// copilotMismatch says which check a task of the wanted agent fails, or "" when it matches, and whether its prompt names the ticket.
// The prompt is read with its backslashes as / (common.SlashSeparators, t-2986): a Copilot session on Windows names
// .agents\skills\sprint\reference\review.md.
func copilotMismatch(t *copilotTask, q copilotQuery) (string, bool) {
	prompt := common.SlashSeparators(t.prompt)
	names := strings.Contains(prompt, q.Ticket)
	if t.subagent != t.agentType {
		return fmt.Sprintf("the newest %s task never started as %s (no subagent.started names it)", q.Agent, q.Agent), names
	}
	if !names {
		return fmt.Sprintf("the newest %s task names a different ticket than %s", q.Agent, q.Ticket), false
	}
	if !strings.Contains(prompt, q.Proto) {
		return fmt.Sprintf("the newest %s task names %s but not %s", q.Agent, q.Ticket, q.Proto), true
	}
	second := strings.Contains(prompt, ".tickets/"+q.Ticket+"/eval-report-2.md")
	if second != q.Second { // the first evaluator's report is never taken for the second's, or the other way
		return fmt.Sprintf("the newest %s task is the other evaluator's (eval-report-2.md named: %t)", q.Agent, second), true
	}
	return "", true
}

// fromMSYS (t-2986) maps a Git Bash path the shell passes (/c/Users/x/.copilot) to the form a Windows program opens; a variable so a
// test can take the Windows branch on any OS (the daemon's pattern, daemon/main.go fromMSYS).
var fromMSYS = func(p string) string { return common.FromMSYS(p, runtime.GOOS) }

// copilotReportCLI: copilot-report [--second] [--record|--usage] [--from <unix>] [--to <unix>] <copilot-home> <agent> <ticket> <protocol-file> <prefix>
// --record prints the gate's raw record instead of the report (the close check greps it, as it greps Claude Code's transcripts).
// Exit 0 with the output, 1 when the layout is recognised but no result matches, 3 when there is no Copilot session record.
// The window defaults to the last 3 hours.
func copilotReportCLI(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("copilot-report", flag.ContinueOnError)
	fs.SetOutput(stderr)
	second := fs.Bool("second", false, "the second evaluator's report (eval-report-2.md)")
	record := fs.Bool("record", false, "print the gate's raw record (every line its agentId produced and its result), not the report")
	usage := fs.Bool("usage", false, "print the gate's tokens and minutes as <tokens>\\t<minutes> (t-46df), not the report")
	from := fs.String("from", "", "earliest result time, unix seconds")
	to := fs.String("to", "", "latest result time, unix seconds")
	if fs.Parse(args) != nil || fs.NArg() != 5 {
		fmt.Fprintln(stderr, "usage: sprint-check copilot-report [--second] [--record] [--from <unix>] [--to <unix>] <copilot-home> <agent> <ticket> <protocol-file> <first-line-prefix>")
		return 2
	}
	now := time.Now()
	q := copilotQuery{Agent: fs.Arg(1), Ticket: fs.Arg(2), Proto: fs.Arg(3), Prefix: fs.Arg(4), Second: *second, Record: *record, Usage: *usage, From: now.Add(-3 * time.Hour), To: now.Add(time.Minute)}
	for _, t := range []struct {
		s   string
		dst *time.Time
	}{{*from, &q.From}, {*to, &q.To}} {
		if t.s == "" {
			continue
		}
		n, err := strconv.ParseInt(t.s, 10, 64)
		if err != nil {
			fmt.Fprintln(stderr, "copilot-report: --from/--to take unix seconds")
			return 2
		}
		*t.dst = time.Unix(n, 0)
	}
	report, found, recognised, why := copilotFind(fromMSYS(fs.Arg(0)), q)
	switch {
	case !recognised:
		return 3
	case !found:
		fmt.Fprintln(stderr, "copilot-report: "+why)
		return 1
	}
	fmt.Fprint(stdout, report)
	return 0
}
