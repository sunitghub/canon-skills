package board

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Protects the board's POST /api/ticket/<id>/github/test-close (t-788f), the card's Test & close form for a Manual cloud ticket merged
// here: the form becomes `sprint manual-qa` arguments only when every field is plain text in bounds; anything else is a bad request.
func TestTestCloseArgs(t *testing.T) {
	ok := map[string]any{"by": "Sunit", "steps": []any{
		map[string]any{"what": "Export CSV has every todo", "result": "pass"},
		map[string]any{"what": "Opens in Numbers", "result": "fail"},
	}}
	got, good := testCloseArgs("t-ab12", ok)
	want := []string{"manual-qa", "t-ab12", "--by", "Sunit", "--step", "Export CSV has every todo|pass", "--step", "Opens in Numbers|fail"}
	if !good || !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, %v; want %q", got, good, want)
	}
	step := func(what, res string) map[string]any { return map[string]any{"what": what, "result": res} }
	ten := make([]any, 11)
	for i := range ten {
		ten[i] = step("x", "pass")
	}
	if _, good := testCloseArgs("t-ab12", map[string]any{"by": "a", "steps": ten[:10]}); !good {
		t.Error("10 steps (the limit) refused")
	}
	if _, good := testCloseArgs("t-ab12", map[string]any{"by": strings.Repeat("b", 80), "steps": []any{step(strings.Repeat("x", 200), "pass")}}); !good {
		t.Error("an 80-character name and a 200-character step (the limits) refused")
	}
	bad := map[string]map[string]any{
		"no steps":           {"by": "a", "steps": []any{}},
		"over 10 steps":      {"by": "a", "steps": ten},
		"steps not a list":   {"by": "a", "steps": "x|pass"},
		"empty name":         {"by": "  ", "steps": []any{step("x", "pass")}},
		"name over 80":       {"by": strings.Repeat("a", 81), "steps": []any{step("x", "pass")}},
		"name with newline":  {"by": "a\nb", "steps": []any{step("x", "pass")}},
		"name not text":      {"by": 3.0, "steps": []any{step("x", "pass")}},
		"step over 200":      {"by": "a", "steps": []any{step(strings.Repeat("x", 201), "pass")}},
		"step with a pipe":   {"by": "a", "steps": []any{step("x|fail", "pass")}},
		"step with newline":  {"by": "a", "steps": []any{step("x\n| y | pass |", "pass")}},
		"step with NUL":      {"by": "a", "steps": []any{step("x\x00", "pass")}},
		"empty step":         {"by": "a", "steps": []any{step(" ", "pass")}},
		"result n/a":         {"by": "a", "steps": []any{step("x", "n/a")}},
		"result other":       {"by": "a", "steps": []any{step("x", "--yes")}},
		"step extra key":     {"by": "a", "steps": []any{map[string]any{"what": "x", "result": "pass", "y": 1.0}}},
		"step not an object": {"by": "a", "steps": []any{"x"}},
		"extra key":          {"by": "a", "steps": []any{step("x", "pass")}, "yes": true},
		"no name":            {"steps": []any{step("x", "pass")}},
	}
	for name, p := range bad {
		if got, good := testCloseArgs("t-ab12", p); good {
			t.Errorf("%s: accepted, args %q", name, got)
		}
	}
}

