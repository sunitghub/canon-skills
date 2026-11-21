package board

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
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
	From   time.Time
	To     time.Time
}

// copilotTruncated is Copilot's notice when it saved a long tool output to a file instead of keeping it: such a text is not the whole report.
const copilotTruncated = "Output too large"

// copilotFind returns the report (or, with Record, the gate's raw record) from the newest matching task (by its result event's own
// timestamp) in every session file under home/session-state. recognised is false when no session-state folder holds an events.jsonl.
func copilotFind(home string, q copilotQuery) (out string, found, recognised bool) {
	dirs, err := os.ReadDir(filepath.Join(home, "session-state"))
	if err != nil {
		return "", false, false
	}
	var best time.Time
	seen := false
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
		if r, at, cand, ok := copilotFindIn(p, q); cand && (!seen || at.After(best)) {
			out, best, found, seen = r, at, ok, true
		}
	}
	if !found {
		out = ""
	}
	return out, found, recognised
}

type copilotTask struct {
	agentType, prompt string
	subagent, agentID string // what subagent.started named for this call
	done              *copilotLine
	doneRaw           string
}

// copilotFindIn scans one session file. A task counts only when it was a `task` dispatch of the wanted canon agent, subagent.started
// names that same agent, the prompt names the ticket and the protocol,
// and the call succeeded inside the window: never the main session's own messages. The report is taken from the task's result,
// else the gate's own newest message that holds it; the record is the gate's own commands and messages (never its tool outputs) plus
// the result line.
func copilotFindIn(path string, q copilotQuery) (out string, at time.Time, candidate, ok bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", time.Time{}, false, false
	}
	defer f.Close()
	tasks := map[string]*copilotTask{}
	var order []string
	raw := map[string][]string{}  // agentId -> its raw lines
	msgs := map[string][]string{} // agentId -> its assistant.message texts, in order
	br := bufio.NewReaderSize(f, 1<<20)
	for {
		line, more := copilotNextLine(br)
		if !more {
			break
		}
		if line == nil {
			continue // longer than copilotMaxLine: skipped, never fatal
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
				tasks[id] = &copilotTask{agentType: l.Data.Arguments.AgentType, prompt: l.Data.Arguments.Prompt}
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
		if t.done == nil || !copilotTaskMatches(t, q) {
			continue
		}
		when, err := time.Parse(time.RFC3339Nano, t.done.Timestamp)
		if err != nil || when.Before(q.From) || when.After(q.To) || (newest != nil && !when.After(at)) {
			continue
		}
		newest, at = t, when
	}
	if newest == nil {
		return "", time.Time{}, false, false
	}
	if newest.done.Data.Success == nil || !*newest.done.Data.Success {
		return "", at, true, false
	}
	if q.Record {
		return strings.Join(append(append([]string{}, raw[newest.agentID]...), newest.doneRaw), "\n") + "\n", at, true, true
	}
	cands := []string{newest.done.Data.Result.Content}
	for i := len(msgs[newest.agentID]) - 1; i >= 0; i-- {
		cands = append(cands, msgs[newest.agentID][i])
	}
	for _, c := range cands {
		if i := reportStart(c, q.Prefix); i >= 0 && !strings.Contains(c, copilotTruncated) {
			return strings.TrimRight(c[i:], "\n") + "\n", at, true, true
		}
	}
	return "", at, true, false
}

// copilotMaxLine bounds one events.jsonl line (a line holds whole tool results).
var copilotMaxLine = 64 << 20 // a var: the test lowers it

// copilotNextLine returns the next line without its newline; nil for a line longer than copilotMaxLine (read past and dropped);
// more is false at the end of the file or on a read error.
func copilotNextLine(br *bufio.Reader) (line []byte, more bool) {
	var buf []byte
	tooLong := false
	for {
		part, err := br.ReadSlice('\n')
		if !tooLong {
			if len(buf)+len(part) > copilotMaxLine {
				tooLong, buf = true, nil
			} else {
				buf = append(buf, part...)
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil && len(part) == 0 && len(buf) == 0 && !tooLong {
			return nil, false
		}
		if tooLong {
			return nil, true
		}
		return bytes.TrimRight(buf, "\r\n"), true
	}
}

func copilotTaskMatches(t *copilotTask, q copilotQuery) bool {
	// Only the canon gate agent: no general-purpose fallback. The main session writes a task's prompt, and general-purpose has write
	// tools, so accepting it would let the session produce its own report (the Claude path's only fallback, Plan, cannot write).
	if t.agentType != q.Agent || t.subagent != t.agentType {
		return false
	}
	if !strings.Contains(t.prompt, q.Ticket) || !strings.Contains(t.prompt, q.Proto) {
		return false
	}
	second := strings.Contains(t.prompt, ".tickets/"+q.Ticket+"/eval-report-2.md")
	return second == q.Second // the first evaluator's report is never taken for the second's, or the other way
}

// copilotReportCLI: copilot-report [--second] [--record] [--from <unix>] [--to <unix>] <copilot-home> <agent> <ticket> <protocol-file> <prefix>
// --record prints the gate's raw record instead of the report (the close check greps it, as it greps Claude Code's transcripts).
// Exit 0 with the output, 1 when the layout is recognised but no result matches, 3 when there is no Copilot session record.
// The window defaults to the last 3 hours.
func copilotReportCLI(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("copilot-report", flag.ContinueOnError)
	fs.SetOutput(stderr)
	second := fs.Bool("second", false, "the second evaluator's report (eval-report-2.md)")
	record := fs.Bool("record", false, "print the gate's raw record (every line its agentId produced and its result), not the report")
	from := fs.String("from", "", "earliest result time, unix seconds")
	to := fs.String("to", "", "latest result time, unix seconds")
	if fs.Parse(args) != nil || fs.NArg() != 5 {
		fmt.Fprintln(stderr, "usage: sprint-check copilot-report [--second] [--record] [--from <unix>] [--to <unix>] <copilot-home> <agent> <ticket> <protocol-file> <first-line-prefix>")
		return 2
	}
	now := time.Now()
	q := copilotQuery{Agent: fs.Arg(1), Ticket: fs.Arg(2), Proto: fs.Arg(3), Prefix: fs.Arg(4), Second: *second, Record: *record, From: now.Add(-3 * time.Hour), To: now.Add(time.Minute)}
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
	report, found, recognised := copilotFind(fs.Arg(0), q)
	switch {
	case !recognised:
		return 3
	case !found:
		return 1
	}
	fmt.Fprint(stdout, report)
	return 0
}
