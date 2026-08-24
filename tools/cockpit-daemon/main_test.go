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

// fakeSprint writes a script that stands in for `sprint`: it records its argv
// and pid, prints READY, then echoes stdin (so input round-trips). Set as
// COCKPIT_SPRINT_BIN. It never sees any daemon token.
func fakeSprint(t *testing.T) (bin, argvFile, pidFile string) {
	t.Helper()
	dir := t.TempDir()
	argvFile = filepath.Join(dir, "argv.txt")
	pidFile = filepath.Join(dir, "pid.txt")
	bin = filepath.Join(dir, "fake-sprint.sh")
	script := "#!/bin/sh\n" +
		"printf 'ARGV:%s\\n' \"$*\" > \"" + argvFile + "\"\n" +
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
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: t.TempDir()})
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

	// argv targeting + no-token-in-argv.
	argv := waitFile(t, argvFile, 3*time.Second)
	if !strings.Contains(argv, "start t-ab12") {
		t.Fatalf("argv not targeted at ticket: %q", argv)
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
	if resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("cockpit page Cache-Control: want no-store, got %q", resp.Header.Get("Cache-Control"))
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
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: t.TempDir(), sessionReapTTL: 50 * time.Millisecond})
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
