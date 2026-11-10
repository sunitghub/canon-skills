package board

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"canon/internal/events"
)

// Protects GET /api/v1/* (t-0b89 slice 1), the public read surface, and `canon-go api schema`: a ticket is served by an allowlist
// (its body never leaves the file), every id is checked before use, no method but GET does anything, no response carries a CORS
// header, a log line that fails the events schema is never served, and the schema printed is the one the handlers and the events
// table use.

func v1Get(t *testing.T, method, target, host string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, nil)
	req.Host = "127.0.0.1:8423"
	if host != "" {
		req.Host = host
	}
	w := httptest.NewRecorder()
	handle(w, req)
	return w
}

func v1Body(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
		t.Fatalf("not JSON (%d): %q", w.Code, w.Body.String())
	}
	return m
}

func TestAPIv1TicketsServeOnlyTheAllowlist(t *testing.T) {
	root := setupTestProject(t)
	writeFile(t, filepath.Join(root, ".tickets", "t-aaaa", "ticket.md"), "---\nid: t-aaaa\nstatus: open\ntype: bug\npriority: 1\ncreated: 2026-11-01T00:00:00Z\nsecret_field: LEAKFIELD\n---\n# Title A\n\nBODYMARKER the description\n")
	writeFile(t, filepath.Join(root, ".tickets", "t-aaaa", "plan.md"), "# Plan\nPLANMARKER\n")
	for _, target := range []string{"/api/v1/tickets", "/api/v1/tickets/t-aaaa"} {
		w := v1Get(t, "GET", target, "")
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", target, w.Code, w.Body)
		}
		for _, bad := range []string{"BODYMARKER", "PLANMARKER", "LEAKFIELD", "body", "docs"} {
			if strings.Contains(w.Body.String(), bad) {
				t.Errorf("%s served %q: %s", target, bad, w.Body)
			}
		}
		if !strings.Contains(w.Body.String(), `"title":"Title A"`) {
			t.Errorf("%s: no title: %s", target, w.Body)
		}
	}
	one := v1Body(t, v1Get(t, "GET", "/api/v1/tickets/t-aaaa", ""))["ticket"].(map[string]any)
	allowed := map[string]bool{}
	for _, k := range v1Ticket {
		allowed[k] = true
	}
	for k := range one {
		if !allowed[k] {
			t.Errorf("ticket key %q is not on the allowlist", k)
		}
	}
	if w := v1Get(t, "GET", "/api/v1/tickets/t-zzzz", ""); w.Code != 404 {
		t.Errorf("unknown ticket: %d", w.Code)
	}
}

func TestAPIv1RefusesBadInputBeforeUse(t *testing.T) {
	setupTestProject(t)
	for _, target := range []string{"/api/v1/tickets/..%2Fx", "/api/v1/tickets/t-AAAA", "/api/v1/tickets/t-aaaaa", "/api/v1/sessions/x-1", "/api/v1/sessions/..", "/api/v1/sprint/../x", "/api/v1/sprint/t-aa%00a", "/api/v1/tickets?project=ffffffffffff", "/api/v1/sprint/t-aaaa?project=nope"} {
		if w := v1Get(t, "GET", target, ""); w.Code != 400 && w.Code != 404 {
			t.Errorf("%s: %d, want 400 or 404", target, w.Code)
		}
	}
	for _, target := range []string{"/api/v1/tickets/t-AAAA", "/api/v1/sessions/x-1", "/api/v1/tickets?project=ffffffffffff"} {
		if w := v1Get(t, "GET", target, ""); w.Code != 400 {
			t.Errorf("%s: %d, want 400", target, w.Code)
		}
	}
}

func TestAPIv1ReadOnlyHostAndNoCORS(t *testing.T) {
	setupTestProject(t)
	routes := []string{"/api/v1/sessions", "/api/v1/sessions/t-aaaa", "/api/v1/sessions/t-aaaa/state", "/api/v1/tickets", "/api/v1/tickets/t-aaaa", "/api/v1/sprint/t-aaaa", "/api/v1/nope", "/api/v1/tickets/bad"}
	for _, route := range routes {
		for _, method := range []string{"GET", "OPTIONS", "POST", "PUT", "DELETE"} {
			w := v1Get(t, method, route, "")
			for k := range w.Header() {
				if strings.HasPrefix(strings.ToLower(k), "access-control-") {
					t.Errorf("%s %s sent %s", method, route, k)
				}
			}
			if method == "POST" || method == "PUT" || method == "DELETE" {
				if w.Code != 405 {
					t.Errorf("%s %s: %d, want 405", method, route, w.Code)
				}
			}
			if method == "OPTIONS" && w.Code != 204 {
				t.Errorf("OPTIONS %s: %d, want 204", route, w.Code)
			}
		}
		if w := v1Get(t, "GET", route, "evil.example"); w.Code != 403 {
			t.Errorf("GET %s with Host evil.example: %d, want 403", route, w.Code)
		}
	}
}

