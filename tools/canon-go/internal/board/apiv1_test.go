package board

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
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

func v1Daemon(t *testing.T, addr string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "ck") // the board reads a daemon.json only from a private (0700) folder
	os.Mkdir(dir, 0o700)
	os.WriteFile(filepath.Join(dir, "daemon.json"), []byte(`{"addr":"`+addr+`","pid":"1"}`), 0o600)
	t.Setenv("COCKPIT_STATE_DIR", dir)
}

func TestAPIv1SessionsWrapTheDaemonsAnswer(t *testing.T) {
	setupTestProject(t)
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/sessions", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`[{"session":"s1","ticket":"t-aaaa","state":"needs-you"},{"session":"s2","ticket":"t-bbbb","state":""}]`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	v1Daemon(t, strings.TrimPrefix(srv.URL, "http://"))

	w := v1Get(t, "GET", "/api/v1/sessions", "")
	if w.Header().Get("X-Cockpit-Daemon") != "up" || w.Header().Get("Content-Type") != "application/json" {
		t.Errorf("headers %v", w.Header())
	}
	if b := v1Body(t, w); b["schema"] != float64(1) || len(b["sessions"].([]any)) != 2 {
		t.Errorf("list: %s", w.Body)
	}
	one := v1Get(t, "GET", "/api/v1/sessions/t-aaaa", "")
	if s := v1Body(t, one)["session"].(map[string]any); s["session"] != "s1" || one.Header().Get("X-Cockpit-Daemon") != "up" {
		t.Errorf("one: %s", one.Body)
	}
	for id, want := range map[string]string{"t-aaaa": "needs-you", "t-bbbb": "running", "t-cccc": "exited"} {
		st := v1Get(t, "GET", "/api/v1/sessions/"+id+"/state", "")
		if b := v1Body(t, st); b["state"] != want || b["id"] != id || st.Header().Get("X-Cockpit-Daemon") != "up" {
			t.Errorf("state of %s: %s, want %s", id, st.Body, want)
		}
	}
	nf := v1Get(t, "GET", "/api/v1/sessions/t-cccc", "")
	if nf.Code != 404 || v1Body(t, nf)["error"] != "no such session" {
		t.Errorf("unknown session: %d %s", nf.Code, nf.Body)
	}

	v1Daemon(t, "127.0.0.1:1") // no daemon: an empty list that says so, never a null
	w = v1Get(t, "GET", "/api/v1/sessions", "")
	if w.Header().Get("X-Cockpit-Daemon") != "down" || !strings.Contains(w.Body.String(), `"sessions":[]`) {
		t.Errorf("daemon down: %v %s", w.Header(), w.Body)
	}
	if h := v1Get(t, "GET", "/api/v1/sessions/t-aaaa/state", "").Header().Get("X-Cockpit-Daemon"); h != "down" {
		t.Errorf("state with the daemon down: %q", h)
	}
}

