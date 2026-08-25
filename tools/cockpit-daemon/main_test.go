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
	// Writes to a .tmp path and renames into place so a concurrent reader (waitFile,
	// which returns as soon as the file is non-empty) never observes a partial
	// write — the file doesn't exist at all until the rename makes it appear whole.
	script := "#!/bin/sh\n" +
		"tmp=\"" + argvFile + ".tmp\"\n" +
		"printf 'ARGC:%s\\n' \"$#\" > \"$tmp\"\n" +
		"for a in \"$@\"; do printf 'ARG:%s\\n' \"$a\" >> \"$tmp\"; done\n" +
		"mv \"$tmp\" \"" + argvFile + "\"\n" +
		"printf '%s\\n' \"$$\" > \"" + pidFile + "\"\n" +
		"printf 'READY\\n'\n" +
		"cat\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

// newTestServer leaves cfg.addr empty on purpose: with no callback URL the hook
// is skipped, so argv stays exactly the joined prompt and the argv assertions
// don't have to carry a temp-dir path. Tests that need the hook use
// newTestServerWithAddr.
func newTestServer(t *testing.T, bin string) (*httptest.Server, string) {
	t.Helper()
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })
	return ts, ts.URL
}

// seedTicketDir creates <root>/.tickets/<ticket>/ so handleStart's existence
// check (t-ef59) doesn't reject the "t-ab12" happy path every other test
// assumes works. Empty is intentional — a ticket dir need not hold
// ticket.md/plan.md yet to be startable (t-ef59 ## Decisions).
func seedTicketDir(t *testing.T, root, ticket string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, ".tickets", ticket), 0o755); err != nil {
		t.Fatal(err)
	}
}

// killAllSessions kills every session's child process so a leaked fake-sprint.sh
// (blocked forever on "cat" reading stdin) doesn't survive the test — at
// stress-test iteration counts, enough leaked processes exhaust file
// descriptors and cause unrelated later spawns to fail with 500s. Registered
// as a t.Cleanup after ts.Close's, so it runs first (LIFO) and reaps
// processes before the TempDirs referenced by projectRoot/stateDir/fakeSprint
// are removed.
func killAllSessions(s *server) {
	s.mu.Lock()
	sessions := make([]*session, 0, len(s.sessions))
	for _, se := range s.sessions {
		sessions = append(sessions, se)
	}
	s.mu.Unlock()
	for _, se := range sessions {
		se.mu.Lock()
		se.killed = true
		se.mu.Unlock()
		killProcess(se.cmd)
		se.pty.Close()
		se.markDone()
		se.cleanup()
	}
}

// newTestServerWithAddr sets a callback addr (so the needs-you hook is written)
// and returns the *server, for tests that inspect per-session state such as the
// status-only token or the hook dir.
func newTestServerWithAddr(t *testing.T, bin string) (*httptest.Server, string, *server) {
	t.Helper()
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir(), addr: "127.0.0.1:8455"})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })
	return ts, ts.URL, s
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

// A shape-valid ticket id that doesn't exist in the project must never reach
// spawn(): the daemon's fixed prompt would resolve to nothing and the spawned
// agent goes hunting for context instead of failing clearly (t-842b, fixed by
// t-ef59).
func TestStartRejectsMissingTicketDir(t *testing.T) {
	bin, argvFile, _ := fakeSprint(t)
	root := t.TempDir() // no .tickets/ at all
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing ticket dir: want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
	if _, err := os.Stat(argvFile); err == nil {
		t.Fatal("a missing ticket dir still spawned a process (argv file exists)")
	}
}

