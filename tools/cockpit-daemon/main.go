// cockpit-daemon — a loopback-only, PTY-owning backend for the sprint-check
// cockpit. It launches an interactive `claude` session on the ticket in a real
// pseudo-terminal, so the agent behaves as if on a TTY, and bridges that PTY to
// the browser over stdlib SSE (output) + POST (input). No WebSocket.
//
// Security: binds loopback only; every endpoint (except /healthz) checks Host
// and Origin are loopback; /session/start requires the daemon boot token;
// per-session endpoints require that session's own token. Ticket ids are
// validated against ^t-[a-z0-9]{4}$ before they reach exec, and are never
// interpolated into a shell — the command is exec'd as an argv slice. No token
// is ever passed via argv. The needs-you hook reads a STATUS-ONLY token from a
// 0600 curl -K file under the daemon's own state dir — deliberately not the
// session token, which would also authorize /input (see handleSession). The
// child inherits the daemon's environment verbatim, so an operator who exports
// COCKPIT_TOKEN does place the boot token there; no in-repo launcher does.
//
// Permissions are INHERITED, never overridden: no --permission-mode, no bypass
// flag, and nothing is ever written into the target project — the session's hook
// config rides in on --settings, which merges with (does not replace) whatever
// that project already configures.
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	pty "github.com/aymanbagabas/go-pty"
)

//go:embed web
var webFS embed.FS

var ticketRe = regexp.MustCompile(`^t-[a-z0-9]{4}$`)

type config struct {
	addr           string        // loopback bind address
	token          string        // daemon boot token (gates /session/start)
	sprintBin      string        // binary to exec (default "claude")
	projectRoot    string        // working dir for the spawned command
	scrollback     int           // bytes of replayable output per session
	sessionReapTTL time.Duration // grace period after natural exit before a session entry is reaped
	stateDir       string        // daemon-owned dir for daemon.json + per-session hook settings
}

type server struct {
	cfg      config
	mu       sync.Mutex
	sessions map[string]*session
}

type session struct {
	sid    string
	ticket string
	token  string
	// statusToken authorizes ONLY POST /session/<id>/status. Separate from token
	// because the needs-you hook's credential is reachable by the spawned agent.
	statusToken string
	pty         pty.Pty
	cmd         *pty.Cmd
	hookDir     string // daemon-owned ephemeral --settings dir; removed when the session ends

	mu            sync.Mutex
	buf           []byte
	max           int
	subs          map[chan frame]struct{}
	status        string // "running" | "needs-you"
	done          chan struct{}
	doneOnce      sync.Once
	exited        bool
	killed        bool   // set by handleKill so readLoop's natural-exit path skips the reaper (already deleted)
	onNaturalExit func() // set by spawn(); schedules the reap-after-TTL cleanup
}

// frame is one SSE event bound for the browser. Terminal output and status
// changes share the per-subscriber channel so they stay ordered relative to each
// other — a "needs-you" that arrived before the prompt was drawn would be
// confusing.
type frame struct {
	event string
	data  []byte
}

func newServer(cfg config) *server {
	if cfg.sprintBin == "" {
		cfg.sprintBin = "claude"
	}
	if cfg.scrollback <= 0 {
		cfg.scrollback = 256 * 1024
	}
	if cfg.sessionReapTTL <= 0 {
		cfg.sessionReapTTL = 15 * time.Minute
	}
	if cfg.stateDir == "" {
		cfg.stateDir = envOr("COCKPIT_STATE_DIR", defaultStateDir())
	}
	return &server{cfg: cfg, sessions: map[string]*session{}}
}

func randToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// ── HTTP wiring ────────────────────────────────────────────────────────────

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ok")
	})
	mux.HandleFunc("/cockpit", s.guard(s.handleCockpit))
	if sub, err := fs.Sub(webFS, "web"); err == nil {
		mux.Handle("/web/", s.guardHandler(http.StripPrefix("/web/", http.FileServer(http.FS(sub)))))
	}
	mux.HandleFunc("/session/start", s.guard(s.handleStart))
	mux.HandleFunc("/session/", s.guard(s.handleSession))
	return mux
}

