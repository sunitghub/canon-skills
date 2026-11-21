package board

import (
	"bufio"
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
	Data      struct {
		ToolCallID string `json:"toolCallId"`
		ToolName   string `json:"toolName"`
		AgentType  string `json:"agentType"`
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
	From   time.Time
	To     time.Time
}

// copilotTruncated is Copilot's notice when it saved a long tool output to a file instead of keeping it: such a result is not the whole report.
const copilotTruncated = "Output too large"

// copilotFind returns the report from the newest matching task result (by the result event's own timestamp) in every
// session file under home/session-state. recognised is false when there is no session-state folder holding an events.jsonl.
func copilotFind(home string, q copilotQuery) (report string, found, recognised bool) {
	dirs, err := os.ReadDir(filepath.Join(home, "session-state"))
	if err != nil {
		return "", false, false
	}
	var best time.Time
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
		if r, at, ok := copilotFindIn(p, q); ok && at.After(best) {
			report, best, found = r, at, true
		}
	}
	return report, found, recognised
}

type copilotTask struct {
	agentType, prompt string
	subagent          string // the agent subagent.started named for this call
}

// copilotFindIn scans one session file. A result counts only when its toolCallId was a `task` dispatch of the wanted agent
// (or a general-purpose fallback whose prompt names the protocol), subagent.started names that same agent, the prompt names the
// ticket and the protocol, and the call succeeded with a full report: never the main session's own messages.
func copilotFindIn(path string, q copilotQuery) (string, time.Time, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", time.Time{}, false
	}
	defer f.Close()
	tasks := map[string]*copilotTask{}
	var report string
	var best time.Time
	found := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20) // a line holds whole tool results; a longer one ends the scan of this file only
	for sc.Scan() {
		l, ok := parseCopilotLine(sc.Bytes())
		if !ok || l.Data.ToolCallID == "" {
			continue
		}
		id := l.Data.ToolCallID
		switch l.Type {
		case "tool.execution_start":
			if l.Data.ToolName == "task" {
				tasks[id] = &copilotTask{agentType: l.Data.Arguments.AgentType, prompt: l.Data.Arguments.Prompt}
			}
		case "subagent.started":
			if t := tasks[id]; t != nil {
				t.subagent = l.Data.AgentType
			}
		case "tool.execution_complete":
			t := tasks[id]
			if t == nil || !copilotTaskMatches(t, q) || l.Data.Success == nil || !*l.Data.Success {
				continue
			}
			at, err := time.Parse(time.RFC3339Nano, l.Timestamp)
			if err != nil || at.Before(q.From) || at.After(q.To) {
				continue
			}
			c := l.Data.Result.Content
			i := reportStart(c, q.Prefix)
			if i < 0 || strings.Contains(c, copilotTruncated) {
				continue
			}
			if !found || at.After(best) {
				report, best, found = strings.TrimRight(c[i:], "\n")+"\n", at, true
			}
		}
	}
	return report, best, found
}

func copilotTaskMatches(t *copilotTask, q copilotQuery) bool {
	agentOK := t.agentType == q.Agent || (t.agentType == "general-purpose" && strings.Contains(t.prompt, q.Proto))
	if !agentOK || t.subagent != t.agentType {
		return false
	}
	if !strings.Contains(t.prompt, q.Ticket) || !strings.Contains(t.prompt, q.Proto) {
		return false
	}
	second := strings.Contains(t.prompt, ".tickets/"+q.Ticket+"/eval-report-2.md")
	return second == q.Second // the first evaluator's report is never taken for the second's, or the other way
}

// copilotReportCLI: copilot-report [--second] [--from <unix>] [--to <unix>] <copilot-home> <agent> <ticket> <protocol-file> <prefix>
// Exit 0 with the report, 1 when the layout is recognised but no result matches, 3 when there is no Copilot session record.
// The window defaults to the last 3 hours.
func copilotReportCLI(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("copilot-report", flag.ContinueOnError)
	fs.SetOutput(stderr)
	second := fs.Bool("second", false, "the second evaluator's report (eval-report-2.md)")
	from := fs.String("from", "", "earliest result time, unix seconds")
	to := fs.String("to", "", "latest result time, unix seconds")
	if fs.Parse(args) != nil || fs.NArg() != 5 {
		fmt.Fprintln(stderr, "usage: sprint-check copilot-report [--second] [--from <unix>] [--to <unix>] <copilot-home> <agent> <ticket> <protocol-file> <first-line-prefix>")
		return 2
	}
	now := time.Now()
	q := copilotQuery{Agent: fs.Arg(1), Ticket: fs.Arg(2), Proto: fs.Arg(3), Prefix: fs.Arg(4), Second: *second, From: now.Add(-3 * time.Hour), To: now.Add(time.Minute)}
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