// A ticket directory that exists but has no ticket.md/plan.md yet is still
// startable — the check is existence, not content completeness (t-ef59 ##
// Decisions).
func TestStartAllowsEmptyTicketDir(t *testing.T) {
	bin, argvFile, _ := fakeSprint(t)
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("empty ticket dir: want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()
	waitFile(t, argvFile, 3*time.Second)
}

// A .tickets/<id> path that exists as a file, not a directory, is treated as
// absent — IsDir(), not existence alone.
func TestStartRejectsTicketPathThatIsAFile(t *testing.T) {
	bin, argvFile, _ := fakeSprint(t)
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".tickets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".tickets", "t-ab12"), []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("ticket path is a file: want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
	if _, err := os.Stat(argvFile); err == nil {
		t.Fatal("a file-shaped ticket path still spawned a process (argv file exists)")
	}
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

	// argv targeting + no-token-in-argv. --session-id <uuid> then the joined
	// prompt — the two-arg bash-CLI shape drops the ticket id under a real
	// `claude` (t-842b); a fresh spawn always pins a session id (t-2e7e).
	argv := waitFile(t, argvFile, 3*time.Second)
	assertFreshSpawnArgv(t, argv, "sprint start t-ab12")
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

var testUUIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// assertFreshSpawnArgv checks the argv shape for a fresh (non-resumed)
// spawn — optionally a leading --model pair, then --session-id <uuid>, then
// the joined prompt as the last element — and returns the generated uuid
// (t-2e7e). extraArgc is any leading argv elements before --session-id
// (e.g. 2 for "--model haiku").
func assertFreshSpawnArgv(t *testing.T, argv, wantPrompt string, leading ...string) string {
	t.Helper()
	lines := strings.Split(strings.TrimRight(argv, "\n"), "\n")
	wantArgc := len(leading) + 3
	if len(lines) != wantArgc+1 || lines[0] != fmt.Sprintf("ARGC:%d", wantArgc) {
		t.Fatalf("argv shape unexpected: %q (want ARGC:%d)", argv, wantArgc)
	}
	for i, want := range leading {
		if lines[1+i] != "ARG:"+want {
			t.Fatalf("argv shape unexpected: %q (leading arg %d want %q)", argv, i, want)
		}
	}
	off := 1 + len(leading)
	if lines[off] != "ARG:--session-id" {
		t.Fatalf("argv shape unexpected: %q (want --session-id at position %d)", argv, off)
	}
	id := strings.TrimPrefix(lines[off+1], "ARG:")
	if !testUUIDRe.MatchString(id) {
		t.Fatalf("argv session id not a valid UUID: %q", id)
	}
	if lines[off+2] != "ARG:"+wantPrompt {
		t.Fatalf("argv shape unexpected: %q (want prompt %q at position %d)", argv, wantPrompt, off+2)
	}
	return id
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
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir(), sessionReapTTL: 50 * time.Millisecond})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })
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
	_, base, s := newTestServerWithAddr(t, bin)
	resp := startSession(t, base, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	// The hook holds a status-only token, not the session token.
	s.mu.Lock()
	se := s.sessions[out.Session]
	s.mu.Unlock()
	if se == nil {
		t.Fatal("session not registered")
	}
	statusTok := se.statusToken
	if statusTok == "" || statusTok == out.Token {
		t.Fatalf("status token must exist and differ from the session token (got %q vs %q)", statusTok, out.Token)
	}

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
	if got := post(strings.Repeat("z", len(statusTok)), "needs-you"); got != http.StatusUnauthorized {
		t.Fatalf("wrong token: want 401, got %d", got)
	}
	// Capability separation, both directions. The session token must not be able
	// to write status, and (the one that matters) the status token must not reach
	// /input — the endpoint that writes to the PTY master, which would let the
	// spawned agent answer its own permission prompt.
	if got := post(out.Token, "needs-you"); got != http.StatusUnauthorized {
		t.Fatalf("session token on /status: want 401, got %d", got)
	}
	for _, action := range []string{"input", "kill", "resize"} {
		req, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/"+action, strings.NewReader("1\n"))
		req.Header.Set("Authorization", "Bearer "+statusTok)
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		if r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("status token on /%s: want 401, got %d", action, r.StatusCode)
		}
	}
	for _, bad := range []string{"", "done", "NEEDS-YOU", "needs-you\x00extra", "running; rm -rf /"} {
		if got := post(statusTok, bad); got != http.StatusBadRequest {
			t.Fatalf("status %q: want 400, got %d", bad, got)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	buf := streamCollectFrames(t, ctx, base, out.Session, out.Token)
	waitFor(t, buf, "out=READY", 3*time.Second)

	if got := post(statusTok, "needs-you"); got != http.StatusNoContent {
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
	if strings.Contains(string(raw), "sess-token-abc") {
		t.Errorf("session token leaked into settings.json: %s", raw)
	}

	conf, err := os.ReadFile(filepath.Join(dir, "curl.conf"))
	if err != nil {
		t.Fatal(err)
	}
	// noproxy is asserted because its absence is silent: curl would route the ping
	// through a proxy and the hook's `|| true` would swallow the failure, disabling
	// needs-you with the whole suite still green.
	for _, want := range []string{"sess-token-abc", "/session/sid123/status", "127.0.0.1:8455", "noproxy = \"*\""} {
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
	seedTicketDir(t, root, "t-ab12")
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
	t.Cleanup(func() { killAllSessions(s) })

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

// TestHookDirLifecycle pins the two halves of hook-dir hygiene: kill removes the
// live session's dir, and the boot sweep clears crash debris while leaving a
// concurrent daemon's fresh dirs alone. Without these, deleting both cleanup()
// call sites left the whole suite green.
func TestHookDirLifecycle(t *testing.T) {
	bin, _, _ := fakeSprint(t)
	_, base, s := newTestServerWithAddr(t, bin)
	resp := startSession(t, base, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	s.mu.Lock()
	se := s.sessions[out.Session]
	s.mu.Unlock()
	if se == nil || se.hookDir == "" {
		t.Fatal("expected a hook dir for a session started with a known addr")
	}
	if _, err := os.Stat(se.hookDir); err != nil {
		t.Fatalf("hook dir missing while the session is live: %v", err)
	}

	killReq, _ := http.NewRequest(http.MethodPost, base+"/session/"+out.Session+"/kill", nil)
	killReq.Header.Set("Authorization", "Bearer "+out.Token)
	kr, err := http.DefaultClient.Do(killReq)
	if err != nil {
		t.Fatal(err)
	}
	kr.Body.Close()
	if _, err := os.Stat(se.hookDir); !os.IsNotExist(err) {
		t.Fatalf("hook dir survived kill: %v", err)
	}

	// Boot sweep: an old dir goes, a fresh one stays.
	hooks := s.hookStateDir()
	old := filepath.Join(hooks, "session-old")
	fresh := filepath.Join(hooks, "session-fresh")
	for _, d := range []string{old, fresh} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	stale := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(old, stale, stale); err != nil {
		t.Fatal(err)
	}
	s.sweepStaleHookDirs(24 * time.Hour)
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Errorf("stale hook dir survived the sweep: %v", err)
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Errorf("sweep removed a fresh hook dir (would clobber a live sibling daemon): %v", err)
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
		name, tierLine string
		wantLeading    []string // leading argv elements before --session-id, if any
	}{
		{"resolved model reaches argv, prompt stays last",
			"Tier: high-risk | Risk: none | Gate model: haiku",
			[]string{"--model", "haiku"}},
		{"no suffix means no flag",
			"Tier: normal | Risk: none",
			nil},
		{"session means no flag",
			"Tier: normal | Risk: none | Gate model: session",
			nil},
		{"a value with shell metacharacters never becomes an argv element",
			"Tier: normal | Risk: none | Gate model: haiku;touch$(id)",
			nil},
		// plan.md is writable by the agent this value configures, so a value that
		// could be re-read as a flag must never reach argv — otherwise a session
		// could escalate the next one past the inherited-permissions guarantee.
		{"a leading-hyphen value never reaches argv as a second flag",
			"Tier: normal | Risk: none | Gate model: --dangerously-skip-permissions",
			nil},
		{"a real hyphenated model id still reaches argv",
			"Tier: normal | Risk: none | Gate model: claude-sonnet-5",
			[]string{"--model", "claude-sonnet-5"}},
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
			t.Cleanup(func() { killAllSessions(s) })

			resp := startSession(t, ts.URL, "t-ab12", bootTok)
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("start: %d", resp.StatusCode)
			}
			resp.Body.Close()
			argv := waitFile(t, argvFile, 3*time.Second)
			assertFreshSpawnArgv(t, argv, "sprint start t-ab12", tc.wantLeading...)
		})
	}
}

// ── t-2e7e: session id resume/fresh + idle reaping ──────────────────────────

func writeTicketStatus(t *testing.T, root, ticket, status string) {
	t.Helper()
	dir := filepath.Join(root, ".tickets", ticket)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := "---\nid: " + ticket + "\nstatus: " + status + "\n---\n# test\n"
	if err := os.WriteFile(filepath.Join(dir, "ticket.md"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestResolveClaudeSessionID(t *testing.T) {
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{projectRoot: root, stateDir: t.TempDir()})

	// No ticket.md at all → fresh, and the id gets persisted.
	id1, resuming := s.resolveClaudeSessionID("t-ab12")
	if resuming {
		t.Fatal("expected fresh (no status file), got resuming")
	}
	if !testUUIDRe.MatchString(id1) {
		t.Fatalf("id1 not a valid UUID: %q", id1)
	}
	persisted, err := os.ReadFile(filepath.Join(root, ".tickets", "t-ab12", ".cockpit-session-id"))
	if err != nil || strings.TrimSpace(string(persisted)) != id1 {
		t.Fatalf("id1 not persisted correctly: %v %q", err, persisted)
	}

	// status: open (not in_progress) with a persisted id from above → still
	// fresh; a reopened ticket must never resume a stale, unrelated conversation.
	writeTicketStatus(t, root, "t-ab12", "open")
	id2, resuming := s.resolveClaudeSessionID("t-ab12")
	if resuming || id2 == id1 {
		t.Fatalf("expected a fresh id on status:open, got resuming=%v id=%q (was %q)", resuming, id2, id1)
	}

	// status: in_progress with a persisted id → resume that exact id.
	writeTicketStatus(t, root, "t-ab12", "in_progress")
	id3, resuming := s.resolveClaudeSessionID("t-ab12")
	if !resuming || id3 != id2 {
		t.Fatalf("expected resume of %q, got resuming=%v id=%q", id2, resuming, id3)
	}
}

func TestSpawnResumesPersistedSessionOnlyWhenInProgress(t *testing.T) {
	bin, argvFile, _ := fakeSprint(t)
	root := t.TempDir()
	writeTicketStatus(t, root, "t-ab12", "open")
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	// First spawn: status is "open" → fresh --session-id.
	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start: %d", resp.StatusCode)
	}
	resp.Body.Close()
	argv := waitFile(t, argvFile, 3*time.Second)
	firstID := assertFreshSpawnArgv(t, argv, "sprint start t-ab12")

	// Flip to in_progress (as the real sprint skill would) and spawn again —
	// must resume the SAME id via --resume, never --fork-session.
	writeTicketStatus(t, root, "t-ab12", "in_progress")
	if err := os.Truncate(argvFile, 0); err != nil {
		t.Fatal(err)
	}
	resp2 := startSession(t, ts.URL, "t-ab12", bootTok)
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("second start: %d", resp2.StatusCode)
	}
	resp2.Body.Close()
	argv2 := waitFile(t, argvFile, 3*time.Second)
	want := "ARGC:2\nARG:--resume\nARG:" + firstID + "\n"
	if argv2 != want {
		t.Fatalf("resume argv = %q, want %q", argv2, want)
	}
	if strings.Contains(argv2, "--fork-session") {
		t.Fatalf("resume argv must never include --fork-session: %q", argv2)
	}
}

// fakeAgentThatSaves simulates a real agent responding to the daemon's
// injected save prompt: on seeing that specific text on stdin, it prints the
// exact marker line (t-2e7e). Never exits on its own (like fakeSprint), so
// the test controls its lifetime entirely via the reaper/kill.
func fakeAgentThatSaves(t *testing.T) (bin string) {
	t.Helper()
	dir := t.TempDir()
	bin = filepath.Join(dir, "fake-agent-saves.sh")
	script := "#!/bin/sh\n" +
		"printf 'READY\\n'\n" +
		"while IFS= read -r line; do\n" +
		"  case \"$line\" in\n" +
		"    *'save your current state'*) printf '" + cockpitSaveMarker + "\\n' ;;\n" +
		"  esac\n" +
		"done\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

// fakeAgentThatIgnores never responds to anything on stdin — used to exercise
// the save-fallback force-kill path (t-2e7e).
func fakeAgentThatIgnores(t *testing.T) (bin string) {
	t.Helper()
	dir := t.TempDir()
	bin = filepath.Join(dir, "fake-agent-ignores.sh")
	script := "#!/bin/sh\nprintf 'READY\\n'\ncat >/dev/null\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

func TestIdleReapSparesNeedsYouSession(t *testing.T) {
	bin := fakeAgentThatIgnores(t)
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{
		token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir(),
		idleTimeout: 50 * time.Millisecond, idleCheckInterval: 20 * time.Millisecond,
	})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	s.mu.Lock()
	se := s.sessions[out.Session]
	s.mu.Unlock()
	se.setStatus("needs-you")

	// Well past idleTimeout — if the exemption didn't work, this would be reaped.
	time.Sleep(300 * time.Millisecond)

	s.mu.Lock()
	_, stillThere := s.sessions[out.Session]
	s.mu.Unlock()
	if !stillThere {
		t.Fatal("needs-you session was reaped — must always be exempted")
	}
}

func TestIdleReapKillsIdleSessionAfterSaveMarker(t *testing.T) {
	bin := fakeAgentThatSaves(t)
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{
		token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir(),
		idleTimeout: 50 * time.Millisecond, idleCheckInterval: 20 * time.Millisecond,
		saveFallback: 3 * time.Second,
	})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		_, stillThere := s.sessions[out.Session]
		s.mu.Unlock()
		if !stillThere {
			return // reaped — success
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("idle session with a responsive fake agent was never reaped")
}

func TestIdleReapFallbackKillsWhenMarkerNeverAppears(t *testing.T) {
	bin := fakeAgentThatIgnores(t)
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{
		token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir(),
		idleTimeout: 50 * time.Millisecond, idleCheckInterval: 20 * time.Millisecond,
		saveFallback: 200 * time.Millisecond,
	})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	// idleTimeout (50ms) + saveFallback (200ms) + generous margin.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		_, stillThere := s.sessions[out.Session]
		s.mu.Unlock()
		if !stillThere {
			return // fallback force-killed it — success
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("idle session with an unresponsive fake agent was never fallback-killed")
}

// fakeAgentWithStaleMarker prints the exact marker line unprompted, early in
// its own output (simulating an unrelated earlier mention of this feature's
// own marker string), then goes unresponsive like fakeAgentThatIgnores. Used
// to prove saveAndEndIdle only counts output written AFTER its save prompt
// (t-2e7e regression: a naive whole-buffer scan would false-kill instantly).
func fakeAgentWithStaleMarker(t *testing.T) (bin string) {
	t.Helper()
	dir := t.TempDir()
	bin = filepath.Join(dir, "fake-agent-stale-marker.sh")
	// The trailing "sleep 1" guarantees the marker line lands in se.buf and
	// this process goes truly idle well before idleTimeout elapses — without
	// it, a short test idleTimeout can race the shell's own fork/exec/printf
	// startup, letting the reaper fire before the "stale" line even exists.
	script := "#!/bin/sh\n" +
		"printf '" + cockpitSaveMarker + "\\n'\n" +
		"sleep 1\n" +
		"cat >/dev/null\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

func TestIdleReapIgnoresMarkerPredatingTheSavePrompt(t *testing.T) {
	bin := fakeAgentWithStaleMarker(t)
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	s := newServer(config{
		token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir(),
		// idleTimeout generous enough that fork/exec/shell-startup latency under
		// heavy machine load (e.g. running alongside other -race tests) can never
		// race past it before the stale marker is flushed — a 150ms budget was
		// reviewer-caught as flaky under load (reproduced: 3/3 failures running 3
		// copies concurrently under -race). 2s comfortably exceeds observed worst-case.
		idleTimeout: 2 * time.Second, idleCheckInterval: 50 * time.Millisecond,
		// saveFallback deliberately longer than saveAndEndIdle's fixed 500ms poll
		// interval, so the "early" check below lands after at least one real poll
		// (where a whole-buffer-scan bug would already have false-killed) but well
		// before the fallback would kill it anyway — otherwise the fallback alone
		// could mask a broken marker scan.
		saveFallback: 6 * time.Second,
	})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	// The stale marker lands in se.buf immediately (before idle-reap even
	// starts). Wait past idleTimeout + one 500ms poll tick, so a whole-buffer
	// scan bug would already have false-killed by now.
	time.Sleep(3 * time.Second)
	s.mu.Lock()
	_, stillThereEarly := s.sessions[out.Session]
	s.mu.Unlock()
	if !stillThereEarly {
		t.Fatal("session was killed on a stale marker line that predates any save prompt")
	}

	// It must still be reaped eventually via the fallback (the agent never
	// responds to the real save prompt either) — proving this isn't just a
	// reaper that silently never fires.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		_, stillThere := s.sessions[out.Session]
		s.mu.Unlock()
		if !stillThere {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("session was never reaped via the fallback path")
}

// TestIdleReapAbortsWhenHumanReturnsMidSave proves saveAndEndIdle honors
// plan.md's stated guarantee ("any real activity resets it") even after the
// save-and-kill sequence has already begun (t-2e7e, reviewer-caught: the
// original implementation only checked activity BEFORE starting the
// sequence, never during the wait for the save marker/fallback).
func TestIdleReapAbortsWhenHumanReturnsMidSave(t *testing.T) {
	bin := fakeAgentThatIgnores(t)
	root := t.TempDir()
	seedTicketDir(t, root, "t-ab12")
	// Generous absolute values (not just generous ratios) so this survives
	// -race contention the way TestIdleReapIgnoresMarkerPredatingTheSavePrompt
	// initially didn't. idleTimeout(1s) means the first reap cycle starts
	// ~1-1.4s in; saveFallback(4s) puts its ORIGINAL kill deadline at roughly
	// t=5.4s if never aborted. The human's input lands well before that. If
	// the fix works, the abort happens within one 100ms poll tick and the
	// session survives past t=5.4s; a *second*, legitimate idle cycle (the
	// fake agent still never responds) won't reach its own kill deadline
	// until ~t=6.5s+, so checking at t=6.0s cleanly distinguishes "aborted
	// the original kill" from "never aborted at all."
	s := newServer(config{
		token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir(),
		idleTimeout: time.Second, idleCheckInterval: 100 * time.Millisecond,
		saveFallback: 4 * time.Second,
	})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })

	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	var out struct{ Session, Token string }
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()

	// Wait for the reaper to fire and enter its save-and-wait window, then
	// confirm it's mid-sequence.
	time.Sleep(1500 * time.Millisecond)
	s.mu.Lock()
	se, ok := s.sessions[out.Session]
	s.mu.Unlock()
	if !ok {
		t.Fatal("session already gone before the human could respond")
	}
	se.mu.Lock()
	reaping := se.reaping
	se.mu.Unlock()
	if !reaping {
		t.Fatal("reaper never entered the save-and-wait sequence")
	}

	// A human sends real input mid-wait — this must abort the pending kill.
	inReq, _ := http.NewRequest(http.MethodPost, ts.URL+"/session/"+out.Session+"/input", strings.NewReader("still here\n"))
	inReq.Header.Set("Authorization", "Bearer "+out.Token)
	ir, err := http.DefaultClient.Do(inReq)
	if err != nil {
		t.Fatal(err)
	}
	ir.Body.Close()
	if ir.StatusCode != http.StatusNoContent {
		t.Fatalf("input: want 204, got %d", ir.StatusCode)
	}

	// Confirm the session survives past what would have been the ORIGINAL
	// fallback kill (~t=5.4-5.8s) and before a legitimate second idle cycle's
	// own deadline could plausibly fire (~t=6.5s+) — see comment above.
	time.Sleep(4500 * time.Millisecond)
	s.mu.Lock()
	_, stillThere := s.sessions[out.Session]
	s.mu.Unlock()
	if !stillThere {
		t.Fatal("session was killed even though a human sent real input mid-save-wait")
	}
}
