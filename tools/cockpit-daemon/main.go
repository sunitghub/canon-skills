// cockpit-daemon — a loopback-only, PTY-owning backend for the sprint-check
// cockpit. It launches `sprint start <id>` in a real pseudo-terminal so an
// interactive agent (claude/codex) behaves as if on a TTY, and bridges that
// PTY to the browser over stdlib SSE (output) + POST (input). No WebSocket.
//
// Security: binds loopback only; every endpoint (except /healthz) checks Host
// and Origin are loopback; /session/start requires the daemon boot token;
// per-session endpoints require that session's own token. Ticket ids are
// validated against ^t-[a-z0-9]{4}$ before they reach exec, and are never
// interpolated into a shell — the command is exec'd as an argv slice. No token
// is ever passed via argv.
package main

import (
	"crypto/rand"
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
	addr        string // loopback bind address
	token       string // daemon boot token (gates /session/start)
	sprintBin   string // binary to exec (default "sprint")
	projectRoot string // working dir for the spawned command
	scrollback  int    // bytes of replayable output per session
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
	pty    pty.Pty
	cmd    *pty.Cmd

	mu       sync.Mutex
	buf      []byte
	max      int
	subs     map[chan []byte]struct{}
	done     chan struct{}
	doneOnce sync.Once
	exited   bool
}

func newServer(cfg config) *server {
	if cfg.sprintBin == "" {
		cfg.sprintBin = "sprint"
	}
	if cfg.scrollback <= 0 {
		cfg.scrollback = 256 * 1024
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

// ── Handlers ─────────────────────────────────────────────────────────────

func (s *server) handleStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.cfg.token == "" || bearer(r) != s.cfg.token {
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

// spawn launches `sprint start <ticket>` in a PTY. The ticket is passed as a
// discrete argv element (never a shell string); no token is in the argv/env of
// the child.
func (s *server) spawn(ticket string) (*session, error) {
	p, err := pty.New()
	if err != nil {
		return nil, err
	}
	c := p.Command(s.cfg.sprintBin, "start", ticket)
	c.Dir = s.cfg.projectRoot
	c.Env = append(os.Environ(), "COCKPIT_TICKET="+ticket)
	if err := c.Start(); err != nil {
		p.Close()
		return nil, err
	}
	se := &session{
		sid: randToken()[:16], ticket: ticket, token: randToken(),
		pty: p, cmd: c, max: s.cfg.scrollback,
		subs: map[chan []byte]struct{}{}, done: make(chan struct{}),
	}
	s.mu.Lock()
	s.sessions[se.sid] = se
	s.mu.Unlock()
	go se.readLoop()
	go func() { _ = c.Wait() }() // reap on exit/kill so no zombie child is left
	return se, nil
}

// handleSession routes /session/{sid}/{stream|input|resize|kill}.
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
	if bearer(r) != se.token {
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

	ch := make(chan []byte, 256)
	se.mu.Lock()
	snapshot := append([]byte(nil), se.buf...)
	se.subs[ch] = struct{}{}
	exited := se.exited
	se.mu.Unlock()
	defer func() {
		se.mu.Lock()
		delete(se.subs, ch)
		se.mu.Unlock()
	}()

	if len(snapshot) > 0 {
		writeSSE(w, "out", snapshot)
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
				case chunk := <-ch:
					writeSSE(w, "out", chunk)
				default:
					writeSSE(w, "exit", nil)
					flusher.Flush()
					return
				}
			}
		case chunk := <-ch:
			writeSSE(w, "out", chunk)
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
	data, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if _, err := se.pty.Write(data); err != nil {
		http.Error(w, "write failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleResize(w http.ResponseWriter, r *http.Request, se *session) {
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
	killProcess(se.cmd) // platform-specific: no orphaned children
	se.pty.Close()
	se.markDone()
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
			for ch := range se.subs {
				select {
				case ch <- chunk:
				default:
				}
			}
			se.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	se.mu.Lock()
	se.exited = true
	se.mu.Unlock()
	se.markDone()
}

func (se *session) markDone() { se.doneOnce.Do(func() { close(se.done) }) }

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
		sprintBin:   envOr("COCKPIT_SPRINT_BIN", "sprint"),
		projectRoot: envOr("COCKPIT_PROJECT_ROOT", mustGetwd()),
	}
	s := newServer(cfg)

	ln, err := net.Listen("tcp", cfg.addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	if err := writeStateFile(ln.Addr().String(), cfg.token); err != nil {
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
func writeStateFile(addr, token string) error {
	dir := envOr("COCKPIT_STATE_DIR", defaultStateDir())
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
