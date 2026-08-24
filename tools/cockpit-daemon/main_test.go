//go:build !windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha512"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const bootTok = "boot-token-test"

// fakeSprint writes a script that stands in for `claude`: it records its argv
// and pid, prints READY, then echoes stdin (so input round-trips). Set as
// COCKPIT_SPRINT_BIN. It never sees any daemon token.
//
// argv is recorded one element per line behind an ARGC count, not as "$*" — a
// space-joined "$*" cannot tell `["sprint start t-ab12"]` from
// `["start", "t-ab12"]`, so it would pass either way and never catch a
// regression back to the bash-CLI shape.
func fakeSprint(t *testing.T) (bin, argvFile, pidFile string) {
	t.Helper()
	dir := t.TempDir()
	argvFile = filepath.Join(dir, "argv.txt")
	pidFile = filepath.Join(dir, "pid.txt")
	bin = filepath.Join(dir, "fake-sprint.sh")
	script := "#!/bin/sh\n" +
		"printf 'ARGC:%s\\n' \"$#\" > \"" + argvFile + "\"\n" +
		"for a in \"$@\"; do printf 'ARG:%s\\n' \"$a\" >> \"" + argvFile + "\"; done\n" +
		"printf '%s\\n' \"$$\" > \"" + pidFile + "\"\n" +
		"printf 'READY\\n'\n" +
		"cat\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

func newTestServer(t *testing.T, bin string) (*httptest.Server, string) {
	t.Helper()
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: t.TempDir(), stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	return ts, ts.URL
}

func startSession(t *testing.T, base, ticket, token string) *http.Response {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"ticket": ticket})
	req, _ := http.NewRequest(http.MethodPost, base+"/session/start", bytes.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestTicketValidationAndInjection(t *testing.T) {
	bin, argvFile, _ := fakeSprint(t)
	_, base := newTestServer(t, bin)
	bad := []string{"t-aaaa; touch PWNED", "t-aaaa`touch x`", "../../etc", "t-ABCD", "t-abc", "", "t-abcde", "tt-abcd"}
	for _, id := range bad {
		resp := startSession(t, base, id, bootTok)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("ticket %q: want 400, got %d", id, resp.StatusCode)
		}
		resp.Body.Close()
	}
	// The injection candidate must never have reached exec: no spawn happened.
	if _, err := os.Stat(argvFile); err == nil {
		t.Fatal("a rejected ticket still spawned a process (argv file exists)")
	}
	// A valid id is accepted.
	resp := startSession(t, base, "t-ab12", bootTok)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("valid ticket: want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestOriginAndHostRejected(t *testing.T) {
	bin, _, _ := fakeSprint(t)
	_, base := newTestServer(t, bin)

	// Foreign Origin → 403.
	req, _ := http.NewRequest(http.MethodPost, base+"/session/start", strings.NewReader(`{"ticket":"t-ab12"}`))
	req.Header.Set("Authorization", "Bearer "+bootTok)
	req.Header.Set("Origin", "http://evil.example.com")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("foreign origin: want 403, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// Foreign Host → 403.
	req2, _ := http.NewRequest(http.MethodPost, base+"/session/start", strings.NewReader(`{"ticket":"t-ab12"}`))
	req2.Header.Set("Authorization", "Bearer "+bootTok)
	req2.Host = "evil.example.com"
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	if resp2.StatusCode != http.StatusForbidden {
		t.Fatalf("foreign host: want 403, got %d", resp2.StatusCode)
	}
	resp2.Body.Close()

	// Loopback Origin is allowed.
	req3, _ := http.NewRequest(http.MethodPost, base+"/session/start", strings.NewReader(`{"ticket":"t-ab12"}`))
	req3.Header.Set("Authorization", "Bearer "+bootTok)
	req3.Header.Set("Origin", "http://127.0.0.1:5173")
	resp3, err := http.DefaultClient.Do(req3)
	if err != nil {
		t.Fatal(err)
	}
	if resp3.StatusCode != http.StatusOK {
		t.Fatalf("loopback origin: want 200, got %d", resp3.StatusCode)
	}
	resp3.Body.Close()
}

func TestStartRequiresBootToken(t *testing.T) {
	bin, _, _ := fakeSprint(t)
	_, base := newTestServer(t, bin)
	for _, tok := range []string{"", "wrong-token"} {
		resp := startSession(t, base, "t-ab12", tok)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("token %q: want 401, got %d", tok, resp.StatusCode)
		}
		resp.Body.Close()
	}
}

func TestSessionTokenRequired(t *testing.T) {
	bin, _, _ := fakeSprint(t)
	_, base := newTestServer(t, bin)
	resp := startSession(t, base, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	// Wrong/missing session token on input → 401.
	for _, tok := range []string{"", "nope", bootTok} {
		req, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("x"))
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("session token %q: want 401, got %d", tok, r.StatusCode)
		}
		r.Body.Close()
	}
}