func TestAPIv1ErrorsAreOneJSONDocumentWithTheirReason(t *testing.T) {
	setupTestProject(t)
	cases := []struct {
		method, target string
		code           int
		msg            string
	}{
		{"GET", "/api/v1/sessions/x-1", 400, "bad session id"},
		{"GET", "/api/v1/sessions/x-1/state", 400, "bad session id"},
		{"GET", "/api/v1/tickets/T-AAAA", 400, "bad ticket id"},
		{"GET", "/api/v1/sprint/T-AAAA", 400, "bad ticket id"},
		{"GET", "/api/v1/tickets?project=ffffffffffff", 400, "unknown project"},
		{"GET", "/api/v1/sprint/t-aaaa?project=ffffffffffff", 400, "unknown project"},
		{"GET", "/api/v1/tickets/t-zzzz", 404, "no such ticket"},
		{"GET", "/api/v1/nope", 404, "no such route"},
		{"GET", "/api/v1", 404, "no such route"},
		{"GET", "/api/v1/sessions/t-aaaa/other", 404, "no such route"},
		{"GET", "/api/v1/sessions/t-aaaa/state/extra", 404, "no such route"},
		{"GET", "/api/v1/tickets/t-aaaa/extra", 404, "no such route"},
		{"GET", "/api/v1/sprint", 404, "no such route"},
		{"POST", "/api/v1/tickets", 405, "read only: GET"},
	}
	for _, c := range cases {
		w := v1Get(t, c.method, c.target, "")
		dec := json.NewDecoder(bytes.NewReader(w.Body.Bytes()))
		var m map[string]any
		if err := dec.Decode(&m); err != nil || dec.More() {
			t.Errorf("%s %s: not exactly one JSON document: %q", c.method, c.target, w.Body)
			continue
		}
		if w.Code != c.code || m["error"] != c.msg || m["schema"] != float64(1) || w.Header().Get("Content-Type") != "application/json" || w.Header().Get("Allow") != "GET, OPTIONS" {
			t.Errorf("%s %s: %d %q (%v) allow=%q, want %d %q", c.method, c.target, w.Code, m["error"], w.Header().Get("Content-Type"), w.Header().Get("Allow"), c.code, c.msg)
		}
	}
	if w := v1Get(t, "GET", "/api/v1/sessions/t-aaaa/", ""); w.Code == 400 { // a trailing slash is the same route
		t.Errorf("trailing slash refused: %s", w.Body)
	}
	for _, p := range []string{"/api/v10", "/api/v1x/tickets", "/api/v"} { // only /api/v1 and /api/v1/... belong to the API
		if w := v1Get(t, "GET", p, ""); strings.Contains(w.Header().Get("Allow"), "OPTIONS") {
			t.Errorf("%s was routed to the API", p)
		}
	}
	if w := v1Get(t, "GET", "/api/version", ""); strings.Contains(w.Header().Get("Allow"), "OPTIONS") {
		t.Errorf("/api/version was routed to the API")
	}
}

func TestAPIv1TicketFieldsAndListRules(t *testing.T) {
	root := setupTestProject(t)
	writeFile(t, filepath.Join(root, ".tickets", "t-aaaa", "ticket.md"), "---\nid: t-aaaa\nstatus: closed\ntype: bug\npriority: 2\ncreated: 2026-11-01T00:00:00Z\nclosed: 2026-11-02T00:00:00Z\n---\n# Title A\n")
	writeFile(t, filepath.Join(root, ".tickets", "t-bbbb", "ticket.md"), "---\nid: t-bbbb\nstatus: archived\n---\n# Title B\n")
	writeFile(t, filepath.Join(root, ".tickets", "t-cccc", "ticket.md"), "---\nid: t-cccc\nstatus: open\n---\n# Title C\n")
	one := v1Body(t, v1Get(t, "GET", "/api/v1/tickets/t-aaaa", ""))["ticket"].(map[string]any)
	want := map[string]any{"id": "t-aaaa", "title": "Title A", "status": "closed", "type": "bug", "priority": float64(2), "created": "2026-11-01T00:00:00Z", "closed": "2026-11-02T00:00:00Z"}
	if len(one) != len(want) {
		t.Errorf("ticket %v, want exactly %v", one, want)
	}
	for k, v := range want {
		if one[k] != v {
			t.Errorf("ticket[%q] = %v, want %v", k, one[k], v)
		}
	}
	if w := v1Get(t, "GET", "/api/v1/tickets/t-bbbb", ""); w.Code != 200 { // archived is hidden from the list, not from a lookup by id
		t.Errorf("archived by id: %d", w.Code)
	}
	list := v1Body(t, v1Get(t, "GET", "/api/v1/tickets", ""))["tickets"].([]any)
	if len(list) != 2 {
		t.Errorf("list should hold t-aaaa and t-cccc, not the archived t-bbbb: %v", list)
	}
	if w := v1Get(t, "GET", "/api/v1/tickets/t-cccc", ""); strings.Contains(w.Body.String(), "t-aaaa") {
		t.Errorf("one ticket returned another: %s", w.Body)
	}
}

