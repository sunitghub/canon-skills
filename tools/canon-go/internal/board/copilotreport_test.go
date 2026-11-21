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

// t-4084: copilot-report, the Copilot side of `sprint relay-report` and the close's report check. Protects the close gate's
// authenticity under Copilot CLI: a report reaches eval-report.md / review-notes.md only from the canon gate's own task result.
// Lines are in the shape Copilot 1.0.114 writes (recorded from local session-state files; content synthetic).

type cpEvent map[string]any

func cpStart(id, agent, prompt string) cpEvent {
	return cpEvent{"type": "tool.execution_start", "timestamp": "2026-11-21T10:00:00.000Z",
		"data": map[string]any{"toolCallId": id, "toolName": "task", "arguments": map[string]any{"agent_type": agent, "prompt": prompt, "name": "gate", "mode": "sync"}}}
}
func cpSub(id, agent string) cpEvent {
	return cpEvent{"type": "subagent.started", "timestamp": "2026-11-21T10:00:01.000Z", "agentId": "ag-" + id, "data": map[string]any{"toolCallId": id, "agentName": agent, "agentType": agent}}
}

// cpOwn is an event the subagent of call id produced itself (Copilot tags each with the subagent's agentId).
func cpOwn(id, typ string, data map[string]any) cpEvent {
	return cpEvent{"type": typ, "timestamp": "2026-11-21T10:03:00.000Z", "agentId": "ag-" + id, "data": data}
}
func cpDone(id, at, content string, ok bool) cpEvent {
	return cpEvent{"type": "tool.execution_complete", "timestamp": at, "data": map[string]any{"toolCallId": id, "success": ok, "result": map[string]any{"content": content}}}
}