func TestAPIv1SprintLatestPerKindSkipsBadLines(t *testing.T) {
	root := setupTestProject(t)
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	proj := resolvedOrAbs(root)
	ev := func(id, ts, kind, ticket, extra string) string {
		return `{"schema":1,"id":"` + id + `","ts":"` + ts + `","kind":"` + kind + `","source":"sprint","project":"` + proj + `","data":{"ticket":"` + ticket + `"` + extra + `}}` + "\n"
	}
	other := `{"schema":1,"id":"00000000000000f1","ts":"2026-11-02T10:00:00.000Z","kind":"plan.approved","source":"sprint","project":"/elsewhere","data":{"ticket":"t-aaaa"}}` + "\n"
	writeFile(t, filepath.Join(home, "events", "2026-11-01.jsonl"), ev("0000000000000001", "2026-11-01T10:00:00.000Z", "plan.approved", "t-aaaa", `,"tier":"normal"`)+ev("0000000000000002", "2026-11-01T11:00:00.000Z", "gate.finished", "t-aaaa", `,"role":"reviewer","verdict":"fail"`)+ev("0000000000000003", "2026-11-01T11:30:00.000Z", "gate.finished", "t-bbbb", `,"role":"reviewer","verdict":"pass"`))
	writeFile(t, filepath.Join(home, "events", "2026-11-02.jsonl"), ev("0000000000000004", "2026-11-02T10:00:00.000Z", "gate.finished", "t-aaaa", `,"role":"reviewer","verdict":"pass"`)+"not json\n"+`{"schema":1,"id":"00000000000000f2","ts":"2026-11-02T11:00:00.000Z","kind":"gate.rejected","source":"sprint","project":"`+proj+`","data":{"ticket":"t-aaaa","evil":"<script>"}}`+"\n"+other)
	w := v1Get(t, "GET", "/api/v1/sprint/t-aaaa", "")
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	b := v1Body(t, w)
	got := b["events"].([]any)
	if len(got) != 2 {
		t.Fatalf("want plan.approved + the later gate.finished, got %s", w.Body)
	}
	first, second := got[0].(map[string]any), got[1].(map[string]any)
	if first["kind"] != "plan.approved" || second["kind"] != "gate.finished" || second["id"] != "0000000000000004" {
		t.Errorf("wrong events: %s", w.Body)
	}
	if strings.Contains(w.Body.String(), "script") || strings.Contains(w.Body.String(), "elsewhere") || strings.Contains(w.Body.String(), `"host"`) {
		t.Errorf("served a line that fails the schema, another project's line or the host: %s", w.Body)
	}
	for k := range second {
		ok := false
		for _, want := range v1EventKeys {
			ok = ok || k == want
		}
		if !ok {
			t.Errorf("event key %q is not in the published envelope", k)
		}
	}
}

func TestAPIv1SchemaCommandListsEveryKindAndRoute(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := apiCLI([]string{"schema", "--json"}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb.String())
	}
	var s struct {
		Events struct {
			Kinds map[string][]events.FieldInfo `json:"kinds"`
		} `json:"events"`
		Responses map[string][]string `json:"responses"`
	}
	if err := json.Unmarshal(out.Bytes(), &s); err != nil {
		t.Fatal(err)
	}
	for _, k := range events.Kinds() {
		if len(s.Events.Kinds[k]) != len(events.Fields(k)) {
			t.Errorf("kind %s: schema has %d fields, table %d", k, len(s.Events.Kinds[k]), len(events.Fields(k)))
		}
	}
	if len(s.Events.Kinds) != len(events.Kinds()) || len(s.Responses) != len(v1Responses) {
		t.Errorf("schema kinds %d/%d routes %d/%d", len(s.Events.Kinds), len(events.Kinds()), len(s.Responses), len(v1Responses))
	}
	if rc := apiCLI([]string{"bogus"}, &out, &errb); rc != 2 {
		t.Errorf("bad usage rc %d", rc)
	}
}

func TestAPIv1ResponseKeysMatchPublishedSchema(t *testing.T) {
	root := setupTestProject(t)
	t.Setenv("CANON_HOME", t.TempDir())
	writeFile(t, filepath.Join(root, ".tickets", "t-aaaa", "ticket.md"), "---\nid: t-aaaa\nstatus: open\n---\n# A\n")
	for route, target := range map[string]string{"/api/v1/tickets": "/api/v1/tickets", "/api/v1/tickets/{id}": "/api/v1/tickets/t-aaaa", "/api/v1/sprint/{ticket}": "/api/v1/sprint/t-aaaa", "/api/v1/sessions": "/api/v1/sessions", "/api/v1/sessions/{id}/state": "/api/v1/sessions/t-aaaa/state"} {
		w := v1Get(t, "GET", target, "")
		if w.Code != http.StatusOK {
			t.Fatalf("%s: %d", target, w.Code)
		}
		got := v1Body(t, w)
		if len(got) != len(v1Responses[route]) {
			t.Errorf("%s keys %v, schema %v", target, got, v1Responses[route])
		}
		for _, k := range v1Responses[route] {
			if _, ok := got[k]; !ok {
				t.Errorf("%s: schema key %q missing from the response", target, k)
			}
		}
	}
}