// The route runs manual-qa, then `sprint complete <id>` only when every step passed and manual-qa succeeded; a bad payload runs nothing.
func TestTestCloseRoute(t *testing.T) {
	setupTestProject(t)
	dir := t.TempDir()
	log := filepath.Join(dir, "argv")
	stub := filepath.Join(dir, "sprint")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\necho \"$*\" >> '"+log+"'\n[ -n \"$QA_FAIL\" ] && [ \"$1\" = manual-qa ] && exit 1\necho done\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPRINT_BIN", stub)
	writeTC := func(fields string) {
		t.Helper()
		d := filepath.Join(ticketsDir, "t-ab12")
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "ticket.md"), []byte("---\nid: t-ab12\n"+fields+"created: 2026-11-16T00:00:00Z\n---\n# x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	shape := "status: open\nruns: github\ngithub: acme/app#1\nmerged: abc1234\nmanual: true\ncloud_status: closed\n"
	writeTC(shape)
	post := func(body string) (int, map[string]any) {
		t.Helper()
		os.Remove(log)
		req := httptest.NewRequest("POST", "http://127.0.0.1/api/ticket/t-ab12/github/test-close", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		handle(rec, req)
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	ran := func() string { b, _ := os.ReadFile(log); return string(b) }

	code, out := post(`{"by":"Sunit","steps":[{"what":"export works","result":"pass"}]}`)
	if code != 200 || out["ok"] != true || ran() != "manual-qa t-ab12 --by Sunit --step export works|pass\ncomplete t-ab12\n" {
		t.Fatalf("all pass: %d %v, ran %q; want manual-qa then complete", code, out, ran())
	}
	if qa, _ := out["qa"].(map[string]any); qa == nil || qa["ok"] != true {
		t.Fatalf("all pass: no qa result in %v", out)
	}
	if cl, _ := out["close"].(map[string]any); cl == nil || !strings.Contains(fmt.Sprint(cl["output"]), "done") {
		t.Fatalf("all pass: no close result in %v", out)
	}
	code, out = post(`{"by":"Sunit","steps":[{"what":"export works","result":"pass"},{"what":"opens","result":"fail"}]}`)
	if code != 200 || out["ok"] != false || out["close"] != nil || strings.Contains(ran(), "complete") {
		t.Fatalf("a fail step: %d %v, ran %q; want manual-qa only", code, out, ran())
	}
	t.Setenv("QA_FAIL", "1")
	code, out = post(`{"by":"Sunit","steps":[{"what":"export works","result":"pass"}]}`)
	if code != 200 || out["ok"] != false || strings.Contains(ran(), "complete") {
		t.Fatalf("manual-qa refused: %d %v, ran %q; want no complete", code, out, ran())
	}
	code, _ = post(`{"by":"Sunit","steps":[{"what":"a|b","result":"pass"}]}`)
	if code != 400 || ran() != "" {
		t.Fatalf("a bad payload: %d, ran %q; want 400 and nothing run", code, ran())
	}
	// another shape (the active sprint, a ticket not merged, not Manual): 409, nothing run
	t.Setenv("QA_FAIL", "")
	for _, other := range []string{
		strings.Replace(shape, "status: open", "status: in_progress", 1),
		strings.Replace(shape, "merged: abc1234\n", "", 1),
		strings.Replace(shape, "manual: true", "manual: false", 1),
		strings.Replace(shape, "cloud_status: closed", "cloud_status: in_progress", 1),
		strings.Replace(shape, "merged: abc1234", "merged: ", 1),
	} {
		writeTC(other)
		if code, _ := post(`{"by":"Sunit","steps":[{"what":"export works","result":"pass"}]}`); code != 409 || ran() != "" {
			t.Fatalf("ticket %q: %d, ran %q; want 409 and nothing run", other, code, ran())
		}
	}
	// a ticket the project does not hold: 409, nothing run
	if err := os.RemoveAll(filepath.Join(ticketsDir, "t-ab12")); err != nil {
		t.Fatal(err)
	}
	if code, _ := post(`{"by":"Sunit","steps":[{"what":"export works","result":"pass"}]}`); code != 409 || ran() != "" {
		t.Fatalf("no such ticket: %d, ran %q; want 409 and nothing run", code, ran())
	}
}

// t-788f: the board finds sprint beside tkt (SPRINT_BIN overrides), and a sprint that cannot start says so, never an empty ok.
func TestResolveAndRunSprint(t *testing.T) {
	t.Setenv("SPRINT_BIN", "")
	t.Setenv("TKT_BIN", filepath.Join("/opt", "canon", "tools", "tkt"))
	if got := resolveSprint(); got != filepath.Join("/opt", "canon", "tools", "sprint") {
		t.Fatalf("resolveSprint = %q, want sprint beside tkt", got)
	}
	t.Setenv("SPRINT_BIN", filepath.Join(t.TempDir(), "no-such-sprint"))
	out := runSprint(t.TempDir(), []string{"complete", "t-ab12"})
	if out["ok"] != false || !strings.Contains(fmt.Sprint(out["output"]), "could not run sprint") {
		t.Fatalf("a missing sprint: %v", out)
	}
}