func TestAPIv1SprintEnvelopeActorOrderAndDays(t *testing.T) {
	root := setupTestProject(t)
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	proj := resolvedOrAbs(root)
	line := func(id, ts, kind, extra string) string {
		return `{"schema":1,"id":"` + id + `","ts":"` + ts + `","kind":"` + kind + `","source":"sprint",` + extra + `"project":"` + proj + `","data":{"ticket":"t-aaaa"}}` + "\n"
	}
	// day 1 holds every lifecycle kind; day 2 holds a newer gate.started and the unrelated ticket.created
	writeFile(t, filepath.Join(home, "events", "2026-11-01.jsonl"),
		line("0000000000000001", "2026-11-01T01:00:00.000Z", "sprint.started", "")+line("0000000000000002", "2026-11-01T02:00:00.000Z", "plan.approved", `"actor":"user",`)+
			line("0000000000000003", "2026-11-01T03:00:00.000Z", "gate.started", "")+line("0000000000000004", "2026-11-01T04:00:00.000Z", "gate.finished", "")+
			line("0000000000000005", "2026-11-01T05:00:00.000Z", "gate.rejected", "")+line("0000000000000006", "2026-11-01T06:00:00.000Z", "close.confirmed", "")+
			line("0000000000000007", "2026-11-01T07:00:00.000Z", "sprint.completed", "")+line("0000000000000008", "2026-11-01T08:00:00.000Z", "ticket.created", ""))
	writeFile(t, filepath.Join(home, "events", "2026-11-02.jsonl"), line("0000000000000009", "2026-11-02T09:00:00.000Z", "gate.started", ""))
	b := v1Body(t, v1Get(t, "GET", "/api/v1/sprint/t-aaaa", ""))
	evs := b["events"].([]any)
	var kinds, ids []string
	for _, e := range evs {
		m := e.(map[string]any)
		kinds, ids = append(kinds, m["kind"].(string)), append(ids, m["id"].(string))
	}
	if got := strings.Join(kinds, " "); got != "sprint.started plan.approved gate.finished gate.rejected close.confirmed sprint.completed gate.started" {
		t.Errorf("kinds in log order: %s", got)
	}
	if ids[len(ids)-1] != "0000000000000009" {
		t.Errorf("the newer gate.started should win: %v", ids)
	}
	plan := evs[1].(map[string]any)
	if plan["actor"] != "user" || plan["ts"] != "2026-11-01T02:00:00.000Z" || plan["source"] != "sprint" || plan["project"] != proj || plan["schema"] != float64(1) {
		t.Errorf("envelope: %v", plan)
	}
	if _, has := evs[0].(map[string]any)["actor"]; has {
		t.Errorf("a line with no actor must not get one: %v", evs[0])
	}
	if b["ticket"] != "t-aaaa" {
		t.Errorf("ticket echo: %v", b["ticket"])
	}
	empty := v1Body(t, v1Get(t, "GET", "/api/v1/sprint/t-zzzz", ""))
	if len(empty["events"].([]any)) != 0 || !strings.Contains(v1Get(t, "GET", "/api/v1/sprint/t-zzzz", "").Body.String(), `"events":[]`) {
		t.Errorf("a ticket with no events is an empty list, never null: %v", empty)
	}
}

