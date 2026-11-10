package board

import (
	"bufio"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Protects GET /api/v1/events and /api/v1/events/stream (t-8d45, slice 2 of t-0b89): the newest events of a project, a stream that resumes from the
// last id it was given with no duplicate and no gap, a cursor that is client input and never reaches a path unchecked, and the caps on a route
// that needs no token.

type evFix struct {
	t    *testing.T
	home string
	proj string
	srv  *httptest.Server
}

// newEvFix points CANON_HOME at a fresh log, lowers the stream's timings and serves the board's real handler on a loopback port.
func newEvFix(t *testing.T) *evFix {
	t.Helper()
	root := setupTestProject(t)
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	poll, keep, life, write := v1StreamPoll, v1StreamKeepAlive, v1StreamLifetime, v1StreamWrite
	v1StreamPoll = 15 * time.Millisecond
	t.Cleanup(func() { v1StreamPoll, v1StreamKeepAlive, v1StreamLifetime, v1StreamWrite = poll, keep, life, write })
	srv := httptest.NewServer(http.HandlerFunc(handle))
	t.Cleanup(srv.Close)
	return &evFix{t: t, home: home, proj: resolvedOrAbs(root), srv: srv}
}

// line is a valid event line for project p, id n.
func (f *evFix) line(n int, p string) string {
	return fmt.Sprintf(`{"schema":1,"id":"%016x","ts":"2026-11-10T09:00:00.000Z","kind":"ticket.closed","source":"tkt","project":"%s","data":{"ticket":"t-aaaa"}}`+"\n", n, p)
}

func (f *evFix) append(day string, body string) {
	f.t.Helper()
	path := filepath.Join(f.home, "events", day+".jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		f.t.Fatal(err)
	}
	w, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		f.t.Fatal(err)
	}
	w.WriteString(body)
	w.Close()
}

func (f *evFix) get(target string, hdr map[string]string) *http.Response {
	f.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	f.t.Cleanup(cancel)
	req, _ := http.NewRequestWithContext(ctx, "GET", f.srv.URL+target, nil)
	req.Host = "127.0.0.1:8423"
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatal(err)
	}
	f.t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// frame is one server-sent event as it arrived.
type frame struct{ id, data string }

// sseReader is the one goroutine reading a stream's body, so every read of it sees every frame once (two readers on one body would split them).
type sseReader struct{ ch chan frame }

func newSSE(resp *http.Response) *sseReader {
	r := &sseReader{ch: make(chan frame, 64)}
	go func() {
		sc := bufio.NewScanner(resp.Body)
		var cur frame
		for sc.Scan() {
			switch l := sc.Text(); {
			case strings.HasPrefix(l, "id: "):
				cur.id = strings.TrimPrefix(l, "id: ")
			case strings.HasPrefix(l, "data: "):
				cur.data = strings.TrimPrefix(l, "data: ")
			case l == "" && cur.data != "":
				r.ch <- cur
				cur = frame{}
			}
		}
		close(r.ch)
	}()
	return r
}

// next reads n data frames, or fails after two seconds.
func (r *sseReader) next(t *testing.T, n int) []frame {
	t.Helper()
	var out []frame
	for len(out) < n {
		select {
		case fr, ok := <-r.ch:
			if !ok {
				t.Fatalf("the stream ended after %d of %d frames", len(out), n)
			}
			out = append(out, fr)
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out after %d of %d frames", len(out), n)
		}
	}
	return out
}