func TestLifecycle(t *testing.T) {
	bin, argvFile, pidFile := fakeSprint(t)
	_, base := newTestServer(t, bin)

	resp := startSession(t, base, "t-ab12", bootTok)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start: %d", resp.StatusCode)
	}
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	if out.Session == "" || out.Token == "" {
		t.Fatal("missing session/token")
	}

	// argv targeting + no-token-in-argv. Exactly one element, the joined prompt —
	// the two-arg bash-CLI shape drops the ticket id under a real `claude`.
	argv := waitFile(t, argvFile, 3*time.Second)
	if want := "ARGC:1\nARG:sprint start t-ab12\n"; argv != want {
		t.Fatalf("argv = %q, want %q", argv, want)
	}
	if strings.Contains(argv, out.Token) || strings.Contains(argv, bootTok) {
		t.Fatalf("token leaked into argv: %q", argv)
	}

	// Attach #1: see READY.
	ctx1, cancel1 := context.WithCancel(context.Background())
	buf1 := streamCollect(t, ctx1, base, out.Session, out.Token)
	waitFor(t, buf1, "READY", 3*time.Second)

	// Input echoes back (cat).
	inReq, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("hello-cockpit\n"))
	inReq.Header.Set("Authorization", "Bearer "+out.Token)
	ir, err := http.DefaultClient.Do(inReq)
	if err != nil {
		t.Fatal(err)
	}
	ir.Body.Close()
	waitFor(t, buf1, "hello-cockpit", 3*time.Second)
	cancel1() // detach (PTY keeps running)

	// Attach #2: scrollback replays prior output (reattach).
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	buf2 := streamCollect(t, ctx2, base, out.Session, out.Token)
	waitFor(t, buf2, "READY", 3*time.Second)
	waitFor(t, buf2, "hello-cockpit", 3*time.Second)
	cancel2()

	// Kill → 204, session gone, no orphan.
	pid := atoi(strings.TrimSpace(waitFile(t, pidFile, 3*time.Second)))
	killReq, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/kill", nil)
	killReq.Header.Set("Authorization", "Bearer "+out.Token)
	kr, err := http.DefaultClient.Do(killReq)
	if err != nil {
		t.Fatal(err)
	}
	kr.Body.Close()
	if kr.StatusCode != http.StatusNoContent {
		t.Fatalf("kill: want 204, got %d", kr.StatusCode)
	}
	// Session removed.
	sr := startStream(t, base, out.Session, out.Token)
	if sr.StatusCode != http.StatusNotFound {
		t.Fatalf("after kill, stream: want 404, got %d", sr.StatusCode)
	}
	sr.Body.Close()
	// Process (and group) gone — no orphan.
	if !waitProcessGone(pid, 3*time.Second) {
		t.Fatalf("process %d still alive after kill (orphan)", pid)
	}
}

// ── test helpers ────────────────────────────────────────────────────────────

type safeBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *safeBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *safeBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

func startStream(t *testing.T, base, sid, token string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, base+"/session/"+sid+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// streamCollect opens an SSE stream and decodes `data:` payloads into a buffer.
func streamCollect(t *testing.T, ctx context.Context, base, sid, token string) *safeBuf {
	t.Helper()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/session/"+sid+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("stream: want 200, got %d", resp.StatusCode)
	}
	out := &safeBuf{}
	go func() {
		defer resp.Body.Close()
		rd := bufio.NewReader(resp.Body)
		for {
			line, err := rd.ReadString('\n')
			if strings.HasPrefix(line, "data: ") {
				if dec, e := base64.StdEncoding.DecodeString(strings.TrimSpace(line[len("data: "):])); e == nil {
					out.Write(dec)
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return out
}

// streamCollectFrames is streamCollect but keeps the event name, as
// "<event>=<data>\n" per frame — needed where the event type is the thing under
// test, since a terminal that merely printed the word "needs-you" would satisfy
// a data-only assertion.
func streamCollectFrames(t *testing.T, ctx context.Context, base, sid, token string) *safeBuf {
	t.Helper()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/session/"+sid+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("stream: want 200, got %d", resp.StatusCode)
	}
	out := &safeBuf{}
	go func() {
		defer resp.Body.Close()
		rd := bufio.NewReader(resp.Body)
		event := ""
		for {
			line, err := rd.ReadString('\n')
			switch {
			case strings.HasPrefix(line, "event: "):
				event = strings.TrimSpace(line[len("event: "):])
			case strings.HasPrefix(line, "data: "):
				if dec, e := base64.StdEncoding.DecodeString(strings.TrimSpace(line[len("data: "):])); e == nil {
					out.Write([]byte(event + "=" + string(dec) + "\n"))
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return out
}

func waitFor(t *testing.T, buf *safeBuf, want string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if strings.Contains(buf.String(), want) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %q; got %q", want, buf.String())
}

func waitFile(t *testing.T, path string, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
			return string(b)
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for file %s", path)
	return ""
}

func waitProcessGone(pid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return syscall.Kill(pid, 0) == syscall.ESRCH
}

func atoi(s string) int { n := 0; fmt.Sscanf(s, "%d", &n); return n }

func TestCockpitPageAndAssets(t *testing.T) {
	bin, _, _ := fakeSprint(t)
	_, base := newTestServer(t, bin)

	resp, err := http.Get(base + "/cockpit")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("cockpit: want 200, got %d", resp.StatusCode)
	}
	page := string(body)
	if !strings.Contains(page, bootTok) {
		t.Fatal("boot token not injected into cockpit page")
	}
	if strings.Contains(page, "__COCKPIT_TOKEN__") {
		t.Fatal("token placeholder not replaced")
	}
	if !strings.Contains(page, "/web/vendor/xterm.js") {
		t.Fatal("cockpit page does not reference xterm.js")
	}

	r2, err := http.Get(base + "/web/vendor/xterm.js")
	if err != nil {
		t.Fatal(err)
	}
	b2, _ := io.ReadAll(r2.Body)
	r2.Body.Close()
	if r2.StatusCode != http.StatusOK || len(b2) < 10000 {
		t.Fatalf("xterm.js asset: status %d, %d bytes", r2.StatusCode, len(b2))
	}

	// SRI: the integrity attribute on each vendored asset must match that
	// asset's own actual served bytes (sha384, base64), not merely be present.
	for _, name := range []string{"xterm.css", "xterm.js", "xterm-addon-fit.js"} {
		re := regexp.MustCompile(`(?:href|src)="/web/vendor/` + regexp.QuoteMeta(name) + `" integrity="sha384-([^"]+)"`)
		m := re.FindStringSubmatch(page)
		if m == nil {
			t.Fatalf("%s: no integrity attribute found in cockpit page", name)
		}
		ar, err := http.Get(base + "/web/vendor/" + name)
		if err != nil {
			t.Fatal(err)
		}
		ab, _ := io.ReadAll(ar.Body)
		ar.Body.Close()
		sum := sha512.Sum384(ab)
		want := base64.StdEncoding.EncodeToString(sum[:])
		if m[1] != want {
			t.Fatalf("%s: integrity %s does not match served bytes' hash sha384-%s", name, m[1], want)
		}
	}

	// Valid ?ticket= is prefilled; an invalid one is dropped.
	r3, _ := http.Get(base + "/cockpit?ticket=t-ab12")
	b3, _ := io.ReadAll(r3.Body)
	r3.Body.Close()
	if !strings.Contains(string(b3), "t-ab12") {
		t.Fatal("valid ticket not prefilled")
	}
	r4, _ := http.Get(base + "/cockpit?ticket=evil;rm")
	b4, _ := io.ReadAll(r4.Body)
	r4.Body.Close()
	if strings.Contains(string(b4), "evil;rm") {
		t.Fatal("invalid ticket was not dropped from prefill")
	}
}

// fakeSprintQuickExit writes a script that prints READY then exits immediately
// (no `cat`, unlike fakeSprint) — used to test the natural-exit paths (closed-PTY
// status, reap-after-TTL) without an explicit /kill.
func fakeSprintQuickExit(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "fake-sprint-quick.sh")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nprintf 'READY\\n'\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// waitForSessionExited polls /input until the closed-PTY 410 path fires,
// i.e. until the session has naturally exited.
func waitForSessionExited(t *testing.T, base, sid, token string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodPost, base+"/session/"+sid+"/input", strings.NewReader(""))
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusGone {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for session to exit")
}

func TestClosedPTYReturns410(t *testing.T) {
	bin := fakeSprintQuickExit(t)
	_, base := newTestServer(t, bin)

	resp := startSession(t, base, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	waitForSessionExited(t, base, out.Session, out.Token, 3*time.Second)

	inReq, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("x"))
	inReq.Header.Set("Authorization", "Bearer "+out.Token)
	ir, err := http.DefaultClient.Do(inReq)
	if err != nil {
		t.Fatal(err)
	}
	ir.Body.Close()
	if ir.StatusCode != http.StatusGone {
		t.Fatalf("input after natural exit: want 410, got %d", ir.StatusCode)
	}

	rzBody, _ := json.Marshal(map[string]int{"Cols": 80, "Rows": 24})
	rzReq, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/resize", bytes.NewReader(rzBody))
	rzReq.Header.Set("Authorization", "Bearer "+out.Token)
	rr, err := http.DefaultClient.Do(rzReq)
	if err != nil {
		t.Fatal(err)
	}
	rr.Body.Close()
	if rr.StatusCode != http.StatusGone {
		t.Fatalf("resize after natural exit: want 410, got %d", rr.StatusCode)
	}
}

func TestSessionReapedAfterNaturalExitTTL(t *testing.T) {
	bin := fakeSprintQuickExit(t)
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: t.TempDir(), stateDir: t.TempDir(), sessionReapTTL: 50 * time.Millisecond})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	base := ts.URL

	resp := startSession(t, base, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	waitForSessionExited(t, base, out.Session, out.Token, 3*time.Second)

	// Still present right after exit (410, the grace period before reap) —
	// not yet 404.
	inReq, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("x"))
	inReq.Header.Set("Authorization", "Bearer "+out.Token)
	ir, err := http.DefaultClient.Do(inReq)
	if err != nil {
		t.Fatal(err)
	}
	ir.Body.Close()
	if ir.StatusCode != http.StatusGone {
		t.Fatalf("immediately after exit: want 410 (still present), got %d", ir.StatusCode)
	}

	// After the TTL elapses, the reaper deletes the entry — same request now 404.
	deadline := time.Now().Add(3 * time.Second)
	for {
		req2, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("x"))
		req2.Header.Set("Authorization", "Bearer "+out.Token)
		r2, err := http.DefaultClient.Do(req2)
		if err != nil {
			t.Fatal(err)
		}
		r2.Body.Close()
		if r2.StatusCode == http.StatusNotFound {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("session not reaped after TTL, last status %d", r2.StatusCode)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestConstantTimeAuthEdgeCases(t *testing.T) {
	bin, _, _ := fakeSprint(t)
	_, base := newTestServer(t, bin)

	// Boot token: same length as the real one but wrong bytes, and empty.
	sameLenWrong := strings.Repeat("x", len(bootTok))
	for _, tok := range []string{sameLenWrong, ""} {
		resp := startSession(t, base, "t-ab12", tok)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("boot token %q: want 401, got %d", tok, resp.StatusCode)
		}
		resp.Body.Close()
	}

	resp := startSession(t, base, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	// Session token: same length as the real one but wrong bytes, and empty.
	sameLenWrongSess := strings.Repeat("y", len(out.Token))
	for _, tok := range []string{sameLenWrongSess, ""} {
		req, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("x"))
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		if r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("session token %q: want 401, got %d", tok, r.StatusCode)
		}
	}

	// Sanity: the real token still works — the constant-time swap didn't
	// break correctness, only timing.
	req, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("hi\n"))
	req.Header.Set("Authorization", "Bearer "+out.Token)
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	r.Body.Close()
	if r.StatusCode != http.StatusNoContent {
		t.Fatalf("correct session token: want 204, got %d", r.StatusCode)
	}
}

// TestNeedsYouStatus covers the whole needs-you path short of a live claude: the
// hook's POST flips the status, an attached stream is told, a reattaching stream
// is told too (so a fresh tab can't show green over an unanswered prompt), the
// human typing clears it, and the endpoint is token-gated and validated like
// every other per-session endpoint.
func TestNeedsYouStatus(t *testing.T) {
	bin, _, _ := fakeSprint(t)
	_, base := newTestServer(t, bin)
	resp := startSession(t, base, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	statusURL := base + "/session/" + out.Session + "/status"
	post := func(tok, body string) int {
		req, _ := http.NewRequest(http.MethodPost, statusURL, strings.NewReader(body))
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		return r.StatusCode
	}

	// Unauthorized and malformed are rejected before any state change.
	if got := post("", "needs-you"); got != http.StatusUnauthorized {
		t.Fatalf("no token: want 401, got %d", got)
	}
	if got := post(strings.Repeat("z", len(out.Token)), "needs-you"); got != http.StatusUnauthorized {
		t.Fatalf("wrong token: want 401, got %d", got)
	}
	for _, bad := range []string{"", "done", "NEEDS-YOU", "needs-you\x00extra", "running; rm -rf /"} {
		if got := post(out.Token, bad); got != http.StatusBadRequest {
			t.Fatalf("status %q: want 400, got %d", bad, got)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	buf := streamCollectFrames(t, ctx, base, out.Session, out.Token)
	waitFor(t, buf, "out=READY", 3*time.Second)

	if got := post(out.Token, "needs-you"); got != http.StatusNoContent {
		t.Fatalf("needs-you: want 204, got %d", got)
	}
	waitFor(t, buf, "status=needs-you", 3*time.Second)

	// A newly attached stream learns the pending status from the replay.
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	buf2 := streamCollectFrames(t, ctx2, base, out.Session, out.Token)
	waitFor(t, buf2, "status=needs-you", 3*time.Second)
	cancel2()

	// Typing answers whatever was asked, so the status clears itself.
	inReq, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/input", strings.NewReader("1\n"))
	inReq.Header.Set("Authorization", "Bearer "+out.Token)
	ir, err := http.DefaultClient.Do(inReq)
	if err != nil {
		t.Fatal(err)
	}
	ir.Body.Close()
	// Must be a running that arrives AFTER the needs-you. A bare
	// waitFor("status=running") would already be satisfied by the replay frame the
	// stream emits on attach, and so would pass even if input cleared nothing.
	waitForAfter(t, buf, "status=needs-you", "status=running", 3*time.Second)
}

// waitForAfter waits for `want` to appear at some point after the first
// occurrence of `after`, so a transition can be asserted rather than mere
// presence.
func waitForAfter(t *testing.T, buf *safeBuf, after, want string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		s := buf.String()
		if i := strings.Index(s, after); i >= 0 && strings.Contains(s[i+len(after):], want) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %q after %q; got %q", want, after, buf.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestHookSettingsFile asserts the shape of what the daemon hands `claude
// --settings`: the Notification event, a curl call that reads its credential
// from a -K file, and the token in that 0600 file rather than in the command
// string (which Claude Code runs through a shell, where it would land in `ps`).
func TestHookSettingsFile(t *testing.T) {
	s := newServer(config{token: bootTok, addr: "127.0.0.1:8455", projectRoot: t.TempDir(), stateDir: t.TempDir()})
	dir, err := s.writeHookSettings("sid123", "sess-token-abc")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	raw, err := os.ReadFile(filepath.Join(dir, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	var parsed struct {
		Hooks map[string][]struct {
			Hooks []struct{ Type, Command string }
		}
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("settings.json is not valid JSON: %v", err)
	}
	n, ok := parsed.Hooks["Notification"]
	if !ok || len(n) != 1 || len(n[0].Hooks) != 1 {
		t.Fatalf("want exactly one Notification hook, got %+v", parsed.Hooks)
	}
	cmd := n[0].Hooks[0].Command
	if !strings.Contains(cmd, "curl -K ") {
		t.Errorf("hook command should read its credential from a -K file: %q", cmd)
	}
	if strings.Contains(cmd, "sess-token-abc") {
		t.Errorf("session token leaked into the hook command string: %q", cmd)
	}
	if string(raw) != "" && strings.Contains(string(raw), "sess-token-abc") {
		t.Errorf("session token leaked into settings.json: %s", raw)
	}

	conf, err := os.ReadFile(filepath.Join(dir, "curl.conf"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"sess-token-abc", "/session/sid123/status", "127.0.0.1:8455"} {
		if !strings.Contains(string(conf), want) {
			t.Errorf("curl.conf missing %q: %s", want, conf)
		}
	}
	for _, f := range []string{"curl.conf", "settings.json"} {
		fi, err := os.Stat(filepath.Join(dir, f))
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != 0o600 {
			t.Errorf("%s mode = %v, want 0600", f, fi.Mode().Perm())
		}
	}
}

// The daemon must write nothing into the target project — that is what keeps
// DECISIONS.md's 2026-07-02 "zero Claude Code hooks in a project's settings"
// intact while still using the hook signal.
func TestSpawnLeavesProjectUntouched(t *testing.T) {
	bin, argvFile, _ := fakeSprint(t)
	root := t.TempDir()
	existing := filepath.Join(root, ".claude", "settings.local.json")
	if err := os.MkdirAll(filepath.Dir(existing), 0o755); err != nil {
		t.Fatal(err)
	}
	before := []byte(`{"permissions":{"ask":["Write"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}`)
	if err := os.WriteFile(existing, before, 0o644); err != nil {
		t.Fatal(err)
	}
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, addr: "127.0.0.1:8455", stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start: %d", resp.StatusCode)
	}
	resp.Body.Close()
	argv := waitFile(t, argvFile, 3*time.Second)

	after, err := os.ReadFile(existing)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("daemon modified the project's settings:\nbefore: %s\nafter:  %s", before, after)
	}
	entries, err := os.ReadDir(filepath.Join(root, ".claude"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("daemon added files to the project's .claude/: %v", entries)
	}
	// The hook rode in on argv instead, pointing outside the project.
	if !strings.Contains(argv, "--settings") {
		t.Fatalf("no --settings in argv: %q", argv)
	}
	if strings.Contains(argv, root) {
		t.Fatalf("--settings points inside the project: %q", argv)
	}
}

type gateModelCase struct{ Name, Plan, Parse, Expect string }

func loadGateModelFixtures(t *testing.T) []gateModelCase {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "tests", "fixtures", "gate-model-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx struct{ Cases []gateModelCase }
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no fixture cases loaded")
	}
	return fx.Cases
}

// TestParseGateModelFixtures and TestResolveGateModelFixtures run the real Go
// port over the same fixture set tests/gate-model-parity.sh feeds the real
// bash/awk implementation in tools/gate-model.sh. Both must agree, so a
// divergence in either port fails one of the two suites.
func TestParseGateModelFixtures(t *testing.T) {
	for _, c := range loadGateModelFixtures(t) {
		if got := parseGateModel(c.Plan); got != c.Parse {
			t.Errorf("%s: parseGateModel = %q, want %q", c.Name, got, c.Parse)
		}
	}
}

func TestResolveGateModelFixtures(t *testing.T) {
	for _, c := range loadGateModelFixtures(t) {
		root := t.TempDir()
		dir := filepath.Join(root, ".tickets", "t-ab12")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "plan.md"), []byte(c.Plan), 0o644); err != nil {
			t.Fatal(err)
		}
		s := newServer(config{projectRoot: root, stateDir: t.TempDir()})
		if got := s.gateModel("t-ab12"); got != c.Expect {
			t.Errorf("%s: gateModel = %q, want %q", c.Name, got, c.Expect)
		}
	}
}

// A missing plan.md is the common case for a brand-new ticket — no override, no error.
func TestResolveGateModelNoPlan(t *testing.T) {
	s := newServer(config{projectRoot: t.TempDir(), stateDir: t.TempDir()})
	if got := s.gateModel("t-ab12"); got != "" {
		t.Fatalf("gateModel with no plan.md = %q, want \"\"", got)
	}
}

// TestSpawnModelFlag proves the resolved model actually reaches argv (and that a
// rejected one does not). Value-level semantics are covered exhaustively by the
// fixture tests above; these are the end-to-end paths through spawn().
func TestSpawnModelFlag(t *testing.T) {
	for _, tc := range []struct {
		name, tierLine, wantArgv string
	}{
		{"resolved model reaches argv, prompt stays last",
			"Tier: high-risk | Risk: none | Gate model: haiku",
			"ARGC:3\nARG:--model\nARG:haiku\nARG:sprint start t-ab12\n"},
		{"no suffix means no flag",
			"Tier: normal | Risk: none",
			"ARGC:1\nARG:sprint start t-ab12\n"},
		{"session means no flag",
			"Tier: normal | Risk: none | Gate model: session",
			"ARGC:1\nARG:sprint start t-ab12\n"},
		{"a value with shell metacharacters never becomes an argv element",
			"Tier: normal | Risk: none | Gate model: haiku;touch$(id)",
			"ARGC:1\nARG:sprint start t-ab12\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bin, argvFile, _ := fakeSprint(t)
			root := t.TempDir()
			dir := filepath.Join(root, ".tickets", "t-ab12")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			plan := "# Plan\n\n## Sign-off\n" + tc.tierLine + "\n\n## Approach\n1. do it\n"
			if err := os.WriteFile(filepath.Join(dir, "plan.md"), []byte(plan), 0o644); err != nil {
				t.Fatal(err)
			}
			s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
			ts := httptest.NewServer(s.handler())
			t.Cleanup(ts.Close)

			resp := startSession(t, ts.URL, "t-ab12", bootTok)
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("start: %d", resp.StatusCode)
			}
			resp.Body.Close()
			if argv := waitFile(t, argvFile, 3*time.Second); argv != tc.wantArgv {
				t.Fatalf("argv = %q, want %q", argv, tc.wantArgv)
			}
		})
	}
}