func (s *server) guardHandler(next http.Handler) http.HandlerFunc {
	return s.guard(next.ServeHTTP)
}

// handleCockpit serves the same-origin cockpit page with the daemon boot token
// injected (loopback trust model — the page and the session API share an
// origin, so the token never crosses origins). An optional ?ticket= prefills
// the Start control; it is validated before injection.
func (s *server) handleCockpit(w http.ResponseWriter, r *http.Request) {
	raw, err := webFS.ReadFile("web/cockpit.html")
	if err != nil {
		http.Error(w, "cockpit page missing", http.StatusInternalServerError)
		return
	}
	ticket := r.URL.Query().Get("ticket")
	if !ticketRe.MatchString(ticket) {
		ticket = ""
	}
	// embed=1 trims the daemon page's own chrome (brand + ticket input) when the
	// board frames it; autostart=1 auto-launches the prefilled ticket. Both are
	// strictly "1" or empty — no other value is injected.
	embed := ""
	if r.URL.Query().Get("embed") == "1" {
		embed = "1"
	}
	autostart := ""
	if r.URL.Query().Get("autostart") == "1" {
		autostart = "1"
	}
	page := strings.ReplaceAll(string(raw), "__COCKPIT_TOKEN__", s.cfg.token)
	page = strings.ReplaceAll(page, "__COCKPIT_TICKET__", ticket)
	page = strings.ReplaceAll(page, "__COCKPIT_EMBED__", embed)
	page = strings.ReplaceAll(page, "__COCKPIT_AUTOSTART__", autostart)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	io.WriteString(w, page)
}

// guard enforces loopback Host + Origin on every guarded request.
func (s *server) guard(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !hostIsLoopback(r.Host) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if o := r.Header.Get("Origin"); o != "" && !originIsLoopback(o) {
			http.Error(w, "forbidden origin", http.StatusForbidden)
			return
		}
		next(w, r)
	}
}

func hostIsLoopback(host string) bool {
	h := host
	if hh, _, err := net.SplitHostPort(host); err == nil {
		h = hh
	}
	return h == "127.0.0.1" || h == "localhost" || h == "::1"
}

func originIsLoopback(origin string) bool {
	for _, p := range []string{"http://127.0.0.1", "http://localhost", "http://[::1]"} {
		if origin == p || strings.HasPrefix(origin, p+":") {
			return true
		}
	}
	return false
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		return strings.TrimSpace(h[len("Bearer "):])
	}
	return ""
}