func frameIDs(fs []frame) string {
	var out []string
	for _, f := range fs {
		i := strings.Index(f.data, `"id":"`)
		out = append(out, strings.TrimLeft(f.data[i+6:i+22], "0"))
	}
	return strings.Join(out, ",")
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// Prod path: GET /api/v1/events (t-8d45): the newest limit events of the project oldest first, only the envelope keys, nothing of another project,
// the cursor at the end of the log, and a bad limit refused before any scan. Hand count: events 1..5 are the project's (day one has 1,2,3 and a
// bad line, day two has 4 and another project's 9, then 5), so limit 2 is 4,5.
func TestAPIv1EventsSnapshot(t *testing.T) {
	f := newEvFix(t)
	if b := v1Body(t, v1Get(t, "GET", "/api/v1/events", "")); len(b["events"].([]any)) != 0 || b["cursor"] != "" {
		t.Fatalf("no log yet: %v", b)
	}
	f.append("2026-11-09", f.line(1, f.proj)+f.line(2, f.proj)+"not json\n"+f.line(3, f.proj))
	f.append("2026-11-10", f.line(4, f.proj)+f.line(9, "/elsewhere")+f.line(5, f.proj)+`{"schema":1,"id":"00000000000000f2","ts":"2026-11-10T09:00:00.000Z","kind":"ticket.closed","source":"tkt","project":"`+f.proj+`","data":{"ticket":"t-aaaa","evil":"<script>"}}`+"\n")
	w := v1Get(t, "GET", "/api/v1/events", "")
	b := v1Body(t, w)
	got := b["events"].([]any)
	if w.Code != 200 || len(got) != 5 || got[0].(map[string]any)["id"] != "0000000000000001" || got[4].(map[string]any)["id"] != "0000000000000005" {
		t.Fatalf("default limit: %d %s", w.Code, w.Body)
	}
	if strings.Contains(w.Body.String(), "elsewhere") || strings.Contains(w.Body.String(), "script") || strings.Contains(w.Body.String(), `"host"`) {
		t.Errorf("served another project's event, a line that fails the schema or the host: %s", w.Body)
	}
	for _, e := range got {
		for k := range e.(map[string]any) {
			if !containsString(v1EventKeys, k) {
				t.Errorf("key %q is not in the published envelope", k)
			}
		}
	}
	size := int64(len(f.line(4, f.proj) + f.line(9, "/elsewhere") + f.line(5, f.proj)))
	two := v1Body(t, v1Get(t, "GET", "/api/v1/events?limit=2", ""))
	if ids := two["events"].([]any); len(ids) != 2 || ids[0].(map[string]any)["id"] != "0000000000000004" || ids[1].(map[string]any)["id"] != "0000000000000005" {
		t.Errorf("limit 2: %v", two["events"])
	}
	if c, _ := two["cursor"].(string); !strings.HasPrefix(c, "2026-11-10:") || c == "2026-11-10:0" || c < fmt.Sprintf("2026-11-10:%d", size/10) {
		t.Errorf("the cursor is the end of the newest day: %v", two["cursor"])
	}
	if len(v1Body(t, v1Get(t, "GET", "/api/v1/events?limit=500", ""))["events"].([]any)) != 5 {
		t.Error("limit 500 is allowed")
	}
	for _, ok := range []string{"5", "05", "00005", "0500", "000000500"} { // the value is what counts, not the digits typed
		if w := v1Get(t, "GET", "/api/v1/events?limit="+ok, ""); w.Code != 200 {
			t.Errorf("limit=%q: %d %s", ok, w.Code, w.Body)
		}
	}
	for _, bad := range []string{"0", "501", "abc", "-1", "+5", "1e2", "5%20", "99999", "1.5", "%00", "0501", "000000000500", "9999999999"} {
		if w := v1Get(t, "GET", "/api/v1/events?limit="+bad, ""); w.Code != 400 || v1Body(t, w)["error"] != "bad limit" {
			t.Errorf("limit=%q: %d %s", bad, w.Code, w.Body)
		}
	}
	if w := v1Get(t, "GET", "/api/v1/events?project=nope", ""); w.Code != 400 {
		t.Errorf("unknown project: %d", w.Code)
	}
	for k := range v1Body(t, v1Get(t, "GET", "/api/v1/events", "")) {
		if !containsString(v1Responses["/api/v1/events"], k) {
			t.Errorf("response key %q is not in the published schema", k)
		}
	}
}

func containsString(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// Prod path: a client subscribes, disconnects and resumes (t-8d45 criterion): every missed event once, in order, across a day change, past a bad line
// and another project's event, then live ones. Hand count: 3 live, then (4, 5) on day one, a bad line, 9 (other project), 6 on a new day, so the
// resume gets 4,5,6; then 8 arrives live. No stream may repeat an id.
func TestAPIv1EventsStreamResumesWithoutDuplicatesOrGaps(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-09", f.line(1, f.proj)+f.line(2, f.proj))
	snap := v1Body(t, v1Get(t, "GET", "/api/v1/events", ""))
	first := f.get("/api/v1/events/stream?cursor="+snap["cursor"].(string), nil)
	if first.StatusCode != 200 || first.Header.Get("Content-Type") != "text/event-stream" || first.Header.Get("Cache-Control") != "no-store" || first.Header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("stream headers: %d %v", first.StatusCode, first.Header)
	}
	f.append("2026-11-09", f.line(3, f.proj))
	firstR := newSSE(first)
	got := firstR.next(t, 1)
	if frameIDs(got) != "3" || !strings.HasPrefix(got[0].id, "2026-11-09:") {
		t.Fatalf("live event: %v", got)
	}
	last := got[0].id
	first.Body.Close() // the client drops
	waitFor(t, "the stream's slot to free", func() bool { return len(v1StreamSlots) == 0 })
	f.append("2026-11-09", f.line(4, f.proj)+f.line(5, f.proj)+"not json\n"+f.line(9, "/elsewhere"))
	f.append("2026-11-10", f.line(6, f.proj))
	second := f.get("/api/v1/events/stream", map[string]string{"Last-Event-ID": last})
	secondR := newSSE(second)
	missed := secondR.next(t, 3)
	if frameIDs(missed) != "4,5,6" || !strings.HasPrefix(missed[2].id, "2026-11-10:") {
		t.Fatalf("missed events: %v", missed)
	}
	f.append("2026-11-10", f.line(8, f.proj))
	if live := secondR.next(t, 1); frameIDs(live) != "8" {
		t.Fatalf("after the missed ones: %v", live)
	}
	// a third resume from the id of event 5 gets 6 and 8 and nothing before
	third := f.get("/api/v1/events/stream?cursor="+missed[1].id, nil)
	if again := newSSE(third).next(t, 2); frameIDs(again) != "6,8" {
		t.Errorf("resume from 5: %v", again)
	}
}

// Prod path: a stream with no cursor starts at the end of the log (t-8d45): what is already there is the snapshot's, not the stream's.
func TestAPIv1EventsStreamWithNoCursorStartsAtTheEnd(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-10", f.line(1, f.proj)+f.line(2, f.proj))
	resp := f.get("/api/v1/events/stream", nil)
	f.append("2026-11-10", f.line(3, f.proj))
	if got := newSSE(resp).next(t, 1); frameIDs(got) != "3" {
		t.Errorf("first frame: %v", got)
	}
}

// Prod path: a subscriber that connects before the log exists (t-8d45) gets the first event once a day file appears.
func TestAPIv1EventsStreamBeforeAnyLogExists(t *testing.T) {
	f := newEvFix(t)
	resp := f.get("/api/v1/events/stream", nil)
	f.append("2026-11-10", f.line(1, f.proj))
	if got := newSSE(resp).next(t, 1); frameIDs(got) != "1" {
		t.Errorf("first frame: %v", got)
	}
}

// Prod path: the cursor is client input (t-8d45): each of these is a 400 with a JSON error that does not echo it, whether it came in the header or the
// query, and a cursor into a day that is only gzipped or past the file's end is refused too.
func TestAPIv1EventsStreamRefusesHostileCursors(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-10", f.line(1, f.proj))
	size := len(f.line(1, f.proj))
	writeGzDay(t, filepath.Join(f.home, "events", "2026-11-01.jsonl.gz"), f.line(7, f.proj))
	for _, c := range []string{"../../x:0", "..%2F..%2Fx:0", "2026-11-10:-1", "2026-11-10:abc", "2026-13-45:0", "2026-11-09:0", "2026-11-01:0", "2025-01-01:0",
		fmt.Sprintf("2026-11-10:%d", size+1), "2026-11-10:99999999999999999999", "2026-11-10", "x", "2026-11-10:0:0", "%00"} {
		for how, resp := range map[string]*http.Response{"query": f.get("/api/v1/events/stream?cursor="+c, nil), "header": f.get("/api/v1/events/stream", map[string]string{"Last-Event-ID": strings.ReplaceAll(c, "%2F", "/")})} {
			body, _ := io.ReadAll(resp.Body)
			if how == "header" && strings.Contains(c, "%") {
				continue // a percent escape is meaningful only in a URL
			}
			if resp.StatusCode != 400 || !strings.Contains(string(body), `"error":"bad cursor`) || strings.Contains(string(body), "x:0") {
				t.Errorf("%s cursor %q: %d %s", how, c, resp.StatusCode, body)
			}
		}
	}
	if ok := f.get("/api/v1/events/stream?cursor=2026-11-10:"+fmt.Sprint(size), nil); ok.StatusCode != 200 {
		t.Errorf("a cursor at the end of the file is valid: %d", ok.StatusCode)
	}
}

// Prod path: at most v1StreamMax streams at once (t-8d45): the next one is a 503 with Retry-After, a refused cursor does not need a slot, and a closed
// stream frees its own.
func TestAPIv1EventsStreamCapAndSlotRelease(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-10", f.line(1, f.proj))
	var held []*http.Response
	for i := 0; i < v1StreamMax; i++ {
		resp := f.get("/api/v1/events/stream", nil)
		if resp.StatusCode != 200 {
			t.Fatalf("stream %d: %d", i, resp.StatusCode)
		}
		held = append(held, resp)
	}
	full := f.get("/api/v1/events/stream", nil)
	body, _ := io.ReadAll(full.Body)
	if full.StatusCode != 503 || full.Header.Get("Retry-After") == "" || !strings.Contains(string(body), "too many streams") {
		t.Fatalf("the fifth stream: %d %v %s", full.StatusCode, full.Header, body)
	}
	if bad := f.get("/api/v1/events/stream?cursor=../../x:0", nil); bad.StatusCode != 400 {
		t.Errorf("a refused cursor is a 400 even when every slot is taken: %d", bad.StatusCode)
	}
	held[0].Body.Close()
	waitFor(t, "a slot to free", func() bool { return len(v1StreamSlots) == v1StreamMax-1 })
	if again := f.get("/api/v1/events/stream", nil); again.StatusCode != 200 {
		t.Errorf("after a stream closed: %d", again.StatusCode)
	}
	for _, h := range held[1:] {
		h.Body.Close()
	}
	waitFor(t, "every slot to free (no stream outlives its client)", func() bool { return len(v1StreamSlots) <= 1 })
}

// Prod path: a stream ends by itself after its lifetime and says it is alive while idle (t-8d45).
func TestAPIv1EventsStreamKeepAliveAndLifetime(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-10", f.line(1, f.proj))
	v1StreamKeepAlive, v1StreamLifetime = 40*time.Millisecond, 400*time.Millisecond
	resp := f.get("/api/v1/events/stream", nil)
	done := make(chan string)
	go func() { b, _ := io.ReadAll(resp.Body); done <- string(b) }()
	select {
	case body := <-done:
		if !strings.Contains(body, "retry: 3000") || strings.Count(body, ": keep-alive\n\n") < 2 || strings.Contains(body, "data:") {
			t.Errorf("an idle stream: %q", body)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the stream did not end after its lifetime")
	}
	waitFor(t, "the slot to free", func() bool { return len(v1StreamSlots) == 0 })
}

// Prod path: the events routes follow slice 1's published schema (t-8d45): `canon-go api schema` lists the snapshot's keys and the stream's frame.
func TestAPIv1SchemaListsTheEventsRoutes(t *testing.T) {
	s := apiSchema()
	if r := s["responses"].(map[string][]string)["/api/v1/events"]; len(r) != 3 {
		t.Errorf("responses: %v", r)
	}
	st := s["streams"].(map[string]map[string]any)["/api/v1/events/stream"]
	if st["content_type"] != "text/event-stream" || st["max_streams"] != v1StreamMax || st["lifetime_s"] != 900 {
		t.Errorf("stream schema: %v", st)
	}
}

func writeGzDay(t *testing.T, path, body string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	z := gzip.NewWriter(f)
	z.Write([]byte(body))
	z.Close()
	f.Close()
}

// Prod path: the stream route is as read only as the rest of /api/v1 (t-8d45): every method but GET is refused, OPTIONS answers 204 with Allow, a
// foreign Host is a 403, and no response carries a CORS header. A GET with a good Host is the one request that streams, so it is not made here.
func TestAPIv1EventsStreamIsReadOnlyHostCheckedAndNoCORS(t *testing.T) {
	newEvFix(t)
	for _, method := range []string{"OPTIONS", "POST", "PUT", "DELETE", "PATCH"} {
		w := v1Get(t, method, "/api/v1/events/stream", "")
		for k := range w.Header() {
			if strings.HasPrefix(strings.ToLower(k), "access-control-") {
				t.Errorf("%s sent %s", method, k)
			}
		}
		want := 405
		if method == "OPTIONS" {
			want = 204
		}
		if w.Code != want || w.Header().Get("Allow") != "GET, OPTIONS" {
			t.Errorf("%s: %d Allow=%q, want %d", method, w.Code, w.Header().Get("Allow"), want)
		}
	}
	if w := v1Get(t, "GET", "/api/v1/events/stream", "evil.example"); w.Code != 403 {
		t.Errorf("a foreign Host: %d, want 403", w.Code)
	}
}

// Prod path: a stream that starts when the newest day is only archived (break-it, t-8d45) stays open and delivers the first event of the file that
// appears; the snapshot's cursor for such a log is one the stream accepts.
func TestAPIv1EventsStreamWhenTheNewestDayIsArchived(t *testing.T) {
	f := newEvFix(t)
	os.MkdirAll(filepath.Join(f.home, "events"), 0o700)
	writeGzDay(t, filepath.Join(f.home, "events", "2026-11-01.jsonl.gz"), f.line(1, f.proj))
	snap := v1Body(t, v1Get(t, "GET", "/api/v1/events", ""))
	if snap["cursor"] != "2026-11-02:0" {
		t.Fatalf("snapshot cursor: %v", snap["cursor"])
	}
	bare := newSSE(f.get("/api/v1/events/stream", nil))
	withCursor := newSSE(f.get("/api/v1/events/stream?cursor="+snap["cursor"].(string), nil))
	f.append("2026-11-04", f.line(2, f.proj))
	if got := bare.next(t, 1); frameIDs(got) != "2" {
		t.Errorf("no cursor: %v", got)
	}
	if got := withCursor.next(t, 1); frameIDs(got) != "2" {
		t.Errorf("snapshot cursor: %v", got)
	}
}

// openingFrame reads a stream's first frame (up to the blank line), as raw lines.
func openingFrame(t *testing.T, resp *http.Response) []string {
	t.Helper()
	sc := bufio.NewScanner(resp.Body)
	var out []string
	for sc.Scan() {
		if sc.Text() == "" {
			return out
		}
		out = append(out, sc.Text())
	}
	t.Fatalf("no opening frame: %v", out)
	return nil
}

// Prod path: a stream names its starting place in the first frame (reviewer, t-8d45): a client that drops before its first event reconnects from that
// id and loses nothing appended meanwhile. The id is the snapshot's cursor, or the one the client sent; with no log yet there is none to send.
func TestAPIv1EventsStreamOpeningFrameCarriesTheStartCursor(t *testing.T) {
	f := newEvFix(t)
	if got := openingFrame(t, f.get("/api/v1/events/stream", nil)); strings.Join(got, "|") != "retry: 3000" {
		t.Errorf("no log yet: %v", got)
	}
	f.append("2026-11-10", f.line(1, f.proj)+f.line(2, f.proj))
	snap := v1Body(t, v1Get(t, "GET", "/api/v1/events", ""))["cursor"].(string)
	if got := openingFrame(t, f.get("/api/v1/events/stream", nil)); strings.Join(got, "|") != "retry: 3000|id: "+snap {
		t.Errorf("no cursor: %v, want the snapshot's %s", got, snap)
	}
	given := "2026-11-10:" + fmt.Sprint(len(f.line(1, f.proj)))
	if got := openingFrame(t, f.get("/api/v1/events/stream?cursor="+given, nil)); strings.Join(got, "|") != "retry: 3000|id: "+given {
		t.Errorf("with a cursor: %v, want %s", got, given)
	}
}