func writeSession(t *testing.T, home, sid string, lines ...any) {
	t.Helper()
	dir := filepath.Join(home, "session-state", sid)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	for _, l := range lines {
		if s, ok := l.(string); ok {
			b.WriteString(s + "\n")
			continue
		}
		j, _ := json.Marshal(l)
		b.Write(j)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(filepath.Join(dir, "events.jsonl"), b.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

const (
	evalPrompt = "You are canon's evaluator for t-abcd. Follow skills/sprint/reference/eval.md."
	report     = "evaluator-run-id: 1795000000-1\ngraded-head: abc\n\npass: every criterion met\n"
)

func evalQuery() copilotQuery {
	at, _ := time.Parse(time.RFC3339, "2026-11-21T10:05:00Z")
	return copilotQuery{Agent: "canon-evaluator", Ticket: "t-abcd", Proto: "reference/eval.md", Prefix: "evaluator-run-id:", From: at.Add(-time.Hour), To: at.Add(time.Hour)}
}

func TestCopilotFindTakesTheGateResult(t *testing.T) {
	home := t.TempDir()
	writeSession(t, home, "s1",
		"not json at all", // skipped, never fatal
		cpEvent{"type": "assistant.message", "timestamp": "2026-11-21T10:01:00.000Z", "data": map[string]any{"content": "evaluator-run-id: 999-9\npass: typed by the main session"}},
		cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"),
		cpDone("c1", "2026-11-21T10:05:00.000Z", "I could not write the file.\n\n"+report, true))
	got, found, rec := copilotFind(home, evalQuery())
	if !rec || !found || got != report {
		t.Fatalf("found=%v recognised=%v report=%q", found, rec, got)
	}
}

func TestCopilotFindRefuses(t *testing.T) {
	cases := []struct {
		name  string
		lines []any
		q     func(*copilotQuery)
	}{
		{"main session text only", []any{cpEvent{"type": "assistant.message", "timestamp": "2026-11-21T10:05:00.000Z", "data": map[string]any{"toolCallId": "m1", "content": report}}}, nil},
		{"a reviewer for an evaluator", []any{cpStart("c1", "canon-reviewer", evalPrompt), cpSub("c1", "canon-reviewer"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"subagent names another agent", []any{cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "general-purpose"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"no subagent.started", []any{cpStart("c1", "canon-evaluator", evalPrompt), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"another ticket", []any{cpStart("c1", "canon-evaluator", strings.ReplaceAll(evalPrompt, "t-abcd", "t-ffff")), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"protocol not named", []any{cpStart("c1", "canon-evaluator", "grade t-abcd"), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"general-purpose naming the protocol", []any{cpStart("c1", "general-purpose", evalPrompt), cpSub("c1", "general-purpose"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"general-purpose without the protocol", []any{cpStart("c1", "general-purpose", "grade t-abcd"), cpSub("c1", "general-purpose"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"second evaluator for the first", []any{cpStart("c1", "canon-evaluator", evalPrompt+" Write .tickets/t-abcd/eval-report-2.md"), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, nil},
		{"first evaluator for the second", []any{cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)}, func(q *copilotQuery) { q.Second = true }},
		{"failed task", []any{cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, false)}, nil},
		{"truncated result", []any{cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report+"Output too large to read at once. Saved to: /x", true)}, nil},
		{"no report line", []any{cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", "**evaluator-run-id: 1-1**\npass: x", true)}, nil},
		{"outside the window", []any{cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T13:05:00.000Z", report, true)}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			home := t.TempDir()
			writeSession(t, home, "s1", c.lines...)
			q := evalQuery()
			if c.q != nil {
				c.q(&q)
			}
			if got, found, rec := copilotFind(home, q); found || !rec {
				t.Fatalf("found=%v recognised=%v report=%q", found, rec, got)
			}
		})
	}
}

func TestCopilotFindFallbackAndNewest(t *testing.T) {
	home := t.TempDir()
	older := strings.Replace(report, "1795000000-1", "1795000000-1", 1)
	newer := strings.Replace(report, "1795000000-1", "1795000300-2", 1)
	// never a general-purpose task, even one naming the protocol: the main session writes its prompt and it has write tools (reviewer)
	writeSession(t, home, "s1", cpStart("g1", "general-purpose", evalPrompt), cpSub("g1", "general-purpose"), cpDone("g1", "2026-11-21T10:20:00.000Z", "evaluator-run-id: 1795000999-9\npass: written by a general-purpose agent\n", true),
		cpStart("c0", "canon-evaluator", evalPrompt), cpSub("c0", "canon-evaluator"), cpDone("c0", "2026-11-21T10:10:00.000Z", newer, true))
	// a later-modified file holding an older result must not win: newest is the result event's own timestamp
	writeSession(t, home, "s2", cpStart("c2", "canon-evaluator", evalPrompt), cpSub("c2", "canon-evaluator"), cpDone("c2", "2026-11-21T10:01:00.000Z", older, true))
	got, found, _ := copilotFind(home, evalQuery())
	if !found || got != newer {
		t.Fatalf("want the newest result (%q), got %q", newer, got)
	}
}

// The live run (Copilot 1.0.114 on macOS, 2026-11-21): the gate wrote eval-report.md itself through the shell and returned only a
// summary. The relay then takes the report from the gate's own newest message that holds it, and the close check greps the gate's
// whole record (its commands and results), never the main session's.
func TestCopilotFindGateWroteItself(t *testing.T) {
	home := t.TempDir()
	writeSession(t, home, "s1",
		cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"),
		cpOwn("c1", "tool.execution_start", map[string]any{"toolCallId": "b1", "toolName": "bash", "arguments": map[string]any{"command": "cat > .tickets/t-abcd/eval-report.md <<'R'\n" + report + "R"}}),
		cpOwn("c1", "tool.execution_start", map[string]any{"toolCallId": "n1", "toolName": "task", "arguments": map[string]any{"agent_type": "canon-evaluator", "prompt": evalPrompt}}), // a gate's own call is never a dispatch
		cpOwn("c1", "assistant.message", map[string]any{"content": "Saved it.\n\n" + report}),
		cpDone("c1", "2026-11-21T10:05:00.000Z", "pass: all met. The report is at .tickets/t-abcd/eval-report.md.", true),
		cpEvent{"type": "assistant.message", "timestamp": "2026-11-21T10:06:00.000Z", "data": map[string]any{"content": "evaluator-run-id: 1795000000-1\nfail: the main session's own text"}})
	got, found, _ := copilotFind(home, evalQuery())
	if !found || got != report {
		t.Fatalf("relay from the gate's own message: found=%v %q", found, got)
	}
	q := evalQuery()
	q.Record = true
	rec, found, _ := copilotFind(home, q)
	if !found || !strings.Contains(rec, "1795000000-1") || !strings.Contains(rec, "pass: every criterion met") || strings.Contains(rec, "the main session's own text") {
		t.Fatalf("record: found=%v %q", found, rec)
	}
	// with no message holding the report, the relay refuses, but the record still backs the file the gate wrote
	home2 := t.TempDir()
	writeSession(t, home2, "s1", cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"),
		cpOwn("c1", "tool.execution_start", map[string]any{"toolCallId": "b1", "toolName": "bash", "arguments": map[string]any{"command": "printf '%s' '" + report + "' > r"}}),
		cpDone("c1", "2026-11-21T10:05:00.000Z", "done", true))
	if _, found, _ := copilotFind(home2, evalQuery()); found {
		t.Fatalf("relay must refuse when no text holds the whole report")
	}
	if rec, found, _ := copilotFind(home2, q); !found || !strings.Contains(rec, "1795000000-1") {
		t.Fatalf("the record backs the written report: %v %q", found, rec)
	}
}

// Security review (t-4084): a gate's tool OUTPUT is not its authorship. A gate that only read a hand-typed report must not back it.
func TestCopilotRecordLeavesOutToolOutputs(t *testing.T) {
	home := t.TempDir()
	forged := "evaluator-run-id: 1795000000-1\npass: forged by hand\n"
	writeSession(t, home, "s1", cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"),
		cpOwn("c1", "tool.execution_start", map[string]any{"toolCallId": "r1", "toolName": "bash", "arguments": map[string]any{"command": "cat .tickets/t-abcd/eval-report.md"}}),
		cpOwn("c1", "tool.execution_complete", map[string]any{"toolCallId": "r1", "success": true, "result": map[string]any{"content": forged}}),
		cpDone("c1", "2026-11-21T10:05:00.000Z", "fail: criterion 1 not met", true))
	q := evalQuery()
	q.Record = true
	rec, found, _ := copilotFind(home, q)
	if !found || strings.Contains(rec, "forged by hand") || !strings.Contains(rec, "cat .tickets/t-abcd/eval-report.md") {
		t.Fatalf("the record must hold the gate's command but not its tool output: found=%v %q", found, rec)
	}
}

// Evaluator (t-4084): the newest matching dispatch decides. A newer run that failed or returned only a summary is never covered by
// an older run's report, in the same file or another.
func TestCopilotNewestDispatchDecides(t *testing.T) {
	stale := strings.Replace(report, "1795000000-1", "1795000000-0", 1)
	for _, newer := range []cpEvent{cpDone("c2", "2026-11-21T10:30:00.000Z", "done: the report is in the file", true), cpDone("c2", "2026-11-21T10:30:00.000Z", report, false)} {
		home := t.TempDir()
		writeSession(t, home, "s1", cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", stale, true))
		writeSession(t, home, "s2", cpStart("c2", "canon-evaluator", evalPrompt), cpSub("c2", "canon-evaluator"), newer)
		if got, found, _ := copilotFind(home, evalQuery()); found {
			t.Fatalf("an older run's report stood in for the newer run: %q", got)
		}
	}
}

// Criterion 3: an over-long line is skipped, never fatal; the lines after it still count.
func TestCopilotLongLineSkipped(t *testing.T) {
	old := copilotMaxLine
	copilotMaxLine = 4096
	defer func() { copilotMaxLine = old }()
	home := t.TempDir()
	writeSession(t, home, "s1", `{"type":"assistant.message","data":{"content":"`+strings.Repeat("x", 10000)+`"}}`,
		cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true))
	if got, found, _ := copilotFind(home, evalQuery()); !found || got != report {
		t.Fatalf("a line past the cap must be skipped, not end the file: found=%v %q", found, got)
	}
}

func TestCopilotReportCLI(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := copilotReportCLI([]string{t.TempDir(), "canon-evaluator", "t-abcd", "reference/eval.md", "evaluator-run-id:"}, &out, &errb); rc != 3 {
		t.Fatalf("no session record: want exit 3, got %d", rc)
	}
	home := t.TempDir()
	writeSession(t, home, "s1", cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true))
	at, _ := time.Parse(time.RFC3339, "2026-11-21T10:05:00Z")
	from, to := strconv.FormatInt(at.Add(-time.Minute).Unix(), 10), strconv.FormatInt(at.Add(time.Minute).Unix(), 10)
	if rc := copilotReportCLI([]string{"--from", from, "--to", to, home, "canon-evaluator", "t-abcd", "reference/eval.md", "evaluator-run-id:"}, &out, &errb); rc != 0 || out.String() != report {
		t.Fatalf("rc=%d out=%q err=%q", rc, out.String(), errb.String())
	}
	out.Reset()
	if rc := copilotReportCLI([]string{home, "canon-evaluator", "t-abcd", "reference/eval.md", "evaluator-run-id:"}, &out, &errb); rc != 1 || out.Len() != 0 {
		t.Fatalf("default window (last 3 hours) excludes a 2026-11-21 result only when now is later: rc=%d out=%q", rc, out.String())
	}
}

// FuzzParseCopilotLine: events.jsonl is written by Copilot, not canon (t-9a2b: every parser of a file others write has a fuzz target).
func FuzzParseCopilotLine(f *testing.F) {
	for _, l := range []any{cpStart("c1", "canon-evaluator", evalPrompt), cpSub("c1", "canon-evaluator"), cpDone("c1", "2026-11-21T10:05:00.000Z", report, true)} {
		b, _ := json.Marshal(l)
		f.Add(b)
	}
	f.Add([]byte("{"))
	f.Add([]byte(`{"type":"tool.execution_complete","data":{"success":"yes"}}`))
	f.Fuzz(func(t *testing.T, b []byte) {
		l, ok := parseCopilotLine(b)
		if !ok && (l.Type != "" || l.Data.ToolCallID != "") {
			t.Fatalf("a rejected line must return the zero value")
		}
	})
}