// secureEqual compares tokens in constant time. An empty want or got never
// matches — subtle.ConstantTimeCompare("", "") would otherwise return 1.
func secureEqual(got, want string) bool {
	if got == "" || want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// ── Handlers ─────────────────────────────────────────────────────────────

func (s *server) handleStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.cfg.token == "" || !secureEqual(bearer(r), s.cfg.token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body struct {
		Ticket string `json:"ticket"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if !ticketRe.MatchString(body.Ticket) {
		http.Error(w, "invalid ticket id", http.StatusBadRequest)
		return
	}
	se, err := s.spawn(body.Ticket)
	if err != nil {
		http.Error(w, "spawn failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]string{"session": se.sid, "token": se.token})
}

// spawn launches an interactive `claude` session on the ticket in a PTY.
//
// The prompt is ONE argv element — exactly what a human would type at the
// prompt, and what the sprint skill's own trigger phrase recognizes. The old
// bash-CLI shape (`sprintBin "start" <ticket>`) must not be reused: `claude`
// treats unrecognized positionals as free-text prompt content and submits only
// the first, so the ticket id was silently dropped (verified live, t-842b).
// Still an argv slice, never a shell string; no token is in the argv of the child.
func (s *server) spawn(ticket string) (*session, error) {
	p, err := pty.New()
	if err != nil {
		return nil, err
	}
	sid, tok, statusTok := randToken()[:16], randToken(), randToken()
	var args []string
	if m := s.gateModel(ticket); m != "" {
		args = append(args, "--model", m)
	}
	// The Notification hook goes in via --settings, which loads ADDITIONAL
	// settings (verified: the project's own permissions.ask rules still fire), so
	// the daemon never writes into the target project. Losing the hook costs the
	// status signal, never the spawn.
	hookDir, err := s.writeHookSettings(sid, statusTok)
	switch {
	case err == nil:
		args = append(args, "--settings", filepath.Join(hookDir, "settings.json"))
	case !errors.Is(err, errNoDaemonAddr):
		fmt.Fprintf(os.Stderr, "cockpit: needs-you status unavailable: %v\n", err)
	}
	args = append(args, "sprint start "+ticket)
	c := p.Command(s.cfg.sprintBin, args...)
	c.Dir = s.cfg.projectRoot
	c.Env = append(os.Environ(), "COCKPIT_TICKET="+ticket)
	if err := c.Start(); err != nil {
		p.Close()
		os.RemoveAll(hookDir)
		return nil, err
	}
	se := &session{
		sid: sid, ticket: ticket, token: tok, statusToken: statusTok, hookDir: hookDir,
		pty: p, cmd: c, max: s.cfg.scrollback, status: "running",
		subs: map[chan frame]struct{}{}, done: make(chan struct{}),
	}
	// Natural exit (no explicit /kill) leaves the entry in s.sessions so a quick
	// reattach can still replay scrollback; reap it after a grace TTL so a
	// long-lived daemon doesn't accumulate dead sessions forever. handleKill's
	// own immediate delete is unaffected — it never sets onNaturalExit's timer.
	se.onNaturalExit = func() {
		time.AfterFunc(s.cfg.sessionReapTTL, func() {
			s.mu.Lock()
			delete(s.sessions, se.sid)
			s.mu.Unlock()
		})
	}
	s.mu.Lock()
	s.sessions[se.sid] = se
	s.mu.Unlock()
	go se.readLoop()
	go func() { _ = c.Wait() }() // reap on exit/kill so no zombie child is left
	return se, nil
}

// handleSession routes /session/{sid}/{stream|input|resize|kill|status}.
//
// Two capabilities, deliberately not one. The browser holds the session token,
// which authorizes stream/input/resize/kill. The needs-you hook holds a
// status-only token, because the hook runs as a child of the spawned agent and
// therefore anything the hook can read, the agent can read too (same UID — 0600
// keeps out other users, not this process). Issuing the hook the session token
// would hand the agent /input, i.e. the ability to write to its own PTY master
// and type the answer to its own permission prompt — which would quietly defeat
// the inherited-permissions guarantee this daemon is built on.
func (s *server) handleSession(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/session/")
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		http.NotFound(w, r)
		return
	}
	sid, action := parts[0], parts[1]
	s.mu.Lock()
	se := s.sessions[sid]
	s.mu.Unlock()
	if se == nil {
		http.Error(w, "no such session", http.StatusNotFound)
		return
	}
	if action == "status" {
		if !secureEqual(bearer(r), se.statusToken) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		s.handleStatus(w, r, se)
		return
	}
	if !secureEqual(bearer(r), se.token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	switch action {
	case "stream":
		s.handleStream(w, r, se)
	case "input":
		s.handleInput(w, r, se)
	case "resize":
		s.handleResize(w, r, se)
	case "kill":
		s.handleKill(w, r, se)
	default:
		http.NotFound(w, r)
	}
}

func (s *server) handleStream(w http.ResponseWriter, r *http.Request, se *session) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "stream unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	ch := make(chan frame, 256)
	se.mu.Lock()
	snapshot := append([]byte(nil), se.buf...)
	se.subs[ch] = struct{}{}
	exited, status := se.exited, se.status
	se.mu.Unlock()
	defer func() {
		se.mu.Lock()
		delete(se.subs, ch)
		se.mu.Unlock()
	}()

	if len(snapshot) > 0 {
		writeSSE(w, "out", snapshot)
	}
	// Replay the current status too: a reattaching tab must not show a green dot
	// for a session that is sitting on an unanswered permission prompt.
	if !exited && status != "" {
		writeSSE(w, "status", []byte(status))
	}
	if exited {
		writeSSE(w, "exit", nil)
	}
	flusher.Flush()

	ctx := r.Context()
	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-se.done:
			for {
				select {
				case f := <-ch:
					writeSSE(w, f.event, f.data)
				default:
					writeSSE(w, "exit", nil)
					flusher.Flush()
					return
				}
			}
		case f := <-ch:
			writeSSE(w, f.event, f.data)
			flusher.Flush()
		case <-keepalive.C:
			io.WriteString(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

func (s *server) handleInput(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if se.isExited() {
		http.Error(w, "session has exited", http.StatusGone)
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if _, err := se.pty.Write(data); err != nil {
		http.Error(w, "write failed", http.StatusInternalServerError)
		return
	}
	// The human just typed — whatever they were being asked, they are answering
	// it. Clears needs-you without needing a second hook event to tell us.
	se.setStatus("running")
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleResize(w http.ResponseWriter, r *http.Request, se *session) {
	if se.isExited() {
		http.Error(w, "session has exited", http.StatusGone)
		return
	}
	var body struct{ Cols, Rows int }
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&body); err != nil || body.Cols <= 0 || body.Rows <= 0 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	_ = se.pty.Resize(body.Cols, body.Rows)
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleKill(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	se.mu.Lock()
	se.killed = true
	se.mu.Unlock()
	killProcess(se.cmd) // platform-specific: no orphaned children
	se.pty.Close()
	se.markDone()
	se.cleanup()
	s.mu.Lock()
	delete(s.sessions, se.sid)
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// ── session I/O ────────────────────────────────────────────────────────────

func (se *session) readLoop() {
	b := make([]byte, 8192)
	for {
		n, err := se.pty.Read(b)
		if n > 0 {
			chunk := append([]byte(nil), b[:n]...)
			se.mu.Lock()
			se.buf = append(se.buf, chunk...)
			if len(se.buf) > se.max {
				se.buf = se.buf[len(se.buf)-se.max:]
			}
			se.broadcastLocked(frame{event: "out", data: chunk})
			se.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	se.mu.Lock()
	se.exited = true
	killed := se.killed
	se.mu.Unlock()
	se.markDone()
	se.cleanup()
	if !killed && se.onNaturalExit != nil {
		se.onNaturalExit()
	}
}

// broadcastLocked fans a frame out to every attached stream; the caller holds
// se.mu. Sends are non-blocking — a subscriber that has stopped draining loses
// frames rather than stalling the PTY reader.
func (se *session) broadcastLocked(f frame) {
	for ch := range se.subs {
		select {
		case ch <- f:
		default:
		}
	}
}

func (se *session) markDone() { se.doneOnce.Do(func() { close(se.done) }) }

// cleanup removes the daemon-owned --settings dir. Called on kill and on natural
// exit, so a long-lived daemon doesn't accumulate hook dirs.
func (se *session) cleanup() {
	if se.hookDir != "" {
		os.RemoveAll(se.hookDir)
	}
}

func (se *session) isExited() bool {
	se.mu.Lock()
	defer se.mu.Unlock()
	return se.exited
}

// ── needs-you status ───────────────────────────────────────────────────────

// errNoDaemonAddr means the hook has no callback URL to point at — only
// reachable before the listener is bound, so it is expected in unit tests and
// not worth a warning.
var errNoDaemonAddr = errors.New("daemon address unknown")

// writeHookSettings builds the daemon-owned, session-scoped settings file passed
// to `claude --settings`. It holds one Notification hook — the event Claude Code
// fires when it opens a permission prompt or otherwise waits on the human
// (verified live against a real permissions.ask prompt) — which posts
// "needs-you" back to this daemon.
//
// The credential is a STATUS-ONLY token (never the session token — see
// handleSession), and it travels in curl's -K config file rather than on curl's
// argv, so it never appears in `ps` output. Both files are 0600 under the
// daemon's own state dir, never inside the user's project. Returns the dir to
// clean up on exit.
func (s *server) writeHookSettings(sid, statusToken string) (string, error) {
	if s.cfg.addr == "" {
		return "", errNoDaemonAddr
	}
	dir, err := os.MkdirTemp(s.hookStateDir(), "session-")
	if err != nil {
		return "", err
	}
	// noproxy is load-bearing, not hygiene: curl honours http_proxy/ALL_PROXY from
	// the environment with no automatic localhost bypass, the hook inherits the
	// daemon's env, and the hook command ends `|| true` — so on any machine with a
	// proxy set the needs-you ping would be routed away and fail invisibly,
	// silently disabling the one signal this whole feature exists to provide.
	conf := fmt.Sprintf("url = \"http://%s/session/%s/status\"\nheader = \"Authorization: Bearer %s\"\nrequest = \"POST\"\ndata = \"needs-you\"\nnoproxy = \"*\"\nsilent\nmax-time = 3\n", s.cfg.addr, sid, statusToken)
	confPath := filepath.Join(dir, "curl.conf")
	if err := os.WriteFile(confPath, []byte(conf), 0o600); err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	// `|| true`: a status ping must never fail the agent's own turn.
	hook := map[string]any{
		"hooks": map[string]any{
			"Notification": []any{map[string]any{
				"hooks": []any{map[string]any{
					"type":    "command",
					"command": "curl -K " + shellQuote(confPath) + " >/dev/null 2>&1 || true",
				}},
			}},
		},
	}
	data, err := json.Marshal(hook)
	if err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), data, 0o600); err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	return dir, nil
}

// ticketsDir resolves `.tickets` by walking up from projectRoot, mirroring
// tools/ticket-root.sh's tickets_dir(). `tools/cockpit` sets
// COCKPIT_PROJECT_ROOT to $PWD, so launching `cockpit t-xxxx` from a
// subdirectory would otherwise make every Gate model: override a silent no-op —
// indistinguishable from "no plan.md yet", since both are just a read error.
func (s *server) ticketsDir() string {
	dir := s.cfg.projectRoot
	for dir != "" && dir != "/" {
		for _, marker := range []string{".tickets", ".git"} {
			if fi, err := os.Stat(filepath.Join(dir, marker)); err == nil && fi.IsDir() {
				return filepath.Join(dir, ".tickets")
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return filepath.Join(s.cfg.projectRoot, ".tickets")
}

// sweepStaleHookDirs removes leftover per-session hook dirs at boot. cleanup()
// handles the graceful paths (kill, natural exit), but a SIGKILLed or crashed
// daemon leaves them behind, each holding a curl.conf. Age-gated rather than
// unconditional so a concurrently running daemon sharing this state dir cannot
// have its live sessions swept out from under it. A stale token authorizes
// nothing — it names a session that died with its daemon — so this is disk
// hygiene, not a secret-expiry mechanism.
func (s *server) sweepStaleHookDirs(maxAge time.Duration) {
	dir := s.hookStateDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), "session-") {
			continue
		}
		info, err := e.Info()
		if err != nil || time.Since(info.ModTime()) < maxAge {
			continue
		}
		_ = os.RemoveAll(filepath.Join(dir, e.Name()))
	}
}

// hookStateDir lives under the same state dir as daemon.json, so
// COCKPIT_STATE_DIR relocates both together — a test or a second daemon that
// redirects its state must not still be writing hook files into the shared
// default.
func (s *server) hookStateDir() string {
	d := filepath.Join(s.cfg.stateDir, "hooks")
	_ = os.MkdirAll(d, 0o700)
	return d
}

// shellQuote single-quotes a path for the hook command string, which Claude Code
// runs through a shell. The path is daemon-generated (a temp dir under the state
// dir), but quoting it costs nothing and keeps that assumption from becoming
// load-bearing.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

var validStatuses = map[string]bool{"running": true, "needs-you": true}

// handleStatus receives the hook's ping. Session-token gated like every other
// per-session endpoint.
func (s *server) handleStatus(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<10))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	status := strings.TrimSpace(string(body))
	if !validStatuses[status] {
		http.Error(w, "unknown status", http.StatusBadRequest)
		return
	}
	se.setStatus(status)
	w.WriteHeader(http.StatusNoContent)
}

// setStatus records the new status and tells every attached browser. A no-op
// when nothing changed, so a chatty hook can't flood the stream.
func (se *session) setStatus(status string) {
	se.mu.Lock()
	defer se.mu.Unlock()
	if se.status == status || se.exited {
		return
	}
	se.status = status
	// Same critical section as the assignment: two concurrent callers can't
	// interleave into a stream order that disagrees with se.status.
	se.broadcastLocked(frame{event: "status", data: []byte(status)})
}

// ── gate model ─────────────────────────────────────────────────────────────

// This ports tools/gate-model.sh's gate_model_parse/gate_model_resolve to Go —
// the same job that script does for headless CI: turn a plan.md's `Gate model:`
// into a `--model` argv for `claude`. It is deliberately aligned to that awk
// program rather than to the board's own display-only reader
// (app.html's parseGateModel), which diverges more widely than label case: it
// also requires a literal `|` before the label, matches only an unindented
// capital-T `Tier:`, does not stop at the next `|`, and applies no charset guard
// — so the board's chip can display a value the daemon never passes. Two ports of one
// rule across runtimes that share no code is the cross-runtime exception in
// standards/efficiency.md; tests/gate-model-parity.sh pins both to one fixture
// set, so changing one without the other fails the suite.
var (
	// [ \t\r], not \s: awk is line-based so its [[:space:]] can never span lines,
	// but Go matches the whole document at once, where \s would let ^##\s+ run
	// across a newline. \r is kept so a CRLF plan.md parses the same either side.
	signoffHeadingRe = regexp.MustCompile(`(?m)^##[ \t]+Sign-off[ \t\r]*$`)
	nextHeadingRe    = regexp.MustCompile(`(?m)^##[ \t]`)
	tierLineRe       = regexp.MustCompile(`(?m)^[ \t]*[Tt]ier[ \t]*:.*$`)
	gateModelLabelRe = regexp.MustCompile(`[Gg]ate[ \t]+model[ \t]*:[ \t]*`)
	// Mirrors gate_model_resolve's charset guard. A shell is never involved (the
	// command is an argv slice), but the value still becomes an argv element, and
	// plan.md is writable by the very agent this value configures — so the guard
	// requires a LEADING letter or digit, not merely the allowed charset. `-` is
	// legal inside a model id (claude-sonnet-5); a leading one would turn
	// `--model <value>` into a second option, e.g.
	// `--model --dangerously-skip-permissions`, escalating the next session past
	// the inherited-permissions guarantee this daemon rests on.
	modelValueRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
)

// parseGateModel returns the raw lowercased `Gate model:` value from the
// Sign-off section's Tier line, or "" — gate_model_parse's contract.
func parseGateModel(content string) string {
	h := signoffHeadingRe.FindStringIndex(content)
	if h == nil {
		return ""
	}
	section := content[h[1]:]
	if n := nextHeadingRe.FindStringIndex(section); n != nil {
		section = section[:n[0]]
	}
	line := tierLineRe.FindString(section)
	if line == "" {
		return ""
	}
	m := gateModelLabelRe.FindStringIndex(line)
	if m == nil {
		return ""
	}
	v := line[m[1]:]
	// Stop at the next `|` — the value is one field of a pipe-delimited line —
	// then strip all whitespace, as the awk does.
	if i := strings.Index(v, "|"); i >= 0 {
		v = v[:i]
	}
	// ASCII-only, matching awk's C-locale [[:space:]] and tolower: strings.Fields
	// and strings.ToLower are Unicode-aware, so a NBSP inside the value would be
	// stripped here but rejected by the bash port — the two must not disagree.
	return strings.Map(func(r rune) rune {
		switch {
		case r == ' ' || r == '\t' || r == '\r' || r == '\n' || r == '\v' || r == '\f':
			return -1
		case r >= 'A' && r <= 'Z':
			return r + ('a' - 'A')
		}
		return r
	}, v)
}

// gateModel returns the model to pass as `--model` for this ticket, or "" when
// no override applies. `session` and an absent field both mean "the CLI's own
// default", matching gate_model_resolve. A present-but-invalid value is dropped
// with a stderr warning rather than aborting the spawn: headless CI can fail the
// whole run on a typo, but here a human is watching a terminal they just asked
// for, and killing the session would be a worse answer than starting it on the
// default model and saying so. ticket has already passed ticketRe, so it cannot
// traverse out of .tickets/.
func (s *server) gateModel(ticket string) string {
	plan := filepath.Join(s.ticketsDir(), ticket, "plan.md")
	b, err := os.ReadFile(plan)
	if err != nil {
		return ""
	}
	v := parseGateModel(string(b))
	// Absent, `session`, and `default` all mean "no override" — `default` is the
	// board dropdown's own label, so a hand-written one would otherwise be
	// forwarded as an invalid model id.
	if v == "" || v == "session" || v == "default" {
		return ""
	}
	if !modelValueRe.MatchString(v) {
		fmt.Fprintf(os.Stderr, "cockpit: ignoring invalid Gate model %q in %s (alias or model id — letters, digits, '.', '_', '-' only)\n", v, plan)
		return ""
	}
	return v
}

// ── helpers ────────────────────────────────────────────────────────────────

func writeSSE(w io.Writer, event string, data []byte) {
	fmt.Fprintf(w, "event: %s\n", event)
	fmt.Fprintf(w, "data: %s\n\n", base64.StdEncoding.EncodeToString(data))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

// ── main ───────────────────────────────────────────────────────────────────

func main() {
	addr := flag.String("addr", envOr("COCKPIT_ADDR", "127.0.0.1:8455"), "loopback bind address")
	flag.Parse()

	if !strings.HasPrefix(*addr, "127.0.0.1:") && !strings.HasPrefix(*addr, "localhost:") && !strings.HasPrefix(*addr, "[::1]:") {
		fmt.Fprintln(os.Stderr, "refusing non-loopback bind:", *addr)
		os.Exit(2)
	}
	cfg := config{
		addr:        *addr,
		token:       envOr("COCKPIT_TOKEN", randToken()),
		sprintBin:   envOr("COCKPIT_SPRINT_BIN", "claude"),
		projectRoot: envOr("COCKPIT_PROJECT_ROOT", mustGetwd()),
	}
	s := newServer(cfg)

	ln, err := net.Listen("tcp", cfg.addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	// The requested addr may carry port 0; the hook's callback URL needs the real
	// one the listener bound.
	s.cfg.addr = ln.Addr().String()
	s.sweepStaleHookDirs(24 * time.Hour)
	if err := writeStateFile(s.cfg.stateDir, ln.Addr().String(), cfg.token); err != nil {
		fmt.Fprintln(os.Stderr, "warning: state file:", err)
	}
	fmt.Fprintf(os.Stderr, "cockpit-daemon listening on %s\n", ln.Addr().String())
	srv := &http.Server{Handler: s.handler()}
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// writeStateFile hands the board the daemon's addr + boot token via a 0600
// file (never argv). The board reads it to authorize /session/start.
func writeStateFile(dir, addr, token string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f := filepath.Join(dir, "daemon.json")
	data, _ := json.Marshal(map[string]string{"addr": addr, "token": token})
	return os.WriteFile(f, data, 0o600)
}

func defaultStateDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "canon-cockpit")
	}
	if d, err := os.UserCacheDir(); err == nil {
		return filepath.Join(d, "canon-cockpit")
	}
	return filepath.Join(os.TempDir(), "canon-cockpit")
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustGetwd() string { d, _ := os.Getwd(); return d }