func TestAPIv1SchemaCommandOutputAndUsage(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := apiCLI([]string{"schema"}, &out, &errb); rc != 0 || !strings.HasPrefix(out.String(), "{\n  \"") {
		t.Fatalf("schema without --json: rc %d %q", rc, out.String())
	}
	var s map[string]any
	if err := json.Unmarshal(out.Bytes(), &s); err != nil {
		t.Fatal(err)
	}
	ev := s["events"].(map[string]any)
	if s["schema"] != float64(1) || ev["schema"] != float64(events.Schema) || len(ev["envelope"].([]any)) != len(v1EventKeys) || len(s["ticket"].([]any)) != len(v1Ticket) {
		t.Errorf("schema document: %v", s)
	}
	for _, args := range [][]string{nil, {}, {"bogus"}, {"schema", "--yaml"}, {"schema", "--json", "x"}, {"--json"}} {
		out.Reset()
		errb.Reset()
		if rc := apiCLI(args, &out, &errb); rc != 2 || errb.String() != "usage: canon-go api schema [--json]\n" || out.Len() != 0 {
			t.Errorf("%v: rc %d stderr %q stdout %q", args, rc, errb.String(), out.String())
		}
	}
	out.Reset()
	if rc, handled := runHelper([]string{"api", "schema", "--json"}, nil, &out, &errb); !handled || rc != 0 || !strings.Contains(out.String(), `"responses"`) {
		t.Errorf("runHelper api: handled=%v rc=%d", handled, rc)
	}
}

func TestAPIv1TicketIDPatternIsAnchored(t *testing.T) {
	for id, ok := range map[string]bool{"t-aaaa": true, "t-a1b2": true, "xt-aaaa": false, "t-aaaax": false, "t-aaa": false, "t-AAAA": false, "": false, "t-aaaa\n": false} {
		if v1TicketIDRe.MatchString(id) != ok {
			t.Errorf("%q: want %v", id, ok)
		}
	}
}

func TestAPIv1SprintReadsAGzippedDayOnceAndSchemaNamesItsFields(t *testing.T) {
	root := setupTestProject(t)
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	proj := resolvedOrAbs(root)
	line := func(id string) string {
		return `{"schema":1,"id":"` + id + `","ts":"2026-11-03T01:00:00.000Z","kind":"plan.approved","source":"sprint","project":"` + proj + `","data":{"ticket":"t-aaaa"}}` + "\n"
	}
	writeFile(t, filepath.Join(home, "events", "2026-11-03.jsonl"), line("00000000000000aa")) // the plain file a crashed gzip left behind
	f, err := os.Create(filepath.Join(home, "events", "2026-11-03.jsonl.gz"))
	if err != nil {
		t.Fatal(err)
	}
	zw := gzip.NewWriter(f)
	zw.Write([]byte(line("00000000000000bb")))
	zw.Close()
	f.Close()
	evs := v1Body(t, v1Get(t, "GET", "/api/v1/sprint/t-aaaa", ""))["events"].([]any)
	if len(evs) != 1 || evs[0].(map[string]any)["id"] != "00000000000000bb" {
		t.Errorf("a day with a .gz twin is read once, from the .gz: %v", evs)
	}
	var out, errb bytes.Buffer
	apiCLI([]string{"schema", "--json"}, &out, &errb)
	var s struct {
		Events struct {
			Kinds map[string][]map[string]any `json:"kinds"`
		} `json:"events"`
	}
	json.Unmarshal(out.Bytes(), &s)
	f0 := s.Events.Kinds["plan.approved"][0]
	if f0["name"] != "ticket" || f0["max"] != float64(64) {
		t.Errorf("a kind's fields are {name, max}: %v", s.Events.Kinds["plan.approved"])
	}
}

// Break-it findings (t-0b89): each test below fails without its fix.

func TestAPIv1SprintFallsBackToThePlainDayWhenTheGzTwinIsBroken(t *testing.T) {
	root := setupTestProject(t)
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	proj := resolvedOrAbs(root)
	ln := `{"schema":1,"id":"00000000000000cc","ts":"2026-11-04T01:00:00.000Z","kind":"plan.approved","source":"sprint","project":"` + proj + `","data":{"ticket":"t-aaaa"}}` + "\n"
	writeFile(t, filepath.Join(home, "events", "2026-11-04.jsonl"), ln)
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write([]byte(ln))
	zw.Close()
	for name, body := range map[string][]byte{"empty": nil, "truncated": buf.Bytes()[:buf.Len()-12]} {
		writeFile(t, filepath.Join(home, "events", "2026-11-04.jsonl.gz"), string(body))
		v1SprintCache = map[string][]map[string]any{}
		evs := v1Body(t, v1Get(t, "GET", "/api/v1/sprint/t-aaaa", ""))["events"].([]any)
		if len(evs) != 1 || evs[0].(map[string]any)["id"] != "00000000000000cc" {
			t.Errorf("%s .gz twin hid the plain day: %v", name, evs)
		}
	}
}

func TestAPIv1SprintScansAreBoundedAndCachedByFileState(t *testing.T) {
	root := setupTestProject(t)
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	proj := resolvedOrAbs(root)
	day := filepath.Join(home, "events", "2026-11-05.jsonl")
	line := func(id string) string {
		return `{"schema":1,"id":"` + id + `","ts":"2026-11-05T01:00:00.000Z","kind":"plan.approved","source":"sprint","project":"` + proj + `","data":{"ticket":"t-aaaa"}}` + "\n"
	}
	writeFile(t, day, line("00000000000000d1"))
	v1SprintCache = map[string][]map[string]any{}
	first := v1Get(t, "GET", "/api/v1/sprint/t-aaaa", "")
	writeFile(t, day, line("00000000000000d1")+line("00000000000000d2")) // a changed file is a new key, not a stale hit
	second := v1Get(t, "GET", "/api/v1/sprint/t-aaaa", "")
	if !strings.Contains(first.Body.String(), "d1") || !strings.Contains(second.Body.String(), "d2") {
		t.Errorf("cache served a stale answer: %s / %s", first.Body, second.Body)
	}
	if len(v1SprintCache) != 2 {
		t.Errorf("want one cache entry per file state, got %d", len(v1SprintCache))
	}
	if again := v1Get(t, "GET", "/api/v1/sprint/t-aaaa", ""); again.Body.String() != second.Body.String() {
		t.Errorf("an unchanged log gave a different answer")
	}
	v1SprintCache = map[string][]map[string]any{}
	for i := 0; i < cap(v1SprintGate); i++ {
		v1SprintGate <- struct{}{}
	}
	busy := v1Get(t, "GET", "/api/v1/sprint/t-aaaa", "")
	for i := 0; i < cap(v1SprintGate); i++ {
		<-v1SprintGate
	}
	if busy.Code != 503 || busy.Header().Get("Retry-After") != "1" || v1Body(t, busy)["error"] != "busy: try again" {
		t.Errorf("a third scan should be refused: %d %s", busy.Code, busy.Body)
	}
	if ok := v1Get(t, "GET", "/api/v1/sprint/t-aaaa", ""); ok.Code != 200 {
		t.Errorf("the gate was not released: %d", ok.Code)
	}
}

func TestAPIv1TicketsCapLongTextSkipSpoofedIdsAndSetSafeHeaders(t *testing.T) {
	root := setupTestProject(t)
	writeFile(t, filepath.Join(root, ".tickets", "t-aaaa", "ticket.md"), "---\nid: t-aaaa\nstatus: open\n---\n# "+strings.Repeat("x", 5000)+"\n")
	writeFile(t, filepath.Join(root, ".tickets", "t-bbbb", "ticket.md"), "---\nid: ../../etc/passwd\nstatus: open\n---\n# Spoof\n")
	w := v1Get(t, "GET", "/api/v1/tickets", "")
	list := v1Body(t, w)["tickets"].([]any)
	if len(list) != 1 || len([]rune(list[0].(map[string]any)["title"].(string))) != v1FieldMax {
		t.Errorf("want one ticket with a %d-rune title: %s", v1FieldMax, strings.ReplaceAll(w.Body.String(), strings.Repeat("x", 300), "x…"))
	}
	if strings.Contains(w.Body.String(), "passwd") {
		t.Errorf("an id that is not a ticket id was served")
	}
	if w.Header().Get("X-Content-Type-Options") != "nosniff" || w.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("headers: %v", w.Header())
	}
}
