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
	"crypto/sha256"
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
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	pty "github.com/aymanbagabas/go-pty"
)

//go:embed web
var webFS embed.FS

var ticketRe = regexp.MustCompile(`^t-[a-z0-9]{4}$`)

// sessionIDRe is what /cockpit and /session/start accept: a ticket id, or a scratch
// session id (t-47f1: "s-" + 4 lowercase alphanumerics, minted by the board) for an
// agent started without a ticket. Validated before any file-path or argv use.
var sessionIDRe = regexp.MustCompile(`^[ts]-[a-z0-9]{4}$`)

// isScratch reports whether a (validated) session id is a scratch session (t-47f1).
func isScratch(id string) bool { return strings.HasPrefix(id, "s-") }

// cwdPrefillRe bounds the ?cwd= query param safe to embed in a JS string
// literal on the (token-less, loopback-only) /cockpit page — no quotes,
// backslashes, or newlines. /session/start re-validates the real value
// independently; this only prevents script injection into the prefill.
//
// t-7590: the colon is REQUIRED for Windows — every absolute path there starts
// with a drive letter (`C:/Users/...`), and the board sends worktree paths with
// forward slashes (git's own separator). Without `:` the regex rejected every
// Windows worktree cwd, `handleCockpit` dropped it to "", and the daemon
// silently spawned in the main checkout regardless of the selection — the
// redirect never worked on Windows. Backslashes stay excluded (JS-string escape
// hazard, and unnecessary since the board normalizes to forward slashes); a
// quote is still rejected, so JS injection remains impossible.
var cwdPrefillRe = regexp.MustCompile(`^[A-Za-z0-9._:/-]+$`)

type config struct {
	addr              string        // loopback bind address
	token             string        // daemon boot token (gates /session/start)
	sprintBin         string        // binary to exec (default "claude")
	projectRoot       string        // working dir for the spawned command
	scrollback        int           // bytes of replayable output per session
	sessionReapTTL    time.Duration // grace period after natural exit before a session entry is reaped
	stateDir          string        // daemon-owned dir for daemon.json + per-session hook settings
	idleTimeout       time.Duration // t-2e7e: reap a session after this much PTY inactivity (default 5m, nebula's own default)
	idleTimeoutMain   time.Duration // t-cd06: longer idle timeout for a main-checkout session (default 30m) — nebula's own 5m default assumes a disposable worktree; the main checkout has no such disposability, so it keeps a longer but still-bounded safety net rather than running forever unreaped
	idleCheckInterval time.Duration // t-2e7e: how often to scan for idle sessions (default 30s)
	saveFallback      time.Duration // t-2e7e: force-kill if the save marker never appears within this long (default 60s)
	saveQuiesce       time.Duration // t-2c9e: after a watched state file changes, conclude "saved" once writes quiesce for this long (default 2s) — mtime-bump != save-complete, so this debounce avoids killing mid-multi-file-write
}

type server struct {
	cfg       config
	mu        sync.Mutex
	sessions  map[string]*session
	scratchMu sync.Mutex // t-e162: serializes scratch starts (main-checkout-or-worktree choice)
}

type session struct {
	scratchWT *scratchWorktree // t-e162: daemon-created worktree to remove on exit if unused
	title     string           // t-f553: a scratch session's user-given title (sanitized)
	sid       string
	ticket    string
	token     string
	// statusToken authorizes ONLY POST /session/<id>/status. Separate from token
	// because the needs-you hook's credential is reachable by the spawned agent.
	statusToken string
	// previewToken authorizes ONLY GET /session/<id>/preview/<relpath> (t-b19b).
	// Separate from token for the same reason as statusToken, one level further:
	// it rides in a query string (an <iframe src> can't carry an Authorization
	// header) where the PREVIEWED PAGE'S OWN untrusted JS can read it straight off
	// location.search — it must never be able to do anything but read files under
	// the resolved preview root.
	previewToken string
	pty          pty.Pty
	cmd          *pty.Cmd
	hookDir      string    // daemon-owned ephemeral --settings dir; removed when the session ends
	cwd          string    // t-cd06: resolved spawn cwd — read-only after spawn(), decides idle-timeout tier
	projectRoot  string    // t-391a: per-session project root (git toplevel of cwd) — scopes ticket/preview, so one daemon serves many projects (nebula model)
	ticketsDir   string    // t-ffb9: parent of the session's state dir, resolved once at spawn() — .tickets/ for a ticket, the daemon's scratch dir for a scratch session (t-47f1) — lets debugf (no *server access) find it without re-walking
	agent        string    // t-391a: agent kind ("claude"/"pi"/"copilot") for the /sessions listing
	started      time.Time // t-391a: spawn time for the /sessions listing
	// copilotResumeAttempt is true iff this spawn used copilot's --resume=<id>
	// (t-6ce0) — read-only after spawn(), same convention as agent/cwd above.
	// handleStart uses it to grace-check for a dead-resume failure and retry
	// fresh before the client ever sees this session.
	copilotResumeAttempt bool

	mu            sync.Mutex
	buf           []byte
	max           int
	subs          map[chan frame]struct{}
	status        string    // "running" | "needs-you" | "awaiting-input" (t-824e: finished, at the prompt)
	statusSince   time.Time // t-824e: when status last changed — /sessions reports how long a session has waited
	done          chan struct{}
	doneOnce      sync.Once
	closeOnce     sync.Once // t-b999: ConPTY's Close calls ClosePseudoConsole — never twice
	exited        bool
	killed        bool      // set by handleKill so readLoop's natural-exit path skips the reaper (already deleted)
	reaping       bool      // t-2e7e: set while saveAndEndIdle is in flight, guards against a second reap goroutine
	onNaturalExit func()    // set by spawn(); schedules the reap-after-TTL cleanup
	lastActivity  time.Time // t-2e7e: bumped on PTY output and on input; idle reaper's clock
	cols, rows    int       // t-6291: last size from /resize (0 = unknown) — Save & End's screen model needs it to wrap and scroll like the terminal
	menuSince     time.Time // t-7c4f: when a pending Copilot menu was first seen (zero when none)
	humanInputAt  time.Time // t-2e7e: bumped ONLY by a real POST /input (not PTY output/echo);
	// lets an in-flight save-and-kill detect a human actually came back and abort
	previewRoot string // t-b19b: symlink-validated dir under projectRoot or the session's own worktree cwd (t-8e73); set once via /preview-root
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
	if cfg.idleTimeout <= 0 {
		cfg.idleTimeout = 5 * time.Minute
	}
	if cfg.idleTimeoutMain <= 0 {
		cfg.idleTimeoutMain = 30 * time.Minute
	}
	if cfg.idleCheckInterval <= 0 {
		cfg.idleCheckInterval = 30 * time.Second
	}
	if cfg.saveFallback <= 0 {
		cfg.saveFallback = 60 * time.Second
	}
	if cfg.saveQuiesce <= 0 {
		cfg.saveQuiesce = 2 * time.Second
	}
	s := &server{cfg: cfg, sessions: map[string]*session{}}
	s.startIdleReaper()
	return s
}

func randToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// newUUIDv4 hand-formats 16 random bytes as RFC 4122 — no new dependency for
// one formatting function. `claude --session-id` requires "a valid UUID"
// (t-2e7e).
func newUUIDv4() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ── HTTP wiring ────────────────────────────────────────────────────────────

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ok")
	})
	// t-99fa: unauthenticated build-version readout (like /healthz) so the board
	// can show which daemon build is running. t-74d6: also report the mtime of
	// this daemon's own executable, captured at startup — the board compares it
	// to the on-disk binary's mtime to detect a version-drifted (stale) daemon.
	// A plain version string is insufficient: local `dev` builds all report the
	// same string, so a string compare could never flag a rebuilt-in-place binary.
	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"version": version, "commit": commit, "exe_mtime": execMtime, "uptime_secs": int64(time.Since(startTime).Seconds()), "debug_enabled": debugEnabled.Load(),
			"idle_timeout_secs": int64(s.cfg.idleTimeout.Seconds()), "idle_timeout_main_secs": int64(s.cfg.idleTimeoutMain.Seconds())}) // t-824e: Admin's reaper line
	})
	// t-ffb9: toggles verbose session-lifecycle logging (see debugf). Deliberately
	// token-free like /version/healthz, NOT s.guard-wrapped like /session/* or
	// /shutdown — the board (server.py) never holds the daemon's token by design
	// (t-ddc8), so an authenticated proxy isn't possible without a much larger
	// architecture change. This adds no new capability beyond flipping a
	// diagnostic switch (no session control, no data exposure); the daemon's
	// existing loopback-only bind is what actually gates every token-free
	// endpoint, this one included.
	mux.HandleFunc("/admin/debug", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Enabled bool `json:"enabled"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<10)).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		debugEnabled.Store(body.Enabled)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"enabled": debugEnabled.Load()})
	})
	// t-74d6: authorized, gated daemon shutdown so the board can replace a stale
	// build. Boot-token gated (checked inside handleShutdown), refuses while a
	// session is live unless ?force=1 — never a blind kill. Guarded for loopback
	// like the rest; the cockpit page (which holds the token) calls it, not the
	// token-free board.
	mux.HandleFunc("/shutdown", s.guard(s.handleShutdown))
	mux.HandleFunc("/cockpit", s.guard(s.handleCockpit))
	if sub, err := fs.Sub(webFS, "web"); err == nil {
		mux.Handle("/web/", s.guardHandler(http.StripPrefix("/web/", http.FileServer(http.FS(sub)))))
	}
	mux.HandleFunc("/session/start", s.guard(s.handleStart))
	mux.HandleFunc("/sessions", s.guard(s.handleSessions))
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
	if !sessionIDRe.MatchString(ticket) {
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
	// t-cd06: ?cwd= prefills the WORKTREE selection the board made. This route
	// has no token (only loopback-origin guard), so the value is validated the
	// same conservative way as ticket above before it's embedded in a JS string
	// literal — /session/start re-validates it independently regardless.
	cwd := r.URL.Query().Get("cwd")
	if cwd != "" && (!filepath.IsAbs(cwd) || !cwdPrefillRe.MatchString(cwd)) {
		cwd = ""
	}
	// t-0d67: Start picker default + "last used" hint. Only meaningful once the
	// ticket has been started before (a .cockpit-agent exists); a fresh ticket
	// defaults to claude with no hint. The model is shown only where canon knows
	// it — claude's plan.md Gate model; pi runs its own default.
	agentDefault := "claude"
	agentHint := ""
	if ticket != "" {
		if b, err := os.ReadFile(filepath.Join(s.ticketsDir(), ticket, ".cockpit-agent")); err == nil {
			if k, ok := agentKind(strings.TrimSpace(string(b))); ok {
				agentDefault = k
				switch k {
				case "pi":
					agentHint = "Last used: Pi \u00b7 model: pi default"
				case "copilot":
					agentHint = "Last used: Copilot CLI \u00b7 model: " + agentDisplayModel(s.gateModel(ticket))
				default:
					agentHint = "Last used: Claude Code \u00b7 model: " + agentDisplayModel(s.gateModel(ticket))
				}
			}
		}
	}
	page := strings.ReplaceAll(string(raw), "__COCKPIT_TOKEN__", s.cfg.token)
	page = strings.ReplaceAll(page, "__COCKPIT_TICKET__", ticket)
	page = strings.ReplaceAll(page, "__COCKPIT_EMBED__", embed)
	page = strings.ReplaceAll(page, "__COCKPIT_AUTOSTART__", autostart)
	page = strings.ReplaceAll(page, "__COCKPIT_CWD__", cwd)
	page = strings.ReplaceAll(page, "__COCKPIT_AGENT__", agentDefault)
	page = strings.ReplaceAll(page, "__COCKPIT_AGENT_HINT__", agentHint)
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
		Cwd    string `json:"cwd"`
		Agent  string `json:"agent"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if !sessionIDRe.MatchString(body.Ticket) {
		http.Error(w, "invalid ticket id", http.StatusBadRequest)
		return
	}
	scratch := isScratch(body.Ticket)
	// t-0d67: the agent choice is client-supplied — validate against the fixed
	// {claude, pi} allowlist here, so the daemon never resolves an arbitrary
	// program. "" defaults to claude (back-compatible).
	kind, ok := agentKind(body.Agent)
	if !ok {
		http.Error(w, "invalid agent", http.StatusBadRequest)
		return
	}
	// t-391a: derive the project from the (re-validated) client cwd so ONE
	// daemon serves tickets from ANY project (nebula's model), not only the
	// launch-time COCKPIT_PROJECT_ROOT. resolveProjectForCwd re-validates the
	// cwd (abs, exists, a real git working tree) — the daemon never trusts the
	// client string (t-b19b/t-cd06) — and returns the MAIN checkout (where a
	// gitignored .tickets/ lives).
	projectRoot, ok := s.resolveProjectForCwd(body.Cwd)
	if !ok {
		http.Error(w, "cwd not allowed", http.StatusBadRequest)
		return
	}
	// Shape-valid is not enough: with no such ticket in the resolved project,
	// spawn()'s fixed "sprint start <id>" prompt resolves to nothing, and the
	// spawned agent goes hunting for context instead of failing clearly (t-842b).
	if !scratch {
		if fi, err := os.Stat(filepath.Join(s.ticketsDirIn(projectRoot), body.Ticket)); err != nil || !fi.IsDir() {
			http.Error(w, "ticket not found in project", http.StatusBadRequest)
			return
		}
	}
	// t-cd06: the daemon re-validates cwd itself against a live `git worktree
	// list` — it never trusts whatever cockpit.html relayed, mirroring
	// previewRootFor's "daemon never trusts the client" precedent (t-b19b).
	// For an already in_progress ticket, the persisted cwd from its first
	// start wins over whatever the client sent — a live conversation must
	// never be reattached in a different directory than it started in.
	cwd, ok := s.resolveSpawnCwdForTicket(body.Ticket, body.Cwd, projectRoot)
	if !ok {
		http.Error(w, "cwd not allowed", http.StatusBadRequest)
		return
	}
	// t-e5ff: a git worktree materializes only *tracked* files, so when
	// `.tickets/` is gitignored the ticket dir is absent in a non-main worktree
	// cwd — a sprint spawned there lands somewhere it can't see its own ticket.
	// For any cwd other than the project's main checkout, require the ticket dir
	// to be physically present at that cwd. The main checkout already passed the
	// existence check above.
	if scratch && !pathsEqual(cwd, projectRoot) {
		http.Error(w, "the daemon picks a scratch session's directory — start it from the project's main checkout", http.StatusBadRequest)
		return
	}
	if !pathsEqual(cwd, projectRoot) {
		if fi, serr := os.Stat(filepath.Join(cwd, ".tickets", body.Ticket)); serr != nil || !fi.IsDir() {
			http.Error(w, "ticket not visible in this worktree (.tickets/ is gitignored) — start from the main checkout", http.StatusBadRequest)
			return
		}
	}
	// t-c6fa: a live session for this ticket already exists (e.g. a second
	// browser tab, or a stale tab plus a fresh Resume click) — attach to it
	// instead of spawning a second PTY that would race the first for the same
	// underlying `claude --resume` conversation. Matches t-a98b's wanted
	// "reattach to a still-live session" behavior. Scoped by projectRoot too,
	// not ticket ID alone: one daemon serves many projects (t-391a), and
	// ticket IDs are only unique within one project's .tickets/.
	if scratch {
		// t-e162: scratch starts are serialized so two can't both see the main checkout free.
		s.scratchMu.Lock()
		defer s.scratchMu.Unlock()
	}
	if existing := s.liveSessionForTicket(projectRoot, body.Ticket); existing != nil {
		existing.debugf("start attached to live session sid=%s cwd=%s requested=%s", existing.sid, existing.cwd, s.resolveRequestedEcho(body.Cwd))
		writeJSON(w, map[string]string{"session": existing.sid, "token": existing.token, "previewToken": existing.previewToken, "cwd": existing.cwd, "requested": s.resolveRequestedEcho(body.Cwd)})
		return
	}
	var wt *scratchWorktree
	if scratch {
		// t-47f1: a scratch session has no ticket; its state lives under the daemon's own
		// state dir (sessionStateDir). Created only now, after every refusal above, so a
		// refused start leaves nothing behind.
		// t-e162: the main checkout is free → run there; otherwise in a new worktree.
		if s.mainCheckoutBusy(projectRoot) {
			created, err := createScratchWorktree(projectRoot)
			if err != nil {
				http.Error(w, "could not create a worktree for this scratch session: "+err.Error(), http.StatusInternalServerError)
				return
			}
			wt, cwd = created, created.Path
		}
		stateDir := s.sessionStateDir(projectRoot, body.Ticket)
		if err := os.MkdirAll(stateDir, 0o700); err != nil {
			if wt != nil {
				wt.remove(projectRoot, func(string, ...any) {})
			}
			http.Error(w, "scratch state unavailable", http.StatusInternalServerError)
			return
		}
	}
	se, err := s.spawn(body.Ticket, cwd, projectRoot, kind)
	if err != nil && wt != nil {
		wt.remove(projectRoot, func(format string, a ...any) {}) // nothing ran in it yet
	}
	if err != nil {
		http.Error(w, "spawn failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if se.copilotResumeAttempt {
		se, err = s.recoverCopilotResumeIfFailed(se, body.Ticket, cwd, projectRoot)
		if err != nil {
			http.Error(w, "spawn failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
	}
	if wt != nil {
		// t-e162: hand the worktree to the session so cleanup() removes it on exit if
		// unused. An agent that already exited missed that cleanup — do it here.
		se.mu.Lock()
		exited := se.exited
		if !exited {
			se.scratchWT = wt
		}
		se.mu.Unlock()
		if exited {
			wt.remove(projectRoot, se.debugf)
		}
	}
	// Record the last-used agent for the picker's default + hint (only when
	// changed). After a successful spawn, so a failed start never records.
	s.persistAgentKindIn(projectRoot, body.Ticket, kind)
	// t-7590: echo the cwd the daemon actually resolved and spawned in (may
	// differ from what the client requested — a locked in_progress ticket
	// reuses its persisted .cockpit-cwd while that still re-validates, an empty request resolves to the main
	// checkout). The board displays this as the authoritative "Working in:" so a
	// wrong-tree run can never hide behind an optimistic pre-Start label.
	//
	// t-eed3: also echo `requested` = the RESOLVED form of what the client asked
	// for, computed the same way resolveSpawnCwd resolves it (empty → projectRoot;
	// non-empty → EvalSymlinks, fallback raw). The board can't resolve symlinks in
	// JS, so it compares `cwd` (actual) against this daemon-resolved `requested`
	// like-for-like: a same-directory-different-symlink (e.g. /tmp vs /private/tmp
	// on macOS) then matches and no longer raises a spurious mismatch warning,
	// while a genuine wrong-tree run (actual differs from both selected and
	// requested) still warns.
	requested := s.resolveRequestedEcho(body.Cwd)
	// t-75cb: the cwd actually used vs the one asked for — a persisted .cockpit-cwd lock can
	// override the picker, and that is the first thing to check when a run lands in the wrong tree.
	se.debugf("start spawned new session sid=%s cwd=%s requested=%s cwd_differs=%v", se.sid, cwd, requested, !pathsEqual(cwd, requested))
	writeJSON(w, map[string]string{"session": se.sid, "token": se.token, "previewToken": se.previewToken, "cwd": cwd, "requested": requested})
}

// resolveRequestedEcho computes the RESOLVED form of what the client asked
// for (t-eed3), shared by the fresh-spawn and attach-to-existing (t-c6fa)
// response paths so both echo `requested` identically.
func (s *server) resolveRequestedEcho(cwdRequested string) string {
	if cwdRequested == "" {
		return s.cfg.projectRoot
	}
	if rr, rerr := filepath.EvalSymlinks(cwdRequested); rerr == nil {
		return rr
	}
	return cwdRequested
}

// mainCheckoutBusy reports whether a live session (ticket or scratch) runs in
// projectRoot's main checkout (t-e162: a new scratch then gets its own worktree).
func (s *server) mainCheckoutBusy(projectRoot string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, se := range s.sessions {
		se.mu.Lock()
		busy := !se.exited && pathsEqual(se.projectRoot, projectRoot) && pathsEqual(se.cwd, projectRoot)
		se.mu.Unlock()
		if busy {
			return true
		}
	}
	return false
}

// scratchWorktree is a worktree the daemon created for a scratch session (t-e162).
type scratchWorktree struct {
	Path   string
	Branch string
	Base   string // commit it started from
}

// createScratchWorktree adds a worktree on branch scratch/<n> — the smallest n ≥ 1 that
// is neither a branch nor an existing path — at the board's sibling convention
// <root>/../<name>-worktrees/scratch-<n>, from the main checkout's HEAD. Branch and path
// are daemon-generated; git runs as an argv slice.
func createScratchWorktree(root string) (*scratchWorktree, error) {
	git := func(args ...string) (string, error) {
		out, err := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput()
		return strings.TrimSpace(string(out)), err
	}
	base, err := git("rev-parse", "HEAD")
	if err != nil {
		return nil, fmt.Errorf("no commit to branch from (%s)", base)
	}
	parent := filepath.Join(filepath.Dir(root), filepath.Base(root)+"-worktrees")
	for n := 1; n <= 1000; n++ {
		branch := fmt.Sprintf("scratch/%d", n)
		path := filepath.Join(parent, fmt.Sprintf("scratch-%d", n))
		if _, err := git("rev-parse", "--verify", "--quiet", "refs/heads/"+branch); err == nil {
			continue
		}
		if _, err := os.Stat(path); err == nil {
			continue
		}
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return nil, err
		}
		if out, err := git("worktree", "add", path, "-b", branch, base); err != nil {
			return nil, fmt.Errorf("git worktree add: %s", out)
		}
		if resolved, err := filepath.EvalSymlinks(path); err == nil {
			path = resolved
		}
		return &scratchWorktree{Path: path, Branch: branch, Base: base}, nil
	}
	return nil, errors.New("no free scratch/<n> branch")
}

// remove deletes the worktree and its branch only when nothing was done in it: no
// uncommitted changes and no commits beyond Base (on HEAD or the branch). Any git
// error keeps both — a kept worktree is recoverable, a deleted one is not.
func (wt *scratchWorktree) remove(root string, logf func(string, ...any)) {
	if dirty, err := checkoutDirty(wt.Path); err != nil || dirty {
		logf("scratch worktree %s kept: uncommitted changes (or git failed: %v)", wt.Branch, err)
		return
	}
	for _, ref := range []string{"HEAD", wt.Branch} {
		out, err := exec.Command("git", "-C", wt.Path, "rev-list", "--count", wt.Base+".."+ref).Output()
		if err != nil || strings.TrimSpace(string(out)) != "0" {
			logf("scratch worktree %s kept: commits beyond its start on %s (or git failed: %v)", wt.Branch, ref, err)
			return
		}
	}
	if out, err := exec.Command("git", "-C", root, "worktree", "remove", wt.Path).CombinedOutput(); err != nil {
		logf("scratch worktree %s kept: git worktree remove failed: %s", wt.Branch, strings.TrimSpace(string(out)))
		return
	}
	_ = exec.Command("git", "-C", root, "branch", "-D", wt.Branch).Run()
	logf("scratch worktree %s removed (nothing done in it)", wt.Branch)
}

// liveSessionForTicket returns the first non-exited session bound to ticket
// within projectRoot, or nil (t-c6fa). Scoped by projectRoot too, not ticket
// ID alone — see the handleStart call site's own comment for why.
func (s *server) liveSessionForTicket(projectRoot, ticket string) *session {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, se := range s.sessions {
		if se.ticket != ticket || se.projectRoot != projectRoot {
			continue
		}
		se.mu.Lock()
		exited := se.exited
		se.mu.Unlock()
		if !exited {
			return se
		}
	}
	return nil
}

// resolveSpawnBin resolves the spawn command against PATH to an absolute path
// before it reaches the PTY. This matters on Windows: the daemon sets Cmd.Dir,
// and go-pty's Windows lookExtensions resolves a *bare* command name relative
// to Dir (filepath.Join(Dir, name)) rather than searching %PATH% — so a
// PATH-installed `claude` is never found while a working dir is set (t-35b3,
// live-reproduced: `where claude` succeeds yet Start fails with
// `<cwd>\claude ... not found in %PATH%`). exec.LookPath searches PATH+PATHEXT
// and returns an absolute path, which go-pty's volume-name branch resolves
// regardless of Dir. On a genuine miss, fall back to the raw value so the
// resulting error still names the command. No-op effect on macOS (go-pty's Unix
// path already resolves on PATH; an absolute path stays valid).
func resolveSpawnBin(bin string) string {
	if lp, err := exec.LookPath(bin); err == nil {
		return lp
	}
	return bin
}

// taskkillTreeArgs builds the Windows `taskkill` argv that terminates a process
// AND its children (`/T` = tree, `/F` = force). Kept build-tag-free in main.go
// (used only by kill_windows.go's killProcess) so the Windows tree-kill argv is
// unit-testable on any host (t-902f). Unix reaps the whole process group instead
// (kill_unix.go); this is the Windows equivalent — no orphaned children.
func taskkillTreeArgs(pid int) []string {
	return []string{"/PID", strconv.Itoa(pid), "/T", "/F"}
}

// agentKind normalizes and validates the client-supplied agent choice for the
// cockpit (t-0d67; copilot added t-66b2). "" defaults to claude (back-compatible).
// Only claude, pi, and copilot are allowed — the daemon must never resolve an
// arbitrary client-supplied program, so an unknown value is rejected (ok=false →
// handleStart 400s).
func agentKind(a string) (string, bool) {
	switch a {
	case "", "claude":
		return "claude", true
	case "pi":
		return "pi", true
	case "copilot":
		return "copilot", true
	default:
		return "", false
	}
}

// agentSpawnArgs builds the PTY command args (after the program) for the chosen
// agent (t-0d67; copilot added t-66b2). claude is byte-identical to the
// pre-t-0d67 argv: [--model <m>] [--settings <path>] then (--resume <id>) or
// (--session-id <id> "sprint start <ticket>"). pi uses documented flags only
// (option B): a positional "sprint start <ticket>" for a fresh start, and `-c`
// (continue most recent session in the cwd) when the ticket is already
// in_progress (a resume) — no claude-only --settings/--session-id/--model (no
// shell hooks; needs-you is a Phase-2 pi extension). copilot mirrors claude's
// optional-flag shape: [--model <m>] then (--resume=<id>) or (--session-id <id>
// --interactive <prompt>) — no --settings equivalent (copilot hooks are
// file-configured, not per-invocation, and it has no Notification-hook-equivalent
// event regardless; needs-you falls back to the same PTY-quiescence path pi
// already uses). copilot takes 0 positional arguments (verified live against
// `copilot --help`, t-842b's claude-positional trick does not carry over): the
// fresh-start prompt must go through -i/--interactive, not a bare positional —
// a bare positional fails with "error: too many arguments. Expected 0
// arguments but got 1". Pure/side-effect-free so it is unit-testable on any
// host.
func agentSpawnArgs(kind, ticket string, resuming bool, sessionID, gateModel, settingsPath string) []string {
	prompt := "sprint start " + ticket
	if isScratch(ticket) {
		prompt = "" // t-47f1: a scratch session is the plain agent — no sprint, no prompt
	}
	if kind == "pi" {
		if resuming {
			return []string{"-c"}
		}
		if prompt == "" {
			return nil
		}
		return []string{prompt}
	}
	// claude and copilot share this shape; only --settings (claude-only), the
	// --resume flag's syntax (space-separated vs. copilot's --resume=<id>), and
	// the fresh-start prompt (positional vs. copilot's --interactive) differ.
	var args []string
	if kind == "copilot" {
		gateModel = copilotModel(gateModel)
	}
	if gateModel != "" {
		args = append(args, "--model", gateModel)
	}
	if settingsPath != "" {
		args = append(args, "--settings", settingsPath)
	}
	switch {
	case !resuming && kind == "copilot":
		args = append(args, "--session-id", sessionID)
		if prompt != "" {
			args = append(args, "--interactive", prompt)
		}
	case !resuming:
		args = append(args, "--session-id", sessionID)
		if prompt != "" {
			args = append(args, prompt)
		}
	case kind == "copilot":
		args = append(args, "--resume="+sessionID)
	default:
		args = append(args, "--resume", sessionID)
	}
	return args
}

// copilotModelIDs maps the Claude Code aliases the board writes to `Gate model:`
// onto Copilot's own model ids (t-d8b0): Copilot's --model rejects the aliases
// ("Model \"haiku\" from --model flag is not available."), and its haiku id
// differs from the Anthropic API id. Only ids verified in Copilot's model list
// (t-bdce) are mapped; the same pairs back complete.md's Copilot gate-dispatch
// note. An alias with no verified id maps to "" — no --model, so the session
// starts on Copilot's default instead of failing.
var copilotModelIDs = map[string]string{
	"sonnet": "claude-sonnet-5",
	"haiku":  "claude-haiku-4.5",
	"opus":   "",
	"fable":  "",
}

// copilotModel returns the --model value for a copilot spawn: the mapped id for a
// Claude alias (case-insensitive), "" for an alias Copilot has no verified id
// for, and any other value (a full id such as gpt-5.4) unchanged.
func copilotModel(gateModel string) string {
	if id, ok := copilotModelIDs[strings.ToLower(gateModel)]; ok {
		return id
	}
	return gateModel
}

// agentDisplayModel sanitizes a model string for injection into cockpit.html's
// "last used" hint (t-0d67). The value comes from plan.md's `Gate model:`, a
// repo file — keep only a conservative charset so it can never break out of the
// injected JS string literal; empty/over-long/odd values fall back to "default".
func agentDisplayModel(m string) string {
	m = strings.TrimSpace(m)
	if m == "" || len(m) > 40 {
		return "default"
	}
	for _, r := range m {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			r == '.' || r == '_' || r == '-' || r == ':' || r == '/'
		if !ok {
			return "default"
		}
	}
	return m
}

// persistAgentKind records the last-used agent for the ticket, writing only when
// it changed (t-0d67). Deterministic (called by the daemon at spawn), never
// dependent on Save & End / agent-written HANDOFF. Best-effort: a write failure
// must never block a spawn that already succeeded.
// persistAgentKindIn records the last-used agent under an arbitrary project root (t-391a).
func (s *server) persistAgentKindIn(root, ticket, kind string) {
	p := filepath.Join(s.sessionStateDir(root, ticket), ".cockpit-agent")
	if b, err := os.ReadFile(p); err == nil && strings.TrimSpace(string(b)) == kind {
		return
	}
	_ = os.WriteFile(p, []byte(kind+"\n"), 0o644)
}

// spawn launches an interactive `claude` session on the ticket in a PTY.
//
// The prompt is ONE argv element — exactly what a human would type at the
// prompt, and what the sprint skill's own trigger phrase recognizes. The old
// bash-CLI shape (`sprintBin "start" <ticket>`) must not be reused: `claude`
// treats unrecognized positionals as free-text prompt content and submits only
// the first, so the ticket id was silently dropped (verified live, t-842b).
// Still an argv slice, never a shell string; no token is in the argv of the child.
func (s *server) spawn(ticket, cwd, projectRoot, kind string) (*session, error) {
	p, err := pty.New()
	if err != nil {
		return nil, err
	}
	sid, tok, statusTok, previewTok := randToken()[:16], randToken(), randToken(), randToken()
	var args []string
	var hookDir string
	// t-0d67: agent-aware spawn. claude keeps its exact pre-t-0d67 argv (--model,
	// --settings Notification hook, --session-id/--resume). pi uses documented
	// flags only and no shell hooks. copilot (t-66b2) mirrors claude's argv shape
	// but has no --settings equivalent (no Notification-hook-equivalent event
	// exists to wire up regardless — see resolveCopilotSessionIDIn/agentSpawnArgs).
	program := s.cfg.sprintBin // claude default / COCKPIT_SPRINT_BIN override
	copilotResuming := false   // t-6ce0: surfaced onto the session below
	copilotGate := ""          // t-d8b0: logged below when copilot can't take it
	switch kind {
	case "pi":
		program = envOr("COCKPIT_PI_BIN", "pi")
		// Resume (pi -c) when the ticket is already in_progress; else a fresh
		// positional "sprint start <ticket>". Option B — see agentSpawnArgs.
		args = agentSpawnArgs("pi", ticket, s.ticketStatusIn(projectRoot, ticket) == "in_progress", "", "", "")
	case "copilot":
		program = envOr("COCKPIT_COPILOT_BIN", "copilot")
		copilotSessionID, resuming := s.resolveCopilotSessionIDIn(projectRoot, ticket)
		copilotResuming = resuming
		copilotGate = s.gateModelIn(projectRoot, ticket)
		args = agentSpawnArgs("copilot", ticket, resuming, copilotSessionID, copilotGate, "")
	default:
		// The Notification hook goes in via --settings, which loads ADDITIONAL
		// settings (verified: the project's own permissions.ask rules still fire), so
		// the daemon never writes into the target project. Losing the hook costs the
		// status signal, never the spawn.
		var herr error
		hookDir, herr = s.writeHookSettings(sid, statusTok)
		settingsPath := ""
		switch {
		case herr == nil:
			settingsPath = filepath.Join(hookDir, "settings.json")
		case !errors.Is(herr, errNoDaemonAddr):
			fmt.Fprintf(os.Stderr, "cockpit: needs-you status unavailable: %v\n", herr)
		}
		// t-2e7e: pin/resume a claude session id. Never --fork-session alongside
		// --resume — that mints a NEW id instead of continuing the real
		// conversation, defeating the whole point.
		claudeSessionID, resuming := s.resolveClaudeSessionIDIn(projectRoot, ticket)
		args = agentSpawnArgs("claude", ticket, resuming, claudeSessionID, s.gateModelIn(projectRoot, ticket), settingsPath)
		if resuming && s.adoptedTicket(projectRoot, ticket) && s.ticketStatusIn(projectRoot, ticket) == "open" {
			// t-f553: the scratch conversation continues — as this ticket's sprint.
			args = append(args, "sprint start "+ticket)
		}
	}
	bin := resolveSpawnBin(program)
	c := p.Command(bin, args...)
	c.Dir = cwd
	c.Env = append(os.Environ(), "COCKPIT_TICKET="+ticket)
	if err := c.Start(); err != nil {
		p.Close()
		os.RemoveAll(hookDir)
		return nil, err
	}
	// t-cd06: best-effort, non-fatal — a logging failure (disk full, read-only
	// fs) must never block a real spawn that already succeeded.
	s.logSessionStart(ticket, cwd, projectRoot)
	se := &session{
		sid: sid, ticket: ticket, token: tok, statusToken: statusTok, previewToken: previewTok,
		hookDir: hookDir, cwd: cwd, projectRoot: projectRoot, ticketsDir: filepath.Dir(s.sessionStateDir(projectRoot, ticket)), // Join(ticketsDir, ticket) = the session's state dir (t-47f1)
		agent: kind, started: time.Now(), copilotResumeAttempt: copilotResuming,
		pty: p, cmd: c, max: s.cfg.scrollback, status: "running", statusSince: time.Now(),
		subs: map[chan frame]struct{}{}, done: make(chan struct{}),
		lastActivity: time.Now(), // not the zero value, or it reads as instantly idle
	}
	// t-75cb: the binary actually run and its full argv (flags, ids, the fixed prompt —
	// never a token: the status token rides in the settings FILE) so a wrong flag is
	// visible at once (t-d8b0's `copilot --model haiku` would have been).
	se.debugf("spawn agent=%s ticket=%s cwd=%s resuming=%v bin=%q argv=%q", kind, ticket, cwd, copilotResuming, bin, args)
	if copilotGate != "" && copilotModel(copilotGate) == "" {
		se.debugf("spawn model=%s omitted for copilot (no verified Copilot id)", copilotGate)
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
	go se.waitExit(c.Wait, exitDrainGrace) // reaps the child (no zombie) and ends readLoop on Windows
	return se, nil
}

// handleSessions lists the daemon's active sessions across ALL projects it
// serves (t-391a — nebula's model: one daemon, many projects, so the board
// renders a session list rather than a daemon roster). Unauthenticated like
// /version — the token-free board must read it (t-ddc8: the boot token stays
// daemon-side; the board never holds it), but still behind guard() so it's
// loopback-only and Origin-checked (no cross-origin browser read). Returns
// ticket/project/cwd/agent/status/started only — never any token, so exposing
// it token-free leaks nothing a local `ps` couldn't already show.
func (s *server) handleSessions(w http.ResponseWriter, r *http.Request) {
	type sessionInfo struct {
		Session     string `json:"session"`
		Ticket      string `json:"ticket"`
		ProjectRoot string `json:"project_root"`
		Cwd         string `json:"cwd"`
		Agent       string `json:"agent"`
		Status      string `json:"status"`
		Started     string `json:"started"`
		// t-824e: the one place session state is decided; the pages only display it.
		State         string `json:"state"`           // needs-you | done | working | idle
		StateSecs     int64  `json:"state_secs"`      // seconds in this state (idle: since last activity)
		IdleSecs      int64  `json:"idle_secs"`       // seconds since terminal output or input
		IdleLimitSecs int64  `json:"idle_limit_secs"` // the reaper's timeout for this session
		Signal        string `json:"signal"`          // where needs-you comes from: hook | copilot-menu | activity
		Title         string `json:"title,omitempty"` // t-f553: a scratch session's user-given title
	}
	// Lock order is s.mu (outer) then se.mu (inner), matching handleShutdown.
	s.mu.Lock()
	out := make([]sessionInfo, 0, len(s.sessions))
	for _, se := range s.sessions {
		se.mu.Lock()
		exited := se.exited
		info := sessionInfo{
			Session: se.sid, Ticket: se.ticket, ProjectRoot: se.projectRoot,
			Cwd: se.cwd, Agent: se.agent, Status: se.status,
			Started: se.started.UTC().Format(time.RFC3339),
		}
		info.State, info.StateSecs, info.IdleSecs, info.Signal = sessionStateLocked(se, time.Now())
		info.Title = se.title
		se.mu.Unlock()
		if !exited {
			out = append(out, info)
		}
	}
	s.mu.Unlock()
	// idleTimeoutFor resolves symlinks on disk — done outside the locks.
	for i := range out {
		out[i].IdleLimitSecs = int64(s.idleTimeoutFor(out[i].ProjectRoot, out[i].Cwd).Seconds())
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// workingWindow: terminal output or input within this long counts as working (t-824e grill).
const workingWindow = 15 * time.Second

// sessionStateLocked derives the displayed state (caller holds se.mu). needs-you: the hook saw a
// question, or a Copilot menu is pending; done: the hook saw the agent finish / idle at its
// prompt; otherwise working or idle by last activity.
func sessionStateLocked(se *session, now time.Time) (state string, stateSecs, idleSecs int64, signal string) {
	idle := now.Sub(se.lastActivity)
	idleSecs = int64(idle.Seconds())
	since := int64(now.Sub(se.statusSince).Seconds())
	switch se.agent {
	case "copilot":
		signal = "copilot-menu"
	case "pi":
		signal = "activity"
	default:
		signal = "hook"
	}
	// t-7c4f: Copilot redraws while its menu waits, so the menu's age can't come from
	// lastActivity — remember when it was first seen instead.
	menu := se.menuPendingLocked()
	if !menu {
		se.menuSince = time.Time{}
	} else if se.menuSince.IsZero() {
		se.menuSince = now
	}
	switch {
	case se.status == "needs-you":
		return "needs-you", since, idleSecs, signal
	case menu:
		return "needs-you", int64(now.Sub(se.menuSince).Seconds()), idleSecs, signal
	case se.status == "awaiting-input":
		return "done", since, idleSecs, signal
	case idle < workingWindow:
		return "working", idleSecs, idleSecs, signal
	}
	return "idle", idleSecs, idleSecs, signal
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
	// t-b19b/t-8fbc: authenticated via a path-segment previewToken, never
	// se.token — an <iframe src> navigation can't carry an Authorization header,
	// and this is the one route a browser loads by direct GET rather than
	// fetch(). The token is the FIRST segment after "preview/"
	// (/session/<sid>/preview/<token>/<relpath>) rather than a ?token= query so
	// that a relative subresource request (./style.css) keeps it — a query
	// string is dropped on relative resolution, a path prefix is not (t-8fbc).
	if tokenAndPath, ok := strings.CutPrefix(action, "preview/"); ok {
		s.handlePreview(w, r, se, tokenAndPath)
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
	case "save-and-end":
		s.handleSaveAndEnd(w, r, se)
	case "title":
		s.handleTitle(w, r, se)
	case "promote":
		s.handlePromote(w, r, se)
	case "adopt":
		s.handleAdopt(w, r, se)
	case "preview-root":
		s.handlePreviewRoot(w, r, se)
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

// terminalReportRe matches a payload made only of automatic terminal replies: focus
// in/out (CSI I / CSI O), cursor-position (CSI r;c R), device status (CSI n), device
// attributes (CSI ? … c / CSI > … c / CSI = … c), mode reports (CSI ?… ; … $y), kitty
// keyboard flags (CSI ? n u), colour-scheme (CSI ? 997 ; n n), OSC replies (ESC ] … BEL
// or ST) and DCS replies (ESC P … ST). Whole payload only: a key typed alongside a
// report still counts as input.
var terminalReportRe = regexp.MustCompile(`^(?:\x1b\[[IO]|\x1b\[\d+;\d+R|\x1b\[\d*n|\x1b\[[?>=][\d;]*c|\x1b\[\??\d+;\d+\$y|\x1b\[\?\d*u|\x1b\[\?997;\dn|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1bP[^\x1b]*\x1b\\)+$`)

func isTerminalReport(data []byte) bool {
	return len(data) > 0 && terminalReportRe.Match(data)
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
	// t-7c4f: an automatic terminal reply — focus in/out once the agent turned on focus
	// reporting (Claude Code does), a cursor-position or device-attributes answer — is the
	// terminal talking, not the human. It still reaches the agent (it asked), but opening
	// a waiting session must not clear needs-you, reset the idle timer, or look like the
	// human returning mid Save & End.
	if isTerminalReport(data) {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	se.mu.Lock()
	se.lastActivity = time.Now() // t-2e7e: input counts as activity too, not just output
	se.humanInputAt = se.lastActivity
	se.mu.Unlock()
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
	se.mu.Lock()
	se.cols, se.rows = body.Cols, body.Rows
	se.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleKill(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.killSession(se)
	w.WriteHeader(http.StatusNoContent)
}

// handleSaveAndEnd (t-2c9e) drives the daemon-side Save & End for an attached
// client: inject the save prompt, then end on the PTY marker, file-settle, or
// the fallback — so a full-screen TUI (pi) that never yields a clean marker
// line still ends promptly instead of waiting out the board's 90s fallback.
// Returns 202 immediately; the client ends on the "saved" SSE frame (or the
// stream closing on kill). Guarded by se.reaping so it can't double-run or race
// the idle reaper.
// ── t-f553: scratch title, promote to a ticket, adopt ────────────────────────

// cleanTitle drops control characters (so a title typed into the agent can never press
// Enter), trims, and caps it at 80 runes.
func cleanTitle(t string) string {
	t = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, t))
	if rs := []rune(t); len(rs) > 80 {
		t = strings.TrimSpace(string(rs[:80]))
	}
	return t
}

// handleTitle sets a scratch session's title (shown in /sessions and used by promote).
func (s *server) handleTitle(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isScratch(se.ticket) {
		http.Error(w, "only a scratch session has an editable title", http.StatusConflict)
		return
	}
	var body struct {
		Title string `json:"title"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	se.mu.Lock()
	se.title = cleanTitle(body.Title)
	se.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// promoteMarker is the line the daemon page watches for after a promote.
const promoteMarker = "CANON_TICKET:"

// promotePrompt asks the agent to create the ticket itself (the user reviews the
// `tkt create` command in the agent's own permission prompt) and to report its id.
func promotePrompt(title string, thenEnd bool) string {
	name := "a short title you choose"
	if title != "" {
		name = `the title "` + strings.ReplaceAll(title, `"`, `'`) + `"`
	}
	stop := "Don't start a sprint."
	if thenEnd {
		stop = "Don't start a sprint and don't continue working."
	}
	return "Turn this scratch session into a canon ticket now, without asking me anything: decide the details " +
		"yourself from this session so far and run tkt create with " + name +
		", -t feature, task or bug (whichever fits), -p 2, and -d with a short summary you write — not the transcript — " +
		"under the headings ## Problem, ## Findings, ## Changes so far and ## Open questions (write 'None yet' where " +
		"there's nothing). " + stop + " Then print the exact line " + promoteMarker + " <the new ticket id> on its own, and stop."
}

// handlePromote types the promote prompt into a scratch session — never into a pending
// prompt (needs-you or a Copilot menu), which the keystrokes would answer (t-f91a).
func (s *server) handlePromote(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isScratch(se.ticket) {
		http.Error(w, "only a scratch session can be promoted", http.StatusConflict)
		return
	}
	if se.isExited() {
		http.Error(w, "session has exited", http.StatusGone)
		return
	}
	var body struct {
		ThenEnd bool `json:"then_end"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body)
	se.mu.Lock()
	waiting := se.status == "needs-you" || se.menuPendingLocked()
	title := se.title
	se.mu.Unlock()
	if waiting {
		http.Error(w, "The agent is waiting on you — answer its prompt first, then promote.", http.StatusConflict)
		return
	}
	if _, err := se.pty.Write([]byte(promotePrompt(title, body.ThenEnd))); err != nil {
		http.Error(w, "write failed", http.StatusInternalServerError)
		return
	}
	time.Sleep(300 * time.Millisecond) // text, then a separate Enter — as saveAndEnd does
	if _, err := se.pty.Write([]byte("\r")); err != nil {
		http.Error(w, "write failed", http.StatusInternalServerError)
		return
	}
	se.debugf("promote prompt sent then_end=%v", body.ThenEnd)
	w.WriteHeader(http.StatusNoContent)
}

// handleAdopt hands a scratch session to the ticket its agent just created: the ticket
// gets the conversation id, agent and directory (and a copy of its own folder in a scratch
// worktree, which is no longer cleaned up), then the scratch session ends. The ticket id
// comes from the agent's output, so it is validated and must exist in this project.
func (s *server) handleAdopt(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isScratch(se.ticket) {
		http.Error(w, "only a scratch session can be adopted", http.StatusConflict)
		return
	}
	var body struct {
		Ticket string `json:"ticket"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil || !ticketRe.MatchString(body.Ticket) {
		http.Error(w, "invalid ticket id", http.StatusBadRequest)
		return
	}
	root := se.projectRoot
	ticketDir := filepath.Join(s.ticketsDirIn(root), body.Ticket)
	if fi, err := os.Stat(filepath.Join(ticketDir, "ticket.md")); err != nil || !fi.Mode().IsRegular() {
		http.Error(w, "ticket not found in project", http.StatusBadRequest)
		return
	}
	// Only a fresh ticket: an id the agent got wrong must not take over another ticket's
	// conversation or directory (Save-then-end adopts without asking).
	if _, err := os.Stat(filepath.Join(ticketDir, ".cockpit-session-id")); err == nil || s.ticketStatusIn(root, body.Ticket) != "open" {
		http.Error(w, "ticket "+body.Ticket+" is not a new ticket — adopt only the one just created", http.StatusConflict)
		return
	}
	scratchDir := s.sessionStateDir(root, se.ticket)
	for _, f := range []string{".cockpit-session-id", ".cockpit-copilot-session-id", ".cockpit-agent"} {
		if b, err := os.ReadFile(filepath.Join(scratchDir, f)); err == nil {
			_ = os.WriteFile(filepath.Join(ticketDir, f), b, 0o600)
		}
	}
	se.mu.Lock()
	cwd := se.cwd
	se.scratchWT = nil // the worktree now belongs to the ticket — never auto-removed
	se.mu.Unlock()
	_ = os.WriteFile(filepath.Join(ticketDir, ".cockpit-cwd"), []byte(cwd+"\n"), 0o600)
	_ = os.WriteFile(filepath.Join(ticketDir, ".cockpit-adopted"), []byte("from "+se.ticket+"\n"), 0o600)
	if !pathsEqual(cwd, root) {
		if err := copyTicketDir(ticketDir, filepath.Join(cwd, ".tickets", body.Ticket)); err != nil {
			se.debugf("adopt: copying %s into the worktree failed: %v", body.Ticket, err)
		}
	}
	se.debugf("adopted by %s — ending the scratch session", body.Ticket)
	s.killSession(se)
	writeJSON(w, map[string]string{"ticket": body.Ticket, "cwd": cwd})
}

// copyTicketDir copies a ticket folder's regular files and subfolders (never symlinks)
// into dst, so a ticket adopted in a scratch worktree is visible there (t-e5ff).
func copyTicketDir(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(target, 0o755)
		case d.Type().IsRegular():
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			return os.WriteFile(target, b, 0o644)
		}
		return nil // symlinks and other types are skipped
	})
}

// adoptedTicket reports whether a ticket took over a scratch session (t-f553): its saved
// conversation id and directory are reused even before the sprint marks it in_progress.
func (s *server) adoptedTicket(root, ticket string) bool {
	if !ticketRe.MatchString(ticket) {
		return false
	}
	_, err := os.Stat(filepath.Join(s.ticketsDirIn(root), ticket, ".cockpit-adopted"))
	return err == nil
}

func (s *server) handleSaveAndEnd(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if se.isExited() {
		http.Error(w, "session has exited", http.StatusGone)
		return
	}
	// t-47f1: a scratch session has no ticket to save state into — End it instead.
	if isScratch(se.ticket) {
		http.Error(w, "Scratch sessions have no save step — use End.", http.StatusConflict)
		return
	}
	// t-f91a: never type into a pending copilot menu — that answers it.
	if se.copilotHasPendingMenu() {
		se.debugf("save-end refused: copilot menu pending")
		http.Error(w, menuRefusal, http.StatusConflict)
		return
	}
	se.mu.Lock()
	already := se.reaping
	if !already {
		se.reaping = true
	}
	se.mu.Unlock()
	if !already {
		go s.saveAndEnd(se)
	}
	w.WriteHeader(http.StatusAccepted)
}

// killSession is the shared teardown handleKill and the idle reaper
// (t-2e7e) both use — no orphaned children, hook dir removed, session
// entry dropped. Safe to call on an already-exited/already-killed session:
// killProcess on a dead pid just errors silently, markDone is a sync.Once,
// and deleting an already-absent map key is a no-op.
func (s *server) killSession(se *session) {
	se.mu.Lock()
	if se.killed {
		se.mu.Unlock()
		return // already torn down by a concurrent caller (e.g. handleKill racing the idle reaper)
	}
	se.killed = true
	se.mu.Unlock()
	se.debugf("kill invoked")
	killProcess(se.cmd) // platform-specific: no orphaned children
	se.closePty()
	se.markDone()
	se.cleanup()
	s.mu.Lock()
	delete(s.sessions, se.sid)
	s.mu.Unlock()
}

// handleShutdown terminates the daemon process so the board can replace a
// version-drifted (stale) build with a freshly-launched one (t-74d6). It is
// boot-token gated (same credential as /session/*) and refuses (409) while any
// live session is attached, unless ?force=1 is passed — the cockpit page only
// sends force behind an explicit user confirm. This is an explicit, authorized,
// gated teardown; it does NOT weaken the detached-survival model (a daemon
// still outlives the board/browser on its own).
func (s *server) handleShutdown(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.cfg.token == "" || !secureEqual(bearer(r), s.cfg.token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	force := r.URL.Query().Get("force") == "1"
	// Snapshot the live (not-yet-exited) sessions.
	s.mu.Lock()
	live := make([]*session, 0, len(s.sessions))
	for _, se := range s.sessions {
		se.mu.Lock()
		exited := se.exited
		se.mu.Unlock()
		if !exited {
			live = append(live, se)
		}
	}
	s.mu.Unlock()
	if len(live) > 0 && !force {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": false, "error": "active session", "sessions": len(live),
		})
		return
	}
	for _, se := range live {
		s.killSession(se) // force path only (live is empty otherwise)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "sessions_ended": len(live)})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	// Exit after the response drains. os.Exit skips no critical cleanup here (the
	// board clears daemon.json on relaunch; sessions were killed above). The small
	// delay avoids the exit racing the HTTP write (pre-mortem: board would see a
	// connection error instead of 200). Indirected through shutdownExit so tests
	// can assert the path without terminating the test process.
	go shutdownExit()
}

// shutdownExit performs the actual process exit for handleShutdown. It is a
// package var so tests can replace it (os.Exit would kill the test runner).
var shutdownExit = func() {
	time.Sleep(150 * time.Millisecond)
	os.Exit(0)
}

// shutdownAllSessions kills every session (killSession reaps each child process
// group via kill_unix/kill_windows) and clears daemon.json — the graceful
// teardown the SIGTERM/SIGINT handler runs (t-44d9) so a board force-restart
// (pid SIGTERM) never orphans an agent, mirroring handleShutdown's force path.
func (s *server) shutdownAllSessions() {
	s.mu.Lock()
	sessions := make([]*session, 0, len(s.sessions))
	for _, se := range s.sessions {
		sessions = append(sessions, se)
	}
	s.mu.Unlock()
	for _, se := range sessions {
		s.killSession(se)
	}
	os.Remove(filepath.Join(s.cfg.stateDir, "daemon.json"))
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
			se.lastActivity = time.Now() // t-2e7e: real output resets the idle clock
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
	bufLen := len(se.buf)
	se.mu.Unlock()
	se.debugf("exit killed=%v buf_len=%d", killed, bufLen)
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

func (se *session) closePty() { se.closeOnce.Do(func() { se.pty.Close() }) }

// exitDrainGrace is how long waitExit lets readLoop drain after the child exits
// before closing the PTY itself.
const exitDrainGrace = 2 * time.Second

// waitExit (t-b999) waits for the agent process, then makes sure readLoop sees
// the exit. On Unix the master read already fails once the child exits. On
// Windows, ConPTY's output pipe stays open until the pseudoconsole is closed
// (go-pty's conPty.Read is a plain pipe read), so readLoop would block forever
// and the session would stay "running". Waiting for done first keeps output the
// child wrote just before exiting; the grace bounds the Windows case.
func (se *session) waitExit(wait func() error, grace time.Duration) {
	code, msg := exitStatus(wait())
	// t-75cb: the process's own status, which the readLoop `exit` line (killed/buf_len) can't give.
	se.debugf("wait returned exit_code=%d wait_err=%q", code, msg)
	select {
	case <-se.done:
	case <-time.After(grace):
		se.debugf("child exited but the pty read is still open after %s — closing it", grace)
	}
	se.closePty()
}

// exitStatus splits a Wait() error into an exit code and a message (t-75cb): nil is a
// clean 0; an *exec.ExitError carries the process's code (-1 when it died on a signal);
// any other error is -1 with its text.
func exitStatus(err error) (int, string) {
	if err == nil {
		return 0, ""
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode(), err.Error()
	}
	return -1, err.Error()
}

// cleanup removes the daemon-owned --settings dir. Called on kill and on natural
// exit, so a long-lived daemon doesn't accumulate hook dirs. t-e162: it also removes a
// scratch session's daemon-created worktree when nothing was done in it (once).
func (se *session) cleanup() {
	if se.hookDir != "" {
		os.RemoveAll(se.hookDir)
	}
	se.mu.Lock()
	wt := se.scratchWT
	se.scratchWT = nil
	se.mu.Unlock()
	if wt != nil {
		wt.remove(se.projectRoot, se.debugf)
	}
}

// debugEnabled (t-ffb9) gates verbose session-lifecycle logging, toggled via
// POST /admin/debug and reflected in GET /version's debug_enabled field.
// Resets to false on every process start — no persistence by design (a
// forgotten-on toggle should never survive an unrelated daemon restart).
var debugEnabled atomic.Bool

// debugLogMu serializes debugf's read-modify-write of .cockpit-debug.log (one lock for all
// sessions: the log is diagnostics, never a hot path).
var debugLogMu sync.Mutex

// debugLogMaxBytes caps .cockpit-debug.log at a fixed size — lifecycle events
// are small and bounded per entry, but an unattended long-running session
// with many spawn/kill cycles could still accumulate indefinitely with no
// rotation otherwise (t-ffb9 pre-mortem). Mirrors se.max's own scrollback
// truncation: keep only the tail once the cap is exceeded.
const debugLogMaxBytes = 512 * 1024

// debugf appends a timestamped lifecycle-event line to this session's
// .cockpit-debug.log when debugEnabled is on; a silent no-op otherwise, so
// every call site can call it unconditionally (t-ffb9) — the same shape as a
// logging library's Debug() call. Lifecycle events only (spawn/kill/exit/
// resume outcomes) — deliberately never raw PTY buffer content, per the
// ticket's Grill decision. Best-effort: a write failure is silently
// swallowed, matching logSessionStart's existing non-fatal file-write
// convention — diagnostics must never block or crash a real session.
func (se *session) debugf(format string, a ...any) {
	if !debugEnabled.Load() {
		return
	}
	// t-75cb: the append below is read-modify-write, and a fast exit fires the spawn, wait and
	// exit lines from different goroutines within microseconds — unserialized, the last writer's
	// snapshot silently dropped the others' lines.
	debugLogMu.Lock()
	defer debugLogMu.Unlock()
	dir := filepath.Join(se.ticketsDir, se.ticket)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	path := filepath.Join(dir, ".cockpit-debug.log")
	line := fmt.Sprintf("%s "+format+"\n", append([]any{time.Now().Format(time.RFC3339Nano)}, a...)...)
	existing, _ := os.ReadFile(path)
	_ = os.WriteFile(path, appendDebugLogLine(existing, []byte(line), debugLogMaxBytes), 0o600)
}

// appendDebugLogLine is debugf's pure size-capping logic, split out so it's
// unit-testable without writing debugLogMaxBytes (512KB) of real lifecycle
// events through a spawned session. Keeps only the tail once the combined
// size would exceed maxBytes — mirrors se.max's own scrollback truncation.
func appendDebugLogLine(existing, line []byte, maxBytes int) []byte {
	combined := append(existing, line...)
	if len(combined) > maxBytes {
		combined = combined[len(combined)-maxBytes:]
	}
	return combined
}

func (se *session) isExited() bool {
	se.mu.Lock()
	defer se.mu.Unlock()
	return se.exited
}

// ── idle reaping (t-2e7e) ────────────────────────────────────────────────
//
// Verified against nebula's actual README, not assumed: it does not tie
// cleanup to client disconnect at all ("Quit the UI, close the laptop lid,
// come back tomorrow — the agents never stopped"). What it reaps is purely
// idle-based ("idle PTYs... are killed after session_idle_timeout — pinned
// agents, working agents, ones waiting on you... are all spared"). This
// mirrors that: idle-ness is a property of the PTY's own activity, not of
// whether a browser is attached, so it works even if the tab was closed
// with zero JS ever running (the exact gap t-f6b6's client-side flow can't
// close on its own).

const cockpitSaveMarker = "COCKPIT_STATE_SAVED"

// startIdleReaper runs for the server's whole lifetime. Each tick, any
// session that is not needs-you, not already exited, and has produced zero
// new PTY output (and received no input) for cfg.idleTimeout gets ended via
// saveAndEndIdle.
func (s *server) startIdleReaper() {
	go func() {
		ticker := time.NewTicker(s.cfg.idleCheckInterval)
		defer ticker.Stop()
		for range ticker.C {
			s.reapIdleSessions()
		}
	}()
}

// idleTimeoutFor picks the idle-reap timeout tier for a session's cwd
// (t-cd06): nebula's own 5m default assumes the session runs in a
// disposable worktree, safe to auto-kill without a second thought. The main
// checkout has no such disposability, so it keeps a longer but still-bounded
// safety net (idleTimeoutMain) rather than running unreaped forever — a
// deliberate compromise, not an exemption, so cockpit never regresses to
// leaking indefinitely-idle agent processes on the main checkout.
// t-824e: projectRoot is the session's own project (t-391a: one daemon serves every project), not
// the daemon's launch root — comparing with the launch root gave another project's main checkout
// the worktree timeout. "" falls back to the launch root, as before.
func (s *server) idleTimeoutFor(projectRoot, cwd string) time.Duration {
	if projectRoot == "" {
		projectRoot = s.cfg.projectRoot
	}
	resolvedRoot, err := filepath.EvalSymlinks(projectRoot)
	if err != nil {
		resolvedRoot = projectRoot
	}
	if cwd == "" || pathsEqual(cwd, resolvedRoot) || pathsEqual(cwd, projectRoot) {
		return s.cfg.idleTimeoutMain
	}
	return s.cfg.idleTimeout
}

func (s *server) reapIdleSessions() {
	s.mu.Lock()
	candidates := make([]*session, 0, len(s.sessions))
	for _, se := range s.sessions {
		candidates = append(candidates, se)
	}
	s.mu.Unlock()
	for _, se := range candidates {
		se.mu.Lock()
		idleFor, idleLimit := time.Since(se.lastActivity), s.idleTimeoutFor(se.projectRoot, se.cwd)
		idle := idleFor > idleLimit
		blocked := se.status == "needs-you"
		exited := se.exited
		alreadyReaping := se.reaping
		// t-f91a: a copilot session on a selection menu is waiting on a human, not
		// abandoned — never write into it (that would answer it), never reap it.
		if idle && !blocked && !exited && !alreadyReaping && se.menuPendingLocked() {
			blocked = true
			se.debugf("idle reap skipped: copilot menu pending")
		}
		if idle && !blocked && !exited && !alreadyReaping {
			se.reaping = true
		}
		se.mu.Unlock()
		if !idle || blocked || exited || alreadyReaping {
			continue
		}
		if isScratch(se.ticket) {
			se.debugf("idle reap: scratch inactive for %s (timeout %s)", idleFor.Round(time.Second), idleLimit)
			go s.endIdleScratch(se)
			continue
		}
		se.debugf("idle reap: inactive for %s (timeout %s) — starting save-and-end", idleFor.Round(time.Second), idleLimit)
		go s.saveAndEnd(se)
	}
}

// endIdleScratch ends an idle scratch session (t-47f1). A scratch session has no ticket
// to save state into, so there is no save prompt: a clean checkout is simply ended; one
// with uncommitted changes is kept (never discarded or committed) until t-86fe's end guard.
func (s *server) endIdleScratch(se *session) {
	if dirty, err := checkoutDirty(se.cwd); err != nil || dirty {
		se.mu.Lock()
		se.reaping = false
		se.mu.Unlock()
		se.debugf("idle reap skipped: scratch checkout has uncommitted changes (or git failed: %v) — kept until t-86fe", err)
		return
	}
	se.debugf("idle reap: scratch checkout clean — ending")
	s.killSession(se)
}

// checkoutDirty reports whether a git working tree has uncommitted changes (t-47f1).
func checkoutDirty(dir string) (bool, error) {
	out, err := exec.Command("git", "-C", dir, "status", "--porcelain").Output()
	if err != nil {
		return false, err
	}
	return len(strings.TrimSpace(string(out))) > 0, nil
}

// saveAndEndIdle mirrors t-f6b6's client-side Save & End, moved server-side
// so it works with zero browser attached: the daemon owns the PTY directly,
// so no HTTP round-trip to itself is needed. Writes the save prompt, polls
// its own already-buffered output for the exact marker line, then kills. A
// bounded fallback force-kills if the marker never appears — same shape as
// the client-side version's own fallback, so an idle-but-unresponsive
// session can't block the reaper forever.
// saveAndEnd mirrors t-f6b6's client-side Save & End, moved server-side so it
// works with zero browser attached: the daemon owns the PTY directly, so no
// HTTP round-trip to itself is needed. Shared by the idle reaper and the
// interactive POST /session/<id>/save-and-end (t-2c9e). Writes the save prompt,
// then ends on the FIRST of: the PTY marker (claude fast path), file-settle (a
// watched state file changed then quiesced — agent-agnostic, covers pi), or the
// bounded fallback. A real human POST /input aborts. The caller sets se.reaping
// before launching this (guards against a second concurrent run).
func (s *server) saveAndEnd(se *session) {
	prompt := "Please save your current state now. If anything changed since the last HANDOFF.md " +
		"entry, append a brief status (where things stand and anything unresolved) — otherwise skip " +
		"the write; a repeated 'nothing changed' entry isn't worth logging. Don't re-read plan.md or " +
		"acceptance.md unless something is unresolved that they don't already capture — only then " +
		"update them. Then print the exact line " + cockpitSaveMarker + " on its own, and stop."
	// t-f91a: the callers check too, but a menu can appear between their check and
	// this goroutine starting. Abort rather than write into it. (A caller that already
	// answered 202 then waits out its own fallback; the window is that narrow.)
	if se.copilotHasPendingMenu() {
		se.debugf("save-end aborted: copilot menu pending")
		se.mu.Lock()
		se.reaping = false
		se.mu.Unlock()
		return
	}
	se.mu.Lock()
	sentAt := len(se.buf)            // only output written AFTER the prompt counts — buf may hold an
	humanBaseline := se.humanInputAt // unrelated earlier line matching the marker verbatim (e.g. from a
	buf := se.buf                    // prior conversation about this very feature) that must never trigger a false kill.
	se.mu.Unlock()
	// t-acc5: an unauthenticated copilot session shows "not logged in" at SPAWN,
	// well before Save & End is ever clicked — it won't repeat that text just
	// because we write more keystrokes into its dead PTY, so t-af51's
	// sentAt-scoped poll-loop check (below) never sees it. Check a bounded
	// recent TAIL of the buffer as it stands right now, before even writing
	// the doomed prompt — not sentAt-scoped (the state predates this attempt),
	// and not the full buffer either (a healthy session that ran /login mid-
	// session and kept working would still have the old text far earlier in
	// scrollback; a small tail is generous for a genuinely-stuck session,
	// whose entire recent output IS just that one message, while real
	// subsequent work pushes a stale mention well outside it).
	if se.agent == "copilot" {
		tail := buf
		if len(tail) > copilotLoginTailWindow {
			tail = tail[len(tail)-copilotLoginTailWindow:]
		}
		if copilotNeedsLogin(tail) {
			s.killSession(se)
			return
		}
	}
	// t-2c9e: snapshot baseline stamps of the watched state files at prompt
	// injection — a change vs THIS baseline is what marks "the agent saved", so
	// an unrelated earlier edit never false-fires. File-settle makes detection
	// agent-agnostic (pi never emits a clean marker line the claude-tuned parser
	// survives); the PTY marker below stays as claude's fast path.
	watched := s.watchedSaveFiles(se)
	baseline := snapshotStamps(watched)
	prev := baseline
	lastChange := time.Now()
	sawChange := false
	// t-cd06: text and Enter must be two SEPARATE writes, not one write with
	// a trailing \r — live-reproduced: a single write landed as an unsubmitted
	// draft sitting in the composer (bracketed-paste-style handling swallows
	// an embedded \r), requiring a human to press Enter manually to unstick
	// it. cockpit.html's own client-triggered sendPrompt already does this
	// correctly (text, then a separate \r ~300ms later); this mirrors it.
	if _, err := se.pty.Write([]byte(prompt)); err != nil {
		s.killSession(se) // can't even write to it — nothing more to wait for
		return
	}
	time.Sleep(300 * time.Millisecond)
	if _, err := se.pty.Write([]byte("\r")); err != nil {
		s.killSession(se)
		return
	}
	// t-6291: verbose lifecycle log of how Save & End ended (metadata only).
	began := time.Now()
	se.debugf("save-end prompt sent agent=%s scan_from=%d", se.agent, sentAt)
	ended := func(by string) {
		se.debugf("save-end ended by=%s after=%s", by, time.Since(began).Round(time.Millisecond))
	}
	deadline := time.NewTimer(s.cfg.saveFallback)
	defer deadline.Stop()
	poll := time.NewTicker(500 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-deadline.C:
			if debugEnabled.Load() {
				se.mu.Lock()
				pre, tail, cols, rows := se.outputSinceLocked(sentAt)
				se.mu.Unlock()
				se.debugf("save-end ended by=fallback after=%s size=%dx%d marker_substring=%v framing=%q screen=%q",
					time.Since(began).Round(time.Millisecond), cols, rows, strings.Contains(string(tail), cockpitSaveMarker),
					markerFraming(tail, cockpitSaveMarker), maskedRows(changedRows(pre, tail, cols, rows), cockpitSaveMarker))
			}
			s.killSession(se)
			return
		case <-poll.C:
			se.mu.Lock()
			pre, newOutput, cols, rows := se.outputSinceLocked(sentAt)
			// t-af51: an unauthenticated copilot session idles forever at its own
			// prompt — never exits, never touches a watched file, never emits the
			// marker — so without this it always waits out the full saveFallback.
			// Scoped to copilot only: never risk a false-positive short-circuit on
			// claude/pi output that happens to contain similar words.
			stuckUnauthenticated := se.agent == "copilot" && copilotNeedsLogin(newOutput)
			exited := se.exited
			// A real human POST /input during the wait (not PTY output/echo,
			// which could just be the agent talking to itself) means someone
			// came back — abort the kill and let the idle clock (bumped by
			// that same input) decide again later, per plan.md's "any real
			// activity resets it" guarantee.
			humanReturned := se.humanInputAt.After(humanBaseline)
			if humanReturned {
				se.reaping = false
			}
			se.mu.Unlock()
			found := markerOnScreen(pre, newOutput, cockpitSaveMarker, cols, rows)
			if exited {
				ended("agent-exited")
				return // already gone naturally — nothing left to kill
			}
			if humanReturned {
				ended("human-returned")
				return
			}
			if stuckUnauthenticated {
				ended("copilot-not-logged-in")
				s.killSession(se) // never salvageable — don't wait out saveFallback
				return
			}
			if found {
				ended("marker")
				s.endSaved(se) // claude fast path: the clean sentinel line
				return
			}
			// t-2c9e: file-settle — a watched state file changed vs baseline,
			// then writes quiesced for saveQuiesce (mtime-bump != save-complete,
			// so the debounce avoids killing mid-multi-file-write). Agent-agnostic:
			// covers pi, whose TUI never yields a clean marker line.
			cur := snapshotStamps(watched)
			if !stampsEqual(cur, prev) {
				lastChange = time.Now()
				prev = cur
			}
			if !stampsEqual(cur, baseline) {
				sawChange = true
			}
			if sawChange && time.Since(lastChange) >= s.cfg.saveQuiesce {
				ended("file-settle")
				s.endSaved(se)
				return
			}
		}
	}
}

// outputSinceLocked splits the scrollback at the save prompt (only output AFTER it
// counts) and returns the terminal size for replaying it. The slices are copies,
// so the screen replay runs without se.mu. Caller holds se.mu.
func (se *session) outputSinceLocked(sentAt int) (pre, post []byte, cols, rows int) {
	buf := se.buf
	if sentAt > len(buf) { // buf was trimmed to max size since sentAt — no valid offset, scan it all
		sentAt = 0
	}
	return append([]byte(nil), buf[:sentAt]...), append([]byte(nil), buf[sentAt:]...), se.cols, se.rows
}

// maskedRows renders screen rows for the fallback log with every letter and
// digit masked (the marker itself kept) — t-ffb9: never raw PTY content.
func maskedRows(rows []string, marker string) string {
	var b strings.Builder
	for i, row := range rows {
		if i > 0 {
			b.WriteString(" | ")
		}
		maskInto(&b, row, marker)
	}
	return b.String()
}

// t-2c9e: file-settle detection of a completed Save & End, agent-agnostic.

// fileStamp captures the mtime AND size of a watched file so a same-tick write
// (coarse mtime resolution) is still seen as a change via the size delta. Zero
// value = the file is absent (its later appearance is itself a change).
type fileStamp struct{ mtime, size int64 }

// watchedSaveFiles is the worktree-aware set whose change marks a completed save
// (t-2c9e): HANDOFF.md at the session cwd root, plus the ticket's plan/acceptance
// under .tickets/<id>/ (both folder and flat layouts — a nonexistent variant is
// simply never observed changing). Reads the tree the session runs in (se.cwd),
// not the daemon's own ticketsDir, so a worktree session is watched correctly.
func (s *server) watchedSaveFiles(se *session) []string {
	root := se.cwd
	if root == "" {
		root = s.cfg.projectRoot
	}
	td := filepath.Join(root, ".tickets")
	return []string{
		filepath.Join(root, "HANDOFF.md"),
		filepath.Join(td, se.ticket, "plan.md"),
		filepath.Join(td, se.ticket, "acceptance.md"),
		filepath.Join(td, se.ticket+"-plan.md"),
		filepath.Join(td, se.ticket+"-acceptance.md"),
	}
}

func snapshotStamps(paths []string) map[string]fileStamp {
	m := make(map[string]fileStamp, len(paths))
	for _, p := range paths {
		if fi, err := os.Stat(p); err == nil {
			m[p] = fileStamp{mtime: fi.ModTime().UnixNano(), size: fi.Size()}
		} else {
			m[p] = fileStamp{}
		}
	}
	return m
}

func stampsEqual(a, b map[string]fileStamp) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// endSaved broadcasts a "saved" SSE frame so an attached client ends promptly,
// then tears the session down. Best-effort: a brief pause lets the stream flush
// the frame before killSession closes the PTY and drops subscribers.
func (s *server) endSaved(se *session) {
	se.mu.Lock()
	se.broadcastLocked(frame{event: "saved"})
	se.mu.Unlock()
	time.Sleep(100 * time.Millisecond)
	s.killSession(se)
}

var ansiCSIRe = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]`)

// The Save & End marker matches a whole trimmed line exactly — a coincidental
// substring mid-sentence (the agent describing what it's about to do, incl. the
// echoed save prompt) must never count, same discipline as t-f6b6's client-side
// matcher. t-2lv7: split on "\r" OR "\n" — Claude Code's TUI positions every row
// with a bare "\r" + cursor-move escape and NEVER a "\n", so splitting on "\n"
// alone left the whole buffer as one line and the marker was never isolated,
// stalling Save & End until the fallback timeout ("saves forever"). Mirrors the
// cockpit.html fix.
//
// t-6291: agents decorate a one-line reply — Copilot prints "● COCKPIT_STATE_SAVED",
// Claude a leading "⏺", some wrap it in markdown — so strip the SAME leading and
// trailing chrome the daemon's own page strips before its identical compare
// (web/cockpit.html: /^[\s*_`>#•●⏺○◦▸▹‣·-]+/ and /[\s*_`]+$/), then still
// require the WHOLE line to be the marker.
const markerLeadChrome = " \t*_`>#•●⏺○◦▸▹‣·-"
const markerTrailChrome = " \t*_`"

// t-6291: on Windows, ConPTY is a screen DIFFER, not a text stream: it redraws a
// row by moving the cursor (CUP/VPA/up/down) and writes only the cells that
// changed since its last frame — so a reply drawn over the old spinner row can
// arrive as "●" + a cursor jump + the tail of the word, and "COCKPIT_STATE_SAVED"
// never occurs contiguously in the bytes (live-reproduced: the marker was on
// screen while the only copy in the stream was the echoed prompt). So the marker
// is matched on a rendered screen (vtScreen), not on the raw bytes: bytes before
// the prompt are replayed untracked, bytes after it mark every row whose cells
// they CHANGE, and only a changed row that reads exactly the marker counts.
//
// markerOnScreen replays pre (untracked) then post onto a cols×rows screen
// (0 = unknown: wrap at vtMaxCols, scroll at vtMaxRows) and reports whether
// a row changed by post is, after chrome trimming, exactly marker. Trailing
// box-drawing and block glyphs also go: Copilot draws its scrollbar ("┃") in
// the last column of every row (VM round 3). Leading ones stay — Copilot's
// "│" prefixes its thinking block, which must never end a save.
func markerOnScreen(pre, post []byte, marker string, cols, rows int) bool {
	for _, line := range changedRows(pre, post, cols, rows) {
		line = strings.TrimRightFunc(line, func(r rune) bool {
			return unicode.IsSpace(r) || strings.ContainsRune(markerTrailChrome, r) || (r >= 0x2500 && r <= 0x259f)
		})
		if strings.TrimLeft(strings.TrimSpace(line), markerLeadChrome) == marker {
			return true
		}
	}
	return false
}

func changedRows(pre, post []byte, cols, rows int) []string {
	v := newVTScreen(cols, rows)
	v.feed(pre)
	v.tracking = true
	v.feed(post)
	var out []string
	for i, row := range v.grid {
		if v.dirty[i] {
			out = append(out, v.rowText(row))
		}
	}
	return out
}

// vtScreen is the minimal VT/xterm model markerOnScreen needs: printable cells,
// CR/LF/BS/TAB, cursor moves, erases, insert/delete, scroll regions and scroll,
// REP, save/restore cursor and the alternate screen (treated as a clear).
// Colors and modes are ignored. It only has to place text where a terminal
// would — anything it gets wrong just misses the marker, and Save & End falls
// back as before.
type vtScreen struct {
	cols, rows     int // rows 0 = unknown (scrolls at vtMaxRows)
	grid           [][]rune
	dirty          []bool
	r, c           int
	savedR, savedC int
	top, bottom    int // scroll region, inclusive; bottom -1 = last row
	pendingWrap    bool
	last           rune
	tracking       bool
}

const vtWideTail = rune(-1) // the right half of a double-width cell

// vtMaxCols/vtMaxRows bound the screen (a real terminal is far smaller) and
// every repeat count. The agent controls these bytes: without them, one
// "ESC[999999999;1H" or "ESC[999999999@" would allocate or loop without bound
// inside the daemon, and a scroll costs O(rows) per line fed.
const vtMaxCols, vtMaxRows = 1024, 512

func newVTScreen(cols, rows int) *vtScreen {
	if cols <= 0 || cols > vtMaxCols {
		cols = vtMaxCols // unknown width: wrap at the cap so a row stays bounded
	}
	v := &vtScreen{cols: cols, rows: min(rows, vtMaxRows), bottom: -1}
	v.ensureRow(max(v.rows-1, 0))
	return v
}

func (v *vtScreen) ensureRow(r int) {
	for len(v.grid) <= r {
		v.grid = append(v.grid, nil)
		v.dirty = append(v.dirty, false)
	}
}

func (v *vtScreen) bottomRow() int {
	if v.bottom >= 0 {
		return v.bottom
	}
	if v.rows > 0 {
		return v.rows - 1
	}
	return vtMaxRows - 1 // unknown height: the cap is the bottom
}

func (v *vtScreen) clampCursor() {
	v.r, v.c = min(max(v.r, 0), vtMaxRows-1), min(max(v.c, 0), vtMaxCols-1)
	if v.rows > 0 {
		v.r = min(v.r, v.rows-1)
	}
	if v.cols > 0 {
		v.c = min(v.c, v.cols-1)
	}
	v.pendingWrap = false
}

func (v *vtScreen) set(r, c int, ch rune) {
	v.ensureRow(r)
	row := v.grid[r]
	for len(row) <= c {
		row = append(row, ' ')
	}
	if row[c] != ch && v.tracking {
		v.dirty[r] = true
	}
	row[c] = ch
	v.grid[r] = row
}

func (v *vtScreen) put(ch rune) {
	w := 1
	if vtWide(ch) {
		w = 2
	}
	if v.pendingWrap || (v.cols > 0 && v.c+w > v.cols) {
		v.c = 0
		v.lineFeed()
	}
	v.set(v.r, v.c, ch)
	if w == 2 {
		v.set(v.r, v.c+1, vtWideTail)
	}
	v.c += w
	if v.cols > 0 && v.c >= v.cols {
		v.c, v.pendingWrap = v.cols-1, true
	}
	v.last = ch
}

func (v *vtScreen) lineFeed() {
	v.pendingWrap = false
	if v.r == v.bottomRow() {
		v.scrollUp(1)
		return
	}
	last := vtMaxRows - 1
	if v.rows > 0 {
		last = v.rows - 1
	}
	v.r = min(v.r+1, last) // below a scroll region: move down, never past the screen
	v.ensureRow(v.r)
}

// scrollUp/scrollDown shift rows (and their dirty flags) within the scroll region.
func (v *vtScreen) scrollUp(n int) {
	bot := v.bottomRow()
	v.ensureRow(bot)
	n = min(n, bot-v.top+1)
	copy(v.grid[v.top:bot+1-n], v.grid[v.top+n:bot+1])
	copy(v.dirty[v.top:bot+1-n], v.dirty[v.top+n:bot+1])
	for r := bot + 1 - n; r <= bot; r++ {
		v.grid[r], v.dirty[r] = nil, v.tracking
	}
}

func (v *vtScreen) scrollDown(n int) {
	bot := v.bottomRow()
	v.ensureRow(bot)
	n = min(n, bot-v.top+1)
	copy(v.grid[v.top+n:bot+1], v.grid[v.top:bot+1-n])
	copy(v.dirty[v.top+n:bot+1], v.dirty[v.top:bot+1-n])
	for r := v.top; r < v.top+n; r++ {
		v.grid[r], v.dirty[r] = nil, v.tracking
	}
}

func (v *vtScreen) eraseRow(r, from, to int) { // [from, to), to<0 = end of row
	v.ensureRow(r)
	if to < 0 || to > len(v.grid[r]) {
		to = len(v.grid[r])
	}
	for c := max(from, 0); c < to; c++ {
		v.set(r, c, ' ')
	}
}

func (v *vtScreen) eraseAll() {
	for r := range v.grid {
		v.eraseRow(r, 0, -1)
	}
}

func (v *vtScreen) rowText(row []rune) string {
	var b strings.Builder
	for _, ch := range row {
		if ch != vtWideTail {
			b.WriteRune(ch)
		}
	}
	return strings.TrimRight(b.String(), " ")
}

func (v *vtScreen) feed(buf []byte) {
	for i := 0; i < len(buf); {
		ch, size := utf8.DecodeRune(buf[i:])
		if ch != 0x1b {
			i += size
			switch {
			case ch == '\r':
				v.c, v.pendingWrap = 0, false
			case ch == '\n' || ch == '\v' || ch == '\f':
				v.lineFeed()
			case ch == '\b':
				v.c, v.pendingWrap = max(v.c-1, 0), false
			case ch == '\t':
				v.c = (v.c/8 + 1) * 8
				v.clampCursor()
			case ch < 0x20 || ch == 0x7f || ch == utf8.RuneError && size == 1:
			case unicode.Is(unicode.Mn, ch) || unicode.Is(unicode.Me, ch) || ch == 0x200d || ch == 0xfe0f:
				// zero-width: combining marks, ZWJ, emoji presentation
			default:
				v.put(ch)
			}
			continue
		}
		i += v.escape(buf[i:])
	}
}

// escape applies the sequence at buf[0] (ESC) and returns its length.
func (v *vtScreen) escape(buf []byte) int {
	if len(buf) < 2 {
		return len(buf)
	}
	switch buf[1] {
	case '[':
		j := 2
		for j < len(buf) && (buf[j] < 0x40 || buf[j] > 0x7e) {
			j++
		}
		if j == len(buf) {
			return j
		}
		v.csi(string(buf[2:j]), buf[j])
		return j + 1
	case ']', 'P', '_', '^': // OSC/DCS/APC/PM: skip to BEL or ST
		for j := 2; j < len(buf); j++ {
			if buf[j] == 0x07 {
				return j + 1
			}
			if buf[j] == 0x1b && j+1 < len(buf) && buf[j+1] == '\\' {
				return j + 2
			}
		}
		return len(buf)
	case '(', ')', '*', '+', '#', '%':
		return min(3, len(buf))
	case '7':
		v.savedR, v.savedC = v.r, v.c
	case '8':
		v.r, v.c = v.savedR, v.savedC
		v.clampCursor()
	case 'D':
		v.lineFeed()
	case 'E':
		v.c = 0
		v.lineFeed()
	case 'M':
		if v.r == v.top {
			v.scrollDown(1)
		} else {
			v.r = max(v.r-1, 0)
		}
	case 'c':
		v.eraseAll()
		v.r, v.c, v.top, v.bottom = 0, 0, 0, -1
	}
	return 2
}

func (v *vtScreen) csi(params string, final byte) {
	private := strings.HasPrefix(params, "?") || strings.HasPrefix(params, ">") || strings.HasPrefix(params, "=")
	params = strings.TrimLeft(params, "?>=")
	var ps []int
	for _, f := range strings.Split(strings.TrimRight(params, " !\"#$%&'()*+,-./"), ";") {
		n, _ := strconv.Atoi(f)
		ps = append(ps, n)
	}
	arg := func(i, def int) int {
		if i < len(ps) && ps[i] > 0 {
			return min(ps[i], vtMaxCols)
		}
		return def
	}
	if private {
		if final == 'h' || final == 'l' {
			for _, p := range ps {
				if p == 1049 || p == 1047 || p == 47 {
					v.eraseAll() // alternate screen in or out: start from a blank screen
				}
			}
		}
		return
	}
	switch final {
	case 'H', 'f':
		v.r, v.c = arg(0, 1)-1, arg(1, 1)-1
	case 'A':
		v.r -= arg(0, 1)
	case 'B', 'e':
		v.r += arg(0, 1)
	case 'C', 'a':
		v.c += arg(0, 1)
	case 'D':
		v.c -= arg(0, 1)
	case 'E':
		v.r, v.c = v.r+arg(0, 1), 0
	case 'F':
		v.r, v.c = v.r-arg(0, 1), 0
	case 'G', '`':
		v.c = arg(0, 1) - 1
	case 'd':
		v.r = arg(0, 1) - 1
	case 'K':
		switch arg(0, 0) {
		case 0:
			v.eraseRow(v.r, v.c, -1)
		case 1:
			v.eraseRow(v.r, 0, v.c+1)
		case 2:
			v.eraseRow(v.r, 0, -1)
		}
	case 'J':
		switch arg(0, 0) {
		case 0:
			v.eraseRow(v.r, v.c, -1)
			for r := v.r + 1; r < len(v.grid); r++ {
				v.eraseRow(r, 0, -1)
			}
		case 1:
			for r := 0; r < v.r; r++ {
				v.eraseRow(r, 0, -1)
			}
			v.eraseRow(v.r, 0, v.c+1)
		default:
			v.eraseAll()
		}
	case 'X':
		v.eraseRow(v.r, v.c, v.c+arg(0, 1))
	case 'P', '@':
		v.ensureRow(v.r)
		row := v.grid[v.r]
		if v.c < len(row) {
			n := arg(0, 1)
			var shifted []rune
			if final == 'P' {
				shifted = append(append([]rune(nil), row[:v.c]...), row[min(v.c+n, len(row)):]...)
			} else {
				shifted = append(append(append([]rune(nil), row[:v.c]...), []rune(strings.Repeat(" ", n))...), row[v.c:]...)
				if v.cols > 0 && len(shifted) > v.cols {
					shifted = shifted[:v.cols]
				}
			}
			for len(shifted) < len(row) {
				shifted = append(shifted, ' ')
			}
			for c, ch := range shifted {
				v.set(v.r, c, ch)
			}
		}
		return // no cursor move
	case 'L', 'M':
		if v.r < v.top || v.r > v.bottomRow() {
			return
		}
		saved := v.top
		v.top = v.r
		if final == 'L' {
			v.scrollDown(arg(0, 1))
		} else {
			v.scrollUp(arg(0, 1))
		}
		v.top = saved
		return
	case 'S':
		v.scrollUp(arg(0, 1))
		return
	case 'T':
		v.scrollDown(arg(0, 1))
		return
	case 'r':
		v.top, v.bottom = arg(0, 1)-1, arg(1, 0)-1
		if v.rows > 0 && (v.bottom < 0 || v.bottom >= v.rows) {
			v.bottom = v.rows - 1
		}
		if v.bottom >= 0 && v.top >= v.bottom {
			v.top, v.bottom = 0, -1
		}
		v.r, v.c = 0, 0
	case 'b':
		for n := arg(0, 1); n > 0 && v.last != 0; n-- {
			v.put(v.last)
		}
		return
	case 's':
		v.savedR, v.savedC = v.r, v.c
		return
	case 'u':
		v.r, v.c = v.savedR, v.savedC
	default:
		return // SGR and every other mode/report sequence: no effect on the cells
	}
	v.clampCursor()
	v.ensureRow(v.r)
}

// vtWide reports double-width (East Asian wide / emoji) runes — enough to keep
// columns aligned with the terminal on the rows the matcher reads.
func vtWide(r rune) bool {
	return r >= 0x1100 && (r <= 0x115f || (r >= 0x2e80 && r <= 0xa4cf && r != 0x303f) ||
		(r >= 0xac00 && r <= 0xd7a3) || (r >= 0xf900 && r <= 0xfaff) || (r >= 0xfe30 && r <= 0xfe4f) ||
		(r >= 0xff00 && r <= 0xff60) || (r >= 0xffe0 && r <= 0xffe6) || (r >= 0x1f300 && r <= 0x1f64f) ||
		(r >= 0x1f900 && r <= 0x1f9ff) || (r >= 0x20000 && r <= 0x3fffd))
}

// markerFraming renders the bytes around the LAST occurrence of marker for the
// Save & End fallback log (t-6291), with content masked: escape sequences and
// control bytes are shown quoted, the marker is kept, symbols/spaces are kept
// (they are the framing — bullets, borders), and every letter or digit becomes
// "x". So the log shows exactly how the line was framed without recording what
// the agent wrote — t-ffb9's rule is lifecycle metadata, never PTY content.
var framingTokenRe = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b.?`)

func markerFraming(buf []byte, marker string) string {
	raw := string(buf)
	i := strings.LastIndex(raw, marker)
	if i < 0 {
		return "absent"
	}
	lo, hi := i-160, i+len(marker)+80
	if lo < 0 {
		lo = 0
	}
	if hi > len(raw) {
		hi = len(raw)
	}
	for lo > 0 && !utf8.RuneStart(raw[lo]) {
		lo--
	}
	for hi < len(raw) && !utf8.RuneStart(raw[hi]) {
		hi++
	}
	win := raw[lo:hi]
	var b strings.Builder
	mask := func(seg string) { maskInto(&b, seg, marker) }
	last := 0
	for _, m := range framingTokenRe.FindAllStringIndex(win, -1) {
		mask(win[last:m[0]])
		b.WriteString(strings.ReplaceAll(win[m[0]:m[1]], "\x1b", "ESC"))
		last = m[1]
	}
	mask(win[last:])
	return b.String()
}

func maskInto(b *strings.Builder, seg, marker string) {
	for len(seg) > 0 {
		if strings.HasPrefix(seg, marker) {
			b.WriteString(marker)
			seg = seg[len(marker):]
			continue
		}
		r, size := utf8.DecodeRuneInString(seg)
		switch {
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\n':
			b.WriteString(`\n`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(b, `\x%02x`, r)
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteByte('x')
		default:
			b.WriteRune(r)
		}
		seg = seg[size:]
	}
}

// copilotLoginTailWindow bounds how much of the recent buffer saveAndEnd's
// pre-check (t-acc5) scans for copilotNeedsLogin — see its call site for why
// this must be a tail window, not the full buffer or a sentAt-scoped slice.
// Scrollback caps at 256KB by default; 4KB is a small, deliberately narrow
// fraction of it — comfortably larger than the observed real login message
// plus its surrounding menu text, while far smaller than what a healthy
// session doing real subsequent work would accumulate.
const copilotLoginTailWindow = 4096

// copilotNeedsLogin detects copilot's stable "not logged in" output (t-af51):
// unlike a resume-id ghost session (t-f15b), there is no proactive pre-spawn
// check for copilot's auth state, so PTY-output matching is the only signal
// available. An unauthenticated copilot process never exits and never touches
// a watched file or emits the save marker — it just idles at its own prompt —
// so without this check saveAndEnd always waits out the full saveFallback.
// Substring (not whole-line) match, since copilot's message may render inside
// a decorated/boxed line rather than a bare one; two independently-worded
// substrings so a minor CLI copy change doesn't fully break detection.
func copilotNeedsLogin(buf []byte) bool {
	clean := ansiCSIRe.ReplaceAllString(string(buf), "")
	return strings.Contains(clean, "You must be logged in") || strings.Contains(clean, "Please use /login")
}

// copilotMenuPending reports whether a copilot session is sitting on one of its
// selection menus (t-f91a): the tool-call approval ("Do you want to allow this?
// 1. Yes / 2. Yes, and remember… / 3. No (Esc)") or the folder-trust prompt. Anything
// typed at such a menu ANSWERS it — Enter picks the highlighted option (approving a
// tool call, or trusting a folder), Esc rejects — so Save & End must send nothing
// while one is up. Copilot has no needs-you event, and while a tool is pending its
// elapsed-time counter keeps redrawing, so PTY quiescence never flags it either:
// the screen is the only signal.
//
// The signature, taken from real captures (testdata/copilot-*-menu.bin), is the
// footer both menus share — "↑/↓ to navigate · enter to select · esc to cancel" —
// AND their last option, "3. No (Esc)" (or, on the command-approval menu, "… (Esc to
// stop)", t-7c4f). The footer alone is the phrase an agent
// would quote when discussing this very feature; requiring the option too makes a
// quote-induced false positive need three menu phrases, not two. (A menu without a
// "No (Esc)" option is not detected: that fails open, i.e. today's behavior.) It is
// matched on the RENDERED screen, over its last few non-blank rows (a menu is the
// live UI, at the bottom; scrollback that once held one must not count). Only
// letters and digits are compared, so a footer wrapped across rows, or across a
// bordered box's "│" edges, on a narrow terminal still matches. Once the menu is
// answered copilot erases those rows, so the match goes away by itself.
func copilotMenuPending(buf []byte, cols, rows int) bool {
	v := newVTScreen(cols, rows)
	v.feed(buf)
	const lastRows = 15
	var picked []string
	for i := len(v.grid) - 1; i >= 0 && len(picked) < lastRows; i-- {
		if t := v.rowText(v.grid[i]); strings.TrimSpace(t) != "" {
			picked = append(picked, t)
		}
	}
	var b strings.Builder
	for i := len(picked) - 1; i >= 0; i-- {
		b.WriteString(picked[i])
	}
	flat := strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, b.String())
	// t-7c4f: the command-approval menu's last option reads "No, and tell Copilot what to
	// do differently (Esc to stop)" — still three phrases with the footer.
	return strings.Contains(flat, "entertoselect") && strings.Contains(flat, "esctocancel") &&
		(strings.Contains(flat, "noesc") || strings.Contains(flat, "esctostop"))
}

// menuRefusal is the body of the 409 Save & End returns while a menu is pending.
const menuRefusal = "Copilot is waiting for your answer to a prompt in the terminal — answer it there, then Save & End again (or End without saving)."

// menuPendingLocked is copilotMenuPending over the session's own buffer (se.mu held).
func (se *session) menuPendingLocked() bool {
	return se.agent == "copilot" && copilotMenuPending(se.buf, se.cols, se.rows)
}

// copilotHasPendingMenu is menuPendingLocked for callers that don't hold se.mu.
func (se *session) copilotHasPendingMenu() bool {
	se.mu.Lock()
	defer se.mu.Unlock()
	return se.menuPendingLocked()
}

// copilotResumeFailed detects copilot's stable "dead resume id" output
// (t-6ce0): copilotSessionExists only stats <COPILOT_HOME>/session-state/<id>,
// but that directory can exist without a matching row in copilot's real
// resumability index (session-store.db, a genuine SQLite database, confirmed
// live) — e.g. a crash after copilot creates working-state scaffolding but
// before it commits the session row. Unlike copilotNeedsLogin's permanent
// hang, a dead --resume attempt exits almost immediately with this text, so
// the caller (handleStart) can detect it and retry fresh within one request.
func copilotResumeFailed(buf []byte) bool {
	clean := ansiCSIRe.ReplaceAllString(string(buf), "")
	return strings.Contains(clean, "No session, task, or name matched")
}

// ── preview pane (t-b19b) ────────────────────────────────────────────────
//
// Serves the containing directory of whatever file the agent reports via a
// PREVIEW_FILE marker (cockpit.html watches for it and relays the path here),
// so a small static app's sibling ./style.css/./app.js resolve the way any
// real static file server would — not just the one named file. Bounded to
// projectRoot plus the session's own re-validated worktree cwd (t-8e73): the daemon process already has full read access to the whole
// project, so the actual thing this check prevents is a malformed or
// malicious absolute path (typo, injected content) pointing the browser at
// files outside the project entirely (e.g. ~/.ssh, /etc/passwd).
//
// The daemon re-validates the path itself rather than trusting whatever the
// client relayed — cockpit.html has no privileged position to assert a path
// is safe; only the daemon, which already owns path-safety logic elsewhere,
// does.

// previewRootFor resolves the safe, symlink-checked directory to serve for a
// reported (agent-chosen) absolute file path. Rejects a non-absolute path, a
// nonexistent directory, or one whose resolved real path falls outside EVERY
// allowed root. Callers pass the session's project root plus its own validated
// cwd (t-8e73): a worktree session's files live in a sibling directory of the
// main checkout, so the project root alone can never contain them. Empty roots
// are ignored; with none left nothing is allowed.
func previewRootFor(reportedPath string, roots ...string) (string, bool) {
	if !filepath.IsAbs(reportedPath) {
		return "", false
	}
	dir := filepath.Dir(filepath.Clean(reportedPath))
	resolvedDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", false // doesn't exist or can't be resolved — never assume safe
	}
	for _, root := range roots {
		if root == "" {
			continue
		}
		resolvedRoot, err := filepath.EvalSymlinks(root)
		if err != nil {
			resolvedRoot = root
		}
		rel, err := filepath.Rel(resolvedRoot, resolvedDir)
		if err == nil && !strings.HasPrefix(rel, "..") {
			return resolvedDir, true
		}
	}
	return "", false
}

// previewRejectReason names why previewRootFor refused a path, for the verbose log
// (t-75cb). previewRootFor stays pure and unchanged; this mirrors its first two checks
// and attributes anything else to the roots.
func previewRejectReason(reportedPath string) string {
	if !filepath.IsAbs(reportedPath) {
		return "not absolute"
	}
	if _, err := filepath.EvalSymlinks(filepath.Dir(filepath.Clean(reportedPath))); err != nil {
		return "directory unresolvable"
	}
	return "outside allowed roots"
}

// handlePreviewRoot validates and stores the one directory this session's
// /preview/<relpath> route will serve from. Authenticated via the real
// session token (only the trusted board relay reaches here) — never the
// narrower previewToken, which authorizes reads only, not setting the root.
func (s *server) handlePreviewRoot(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	// t-391a: preview containment is scoped to THIS session's project root
	// (git toplevel of its cwd), not the launch global — so one daemon serving
	// many projects still confines each preview to its own project. Falls back
	// to the launch global if unset (older/directly-constructed sessions).
	projectRoot := se.projectRoot
	if projectRoot == "" {
		projectRoot = s.cfg.projectRoot
	}
	// t-8e73: a worktree session runs (and prints PREVIEW_FILE) in its own cwd, a sibling of the main
	// checkout that projectRoot names — allow that cwd too. Spawn now validates a persisted .cockpit-cwd
	// (t-6a45), but a worktree can be removed or the file rewritten while the session lives, so re-validate
	// it NOW against the project root / a live `git worktree list` (resolveSpawnCwd) and add it only if it
	// passes; otherwise the preview stays bounded to projectRoot. A session still can't preview another
	// worktree or project.
	roots := []string{projectRoot}
	if se.cwd != "" {
		if cwd, cok := s.resolveSpawnCwd(se.cwd, projectRoot); cok {
			roots = append(roots, cwd)
		}
	}
	root, ok := previewRootFor(body.Path, roots...)
	if !ok {
		se.debugf("preview-root rejected path=%q reason=%s", body.Path, previewRejectReason(body.Path))
		http.Error(w, "path not allowed", http.StatusBadRequest)
		return
	}
	se.debugf("preview-root accepted path=%q root=%q", body.Path, root)
	se.mu.Lock()
	se.previewRoot = root
	se.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// handlePreview serves a file from the session's validated preview root.
// GET-only. The previewToken is the FIRST path segment of tokenAndPath
// (/session/<sid>/preview/<token>/<relpath>), never a query param (t-8fbc): a
// relative subresource (./style.css) from the served page drops a query string
// on URL resolution but preserves the path prefix, so the token rides along and
// sibling assets resolve. Same secrecy as the old query form — the untrusted
// app can read the token off location either way, and it stays a read-only,
// this-root-only capability (constant-time compared). http.FileServer(http.Dir(root))
// already refuses to serve anything above root via "../" in relpath; root itself
// was already validated to be under projectRoot (or the session's own worktree cwd) at /preview-root time.
func (s *server) handlePreview(w http.ResponseWriter, r *http.Request, se *session, tokenAndPath string) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Split "<token>/<relpath>" on the first slash. A request with no relpath
	// (e.g. .../preview/<token> or .../preview/<token>/ after the index redirect)
	// yields relpath "" → served as the directory index by http.FileServer.
	token, relpath, _ := strings.Cut(tokenAndPath, "/")
	if !secureEqual(token, se.previewToken) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	se.mu.Lock()
	root := se.previewRoot
	se.mu.Unlock()
	if root == "" {
		http.Error(w, "no preview available", http.StatusNotFound)
		return
	}
	// Rewrite the path (StripPrefix's own pattern) rather than constructing a
	// bare *http.Request from scratch, so headers like If-Modified-Since and
	// Range still reach the file server unchanged.
	r2 := new(http.Request)
	*r2 = *r
	r2.URL = new(url.URL)
	*r2.URL = *r.URL
	r2.URL.Path = "/" + relpath
	http.FileServer(http.Dir(root)).ServeHTTP(w, r2)
}

// ── needs-you status ───────────────────────────────────────────────────────

// errNoDaemonAddr means the hook has no callback URL to point at — only
// reachable before the listener is bound, so it is expected in unit tests and
// not worth a warning.
var errNoDaemonAddr = errors.New("daemon address unknown")

// hookMatchers maps Claude Code Notification types (hook matchers) to the status they post.
var hookMatchers = []struct{ matcher, status string }{
	{"permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", "needs-you"},
	{"idle_prompt|agent_completed", "awaiting-input"},
}

// writeHookSettings builds the daemon-owned, session-scoped settings file passed
// to `claude --settings`. It holds one Notification hook entry per hookMatchers
// row: questions post "needs-you", finishing / idling at the prompt posts
// "awaiting-input" (both verified live, t-2e7e and t-824e).
//
// The credential is a STATUS-ONLY token (never the session token — see
// handleSession), and it travels in curl's -K config file rather than on curl's
// argv, so it never appears in `ps` output. Every file is 0600 under the
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
	// t-824e: one curl config per status. Questions mean the agent is blocked on the human
	// (needs-you, never reaped); finishing or idling at the prompt is "awaiting-input" (shown as
	// done, reaped on the normal timer). Any other notification (auth_success, quota_*) posts nothing —
	// without matchers every notification marked needs-you and idle sessions were never reaped.
	entries := []any{}
	for _, h := range hookMatchers {
		conf := fmt.Sprintf("url = \"http://%s/session/%s/status\"\nheader = \"Authorization: Bearer %s\"\nrequest = \"POST\"\ndata = \"%s\"\nnoproxy = \"*\"\nsilent\nmax-time = 3\n", s.cfg.addr, sid, statusToken, h.status)
		confPath := filepath.Join(dir, h.status+".conf")
		if err := os.WriteFile(confPath, []byte(conf), 0o600); err != nil {
			os.RemoveAll(dir)
			return "", err
		}
		// `|| true`: a status ping must never fail the agent's own turn.
		entries = append(entries, map[string]any{
			"matcher": h.matcher,
			"hooks": []any{map[string]any{
				"type":    "command",
				"command": "curl -K " + shellQuote(confPath) + " >/dev/null 2>&1 || true",
			}},
		})
	}
	hook := map[string]any{"hooks": map[string]any{"Notification": entries}}
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
// tools/ticket-root.sh's tickets_dir(). The board server's spawn() sets
// COCKPIT_PROJECT_ROOT from its own resolved project root, so a mismatch here
// would otherwise make every Gate model: override a silent no-op —
// indistinguishable from "no plan.md yet", since both are just a read error.
func (s *server) ticketsDir() string {
	return s.ticketsDirIn(s.cfg.projectRoot)
}

// sessionStateDir is where a session's per-session state files live (t-47f1): a
// ticket's own .tickets/<id>/, or — for a scratch session, which has no ticket — a
// daemon-owned dir keyed by project, so nothing is written into the project.
func (s *server) sessionStateDir(root, id string) string {
	if isScratch(id) {
		sum := sha256.Sum256([]byte(root))
		return filepath.Join(s.cfg.stateDir, "scratch", hex.EncodeToString(sum[:])[:12], id)
	}
	return filepath.Join(s.ticketsDirIn(root), id)
}

// ticketsDirIn resolves the .tickets dir for an arbitrary project root by
// walking up from it (t-391a: per-request project scoping — one daemon serves
// many projects). ticketsDir() is the launch-default wrapper.
func (s *server) ticketsDirIn(root string) string {
	dir := root
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
	return filepath.Join(root, ".tickets")
}

// listWorktrees returns the absolute path of every worktree `git` knows about
// for projectRoot (main checkout included), parsed from `git worktree list
// --porcelain`'s "worktree <path>" lines — the ticket's own resolved design
// names this the single source of truth, deliberately not a cockpit-owned
// registry.
// listWorktreesIn lists git worktrees for an arbitrary root (t-391a). The FIRST
// entry is always the main checkout — the tree where a gitignored `.tickets/`
// actually lives — so it doubles as "the project root for this cwd".
func (s *server) listWorktreesIn(root string) ([]string, error) {
	out, err := exec.Command("git", "-C", root, "worktree", "list", "--porcelain").Output()
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, line := range strings.Split(string(out), "\n") {
		if p, ok := strings.CutPrefix(line, "worktree "); ok {
			paths = append(paths, p)
		}
	}
	return paths, nil
}

// resolveProjectForCwd derives the project root for a client-supplied cwd so a
// single daemon can serve tickets from ANY project (t-391a, nebula's model),
// not just the launch-time COCKPIT_PROJECT_ROOT. The daemon never trusts the
// client string: the cwd must be absolute, exist (EvalSymlinks), and be a real
// git working tree. The returned root is that tree's MAIN checkout (the first
// `git worktree list` entry) — where a gitignored `.tickets/` lives — so a
// linked-worktree cwd still resolves to the parent repo that holds the ticket,
// preserving the t-e5ff "not visible in this worktree" flow. Empty cwd falls
// back to cfg.projectRoot (backward compatible). Reuses the OS-aware
// EvalSymlinks/pathsEqual helpers — no per-OS path branch (DRY, Mac/Win).
func (s *server) resolveProjectForCwd(cwd string) (string, bool) {
	if cwd == "" {
		// Verbatim (not EvalSymlinks'd): the "" request resolves to the launch
		// projectRoot and must echo it unchanged, matching the actual spawn cwd
		// and the `requested` echo (t-7590/t-eed3). Containment/ticket checks
		// EvalSymlinks internally, so a symlinked root is still handled.
		return s.cfg.projectRoot, true
	}
	if !filepath.IsAbs(cwd) {
		return "", false
	}
	resolved, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		return "", false
	}
	wts, err := s.listWorktreesIn(resolved)
	if err != nil || len(wts) == 0 {
		return "", false // not a git working tree — never assume a project
	}
	if main, err := filepath.EvalSymlinks(wts[0]); err == nil {
		return main, true
	}
	return wts[0], true
}

// pathsEqual compares two already-resolved absolute paths. Windows paths are
// case-insensitive; POSIX paths are not.
func pathsEqual(a, b string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// resolveSpawnCwd validates a client-supplied cwd against the given project
// root or a live `git worktree list` re-check — the daemon never trusts the
// client string alone (t-b19b). An empty cwd resolves to the project root.
// t-391a: projectRoot is now per-request (resolveProjectForCwd), not the launch
// global, so one daemon validates cwds for any project.
func (s *server) resolveSpawnCwd(cwd, projectRoot string) (string, bool) {
	if cwd == "" {
		return projectRoot, true
	}
	if !filepath.IsAbs(cwd) {
		return "", false
	}
	resolvedCwd, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		return "", false // doesn't exist or can't be resolved — never assume safe
	}
	resolvedRoot, err := filepath.EvalSymlinks(projectRoot)
	if err != nil {
		resolvedRoot = projectRoot
	}
	if pathsEqual(resolvedCwd, resolvedRoot) {
		return resolvedCwd, true
	}
	worktrees, err := s.listWorktreesIn(projectRoot)
	if err != nil {
		return "", false
	}
	for _, wt := range worktrees {
		resolvedWt, err := filepath.EvalSymlinks(wt)
		if err != nil {
			continue
		}
		if pathsEqual(resolvedWt, resolvedCwd) {
			return resolvedCwd, true
		}
	}
	return "", false
}

// resolveSpawnCwdForTicket persists the resolved cwd to
// .tickets/<id>/.cockpit-cwd, mirroring resolveClaudeSessionID's pattern: an
// already in_progress ticket reads its persisted cwd back and reuses it
// (once it still re-validates, t-6a45) regardless of what the client
// requested, so a live claude conversation is
// never reattached in a different directory than it started in and the
// WORKTREE picker never needs to be re-asked mid-sprint. A ticket freshly
// (re)opened from open/closed re-resolves and re-persists, same as a fresh
// (non-resumed) claude session id.
func (s *server) resolveSpawnCwdForTicket(ticket, requestedCwd, projectRoot string) (string, bool) {
	cwdPath := filepath.Join(s.sessionStateDir(projectRoot, ticket), ".cockpit-cwd")
	keepPersisted := false
	if s.ticketStatusIn(projectRoot, ticket) == "in_progress" || s.adoptedTicket(projectRoot, ticket) {
		if b, err := os.ReadFile(cwdPath); err == nil {
			if existing := strings.TrimSpace(string(b)); existing != "" {
				// .cockpit-cwd lives in agent-writable .tickets/, so re-validate it like
				// any fresh cwd (t-6a45). A worktree removed between sessions, or a
				// tampered value, fails here and falls through to re-resolve from the
				// request instead of spawning somewhere unvalidated.
				if cwd, ok := s.resolveSpawnCwd(existing, projectRoot); ok {
					return cwd, true
				}
				// Don't overwrite a value that still exists on disk: validation also fails
				// closed on a transient `git worktree list` error, and rewriting would
				// permanently unbind a legit worktree. A tampered value stays inert — it is
				// re-validated on every start. Only a vanished directory is re-persisted.
				if _, err := os.Stat(existing); err == nil {
					keepPersisted = true
				}
			}
		}
	}
	resolved, ok := s.resolveSpawnCwd(requestedCwd, projectRoot)
	if !ok {
		return "", false
	}
	if !keepPersisted {
		_ = os.WriteFile(cwdPath, []byte(resolved+"\n"), 0o600)
	}
	return resolved, true
}

// logSessionStart appends one line to .tickets/<id>/cockpit-sessions.md
// recording which worktree (or the main checkout) a sprint start used —
// renamed from logWorktreeDecision (t-022f): this is a mechanical
// session-start audit trail, not a "decision", and writing it to Decisions.md
// collided with the board's real Decisions tab (doc tabs are generated from
// any *.md file in a ticket dir, named after the filename — see
// server.py/_doc_name and sprint-check-go's parity glob). Lives inside
// spawn() — the single code path every /session/start call goes through,
// regardless of client — so it can't be bypassed by hitting the endpoint
// directly instead of going through the board UI. Best-effort: a write
// failure is logged to stderr and never blocks the spawn that already
// succeeded. Consecutive same-day, same-label starts collapse to one line so
// repeated resumes don't pile up identical entries (t-022f).
func (s *server) logSessionStart(ticket, cwd, projectRoot string) {
	label := "main checkout"
	if resolvedRoot, err := filepath.EvalSymlinks(projectRoot); err == nil {
		if !pathsEqual(cwd, resolvedRoot) && !pathsEqual(cwd, projectRoot) {
			label = cwd
		}
	} else if cwd != projectRoot {
		label = cwd
	}
	line := fmt.Sprintf("- %s: sprint start used %s\n", time.Now().UTC().Format("2006-01-02"), label)
	path := filepath.Join(s.sessionStateDir(projectRoot, ticket), "cockpit-sessions.md")

	if existing, err := os.ReadFile(path); err == nil {
		lines := strings.Split(strings.TrimRight(string(existing), "\r\n"), "\n")
		last := strings.TrimSuffix(lines[len(lines)-1], "\r")
		if last == strings.TrimSuffix(line, "\n") {
			return // same date + same label as the last entry — skip the duplicate
		}
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cockpit: session log unavailable: %v\n", err)
		return
	}
	defer f.Close()
	if _, err := f.WriteString(line); err != nil {
		fmt.Fprintf(os.Stderr, "cockpit: session log write failed: %v\n", err)
	}
}

var ticketStatusRe = regexp.MustCompile(`(?m)^status:\s*(\S+)`)

// ticketStatus reads the `status:` frontmatter field from a ticket's own
// ticket.md. Empty string (never an error) if the file or field is absent —
// callers treat that the same as "not in_progress" (t-2e7e).
// ticketStatusIn reads a ticket's status from an arbitrary project root (t-391a).
func (s *server) ticketStatusIn(root, ticket string) string {
	b, err := os.ReadFile(filepath.Join(s.sessionStateDir(root, ticket), "ticket.md"))
	if err != nil {
		return ""
	}
	m := ticketStatusRe.FindSubmatch(b)
	if m == nil {
		return ""
	}
	return string(m[1])
}

// resolveClaudeSessionID decides whether to resume a persisted claude
// session or mint a fresh one (t-2e7e). Resume only when the ticket is
// already in_progress — a ticket freshly (re)opened from open/closed always
// starts clean, so a stale, unrelated conversation is never silently resumed
// onto later work. The id is persisted to the ticket's own folder (not the
// daemon's state dir) so it survives a daemon restart.
//
// A persisted id is necessary but not sufficient to resume (t-77d7): a fresh
// spawn mints the id and flips the ticket to in_progress *before* claude
// writes any conversation, so a session killed before its first turn leaves an
// id naming a conversation that never existed. `claude --resume <id>` then
// fails hard ("No conversation found with session ID"). Resume only when a
// persisted conversation for the id actually exists; otherwise reuse the same
// id for a fresh --session-id start rather than handing claude a --resume it
// will reject.
func (s *server) resolveClaudeSessionID(ticket string) (id string, resuming bool) {
	return s.resolveClaudeSessionIDIn(s.cfg.projectRoot, ticket)
}

// resolveClaudeSessionIDIn is resolveClaudeSessionID scoped to an arbitrary
// project root (t-391a).
func (s *server) resolveClaudeSessionIDIn(root, ticket string) (id string, resuming bool) {
	idPath := filepath.Join(s.sessionStateDir(root, ticket), ".cockpit-session-id")
	if s.ticketStatusIn(root, ticket) == "in_progress" || s.adoptedTicket(root, ticket) {
		if b, err := os.ReadFile(idPath); err == nil {
			if existing := strings.TrimSpace(string(b)); existing != "" {
				return existing, claudeConversationExists(existing)
			}
		}
	}
	id = newUUIDv4()
	_ = os.WriteFile(idPath, []byte(id+"\n"), 0o600)
	return id, false
}

// resolveCopilotSessionIDIn mints/persists a session id for copilot (t-66b2),
// scoped to an arbitrary project root. Deliberately its own file
// (.cockpit-copilot-session-id), not claude's .cockpit-session-id — sharing
// would let a ticket that switched agents hand copilot a UUID claude minted
// (or vice versa), which either agent's --resume/--session-id would mishandle.
//
// A persisted id is necessary but not sufficient to resume (t-f15b, mirroring
// claude's t-77d7): a fresh spawn persists the id before copilot has created
// anything, so a session that crashed before its first turn (e.g. the
// pre-t-f15b/t-66b2 argv bug) leaves an id naming a session that never
// existed — copilot then rejects --resume=<id> hard ("No session, task, or
// name matched"). copilotSessionExists checks copilot's own on-disk
// session-state directory (verified live) before trusting the persisted id,
// same shape as claudeConversationExists above; unlike a stale claude id,
// a stale copilot one is simply retried as a fresh --session-id start rather
// than minting a brand new UUID, since the ticket-scoped file already names
// one nothing else could be resuming.
func (s *server) resolveCopilotSessionIDIn(root, ticket string) (id string, resuming bool) {
	idPath := filepath.Join(s.sessionStateDir(root, ticket), ".cockpit-copilot-session-id")
	if s.ticketStatusIn(root, ticket) == "in_progress" {
		if b, err := os.ReadFile(idPath); err == nil {
			if existing := strings.TrimSpace(string(b)); existing != "" {
				return existing, copilotSessionExists(copilotHomeDir(), existing)
			}
		}
	}
	id = newUUIDv4()
	_ = os.WriteFile(idPath, []byte(id+"\n"), 0o600)
	return id, false
}

// copilotResumeGraceWindow/copilotResumeGracePoll bound how long
// recoverCopilotResumeIfFailed waits for a dead --resume attempt to reveal
// itself (t-6ce0). t-2e84's original 2s budget was set from a single macOS
// measurement ("well under 1s") — live Windows capture (t-a4ed) showed a dead
// --resume attempt spends its first ~2s writing nothing but a TUI-init escape
// burst (alternate-screen/cursor-hide sequences, zero visible text) while it
// makes what's likely a real network round-trip to GitHub's backend before it
// can determine the id is dead; the actual "No session, task, or name
// matched" text didn't land until ~2.9s in. 6s leaves real margin above that
// measurement without making a genuinely successful resume — which never
// exits in this window at all — feel delayed.
const (
	copilotResumeGraceWindow = 6 * time.Second
	copilotResumeGracePoll   = 100 * time.Millisecond
)

// recoverCopilotResumeIfFailed grace-checks a just-spawned copilot --resume
// attempt (t-6ce0): copilotSessionExists's directory stat is necessary but not
// sufficient — copilot's real resumability index is a SQLite database
// (session-store.db, confirmed live), so a stale/incomplete session-state
// directory can pass the proactive check yet still be rejected by copilot
// itself ("No session, task, or name matched"). Unlike copilotNeedsLogin's
// permanent hang, this failure exits almost immediately, so the correction
// happens entirely here, before the client ever receives a session id/token —
// on detection, a fresh UUID is persisted (so the natural next
// resolveCopilotSessionIDIn read takes the fresh-start branch on its own, no
// special-cased bypass needed) and spawn is retried once. If the window
// passes without a confirmed match, se is returned unchanged — this can only
// ever ADD a bounded wait to a copilot resume attempt, never affect any other
// spawn path.
func (s *server) recoverCopilotResumeIfFailed(se *session, ticket, cwd, projectRoot string) (*session, error) {
	se.debugf("resume-check started")
	deadline := time.Now().Add(copilotResumeGraceWindow)
	for time.Now().Before(deadline) {
		se.mu.Lock()
		exited := se.exited
		buf := append([]byte(nil), se.buf...)
		se.mu.Unlock()
		// t-2e84: check the failure text FIRST, independent of se.exited — that
		// flag is only set inside readLoop() when the PTY read returns EOF,
		// which can lag the real OS process exit (live-reproduced on Windows:
		// Task Manager showed copilot.exe spawn and disappear, but se.exited
		// never flipped within the grace window, so the retry never fired even
		// though the failure text was already sitting in the buffer). The text
		// alone is sufficient proof — a process that printed it isn't going to
		// un-print it or recover on its own, regardless of exit-signal timing.
		if copilotResumeFailed(buf) {
			se.debugf("resume-check matched dead-resume text — killing and retrying fresh")
			s.killSession(se) // idempotent even if the process already exited naturally
			idPath := filepath.Join(s.sessionStateDir(projectRoot, ticket), ".cockpit-copilot-session-id")
			_ = os.WriteFile(idPath, []byte(newUUIDv4()+"\n"), 0o600)
			return s.spawn(ticket, cwd, projectRoot, "copilot")
		}
		if exited {
			se.debugf("resume-check exited without a match — treating as unrelated")
			return se, nil // exited for an unrelated reason — not this ticket's concern
		}
		time.Sleep(copilotResumeGracePoll)
	}
	se.debugf("resume-check deadline exceeded — treating as legitimate resume")
	return se, nil // still running past the window — treat as a legitimate resume
}

// claudeConversationExists reports whether claude holds a persisted, resumable
// conversation for sid. Claude stores each conversation at
// <configDir>/projects/<encoded-cwd>/<sid>.jsonl, where the filename is exactly
// the session id — so a config-dir-wide glob answers "is this resumable?"
// without reproducing claude's fragile cwd->dir encoding. sid is a
// daemon-minted UUID v4 (hex + '-' only), so it carries no glob metacharacters.
// Honors CLAUDE_CONFIG_DIR (claude's own override), defaulting to ~/.claude;
// any lookup failure is reported as "not resumable" so a missing store can
// never block a spawn — it only forces a fresh start.
func claudeConversationExists(sid string) bool {
	if sid == "" {
		return false
	}
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return false
		}
		dir = filepath.Join(home, ".claude")
	}
	matches, err := filepath.Glob(filepath.Join(dir, "projects", "*", sid+".jsonl"))
	return err == nil && len(matches) > 0
}

// copilotHomeDir resolves copilot's own state directory (t-f15b), honoring its
// documented COPILOT_HOME override (`copilot help environment`), defaulting to
// ~/.copilot — the same override/default shape claude's CLAUDE_CONFIG_DIR gets
// above.
func copilotHomeDir() string {
	if dir := os.Getenv("COPILOT_HOME"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".copilot")
}

// copilotSessionExists reports whether copilot holds a real, resumable session
// for sid (t-f15b). Unlike claude's per-conversation JSONL files under
// projects/*, copilot keys a real session's state directly by id at
// <home>/session-state/<sid>/ — verified live: a crashed spawn (bad argv, the
// pre-t-f15b/t-66b2 bug) creates no such directory at all, while a real
// completed turn does, and --resume=<sid> only succeeds once it exists. No
// glob needed (copilot doesn't shard by cwd the way claude does).
func copilotSessionExists(home, sid string) bool {
	if home == "" || sid == "" {
		return false
	}
	fi, err := os.Stat(filepath.Join(home, "session-state", sid))
	return err == nil && fi.IsDir()
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

// t-824e: "awaiting-input" is the hook's "finished, at the prompt" (idle_prompt / agent_completed).
// Not "done": the pages already use "done" for an exited session.
var validStatuses = map[string]bool{"running": true, "needs-you": true, "awaiting-input": true}

// handleStatus receives the hook's ping. Gated by the session's STATUS-ONLY
// token (see handleSession) — deliberately not the session token, which the
// spawned agent could otherwise use to write to its own PTY.
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
	se.statusSince = time.Now()
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
	return s.gateModelIn(s.cfg.projectRoot, ticket)
}

// gateModelIn is gateModel scoped to an arbitrary project root (t-391a).
func (s *server) gateModelIn(root, ticket string) string {
	plan := filepath.Join(s.sessionStateDir(root, ticket), "plan.md")
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
	// t-ef27: `openai:<id>` picks an OpenAI model for the close gates under Copilot
	// CLI. The session itself runs on the harness default, so it is no --model here;
	// mirrors gate_model_resolve.
	if id := strings.TrimPrefix(v, "openai:"); id != v {
		if !modelValueRe.MatchString(id) {
			fmt.Fprintf(os.Stderr, "cockpit: ignoring invalid Gate model %q in %s (openai:<id> — the id must start with a letter or digit; letters, digits, '.', '_', '-' only)\n", v, plan)
		}
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

// version is the build id, stamped via -ldflags "-X main.version=<sha>" by
// scripts/build-zip.sh (short SHA of the last commit touching
// tools/cockpit-daemon). A plain `go build` leaves it "dev". t-99fa.
var version = "dev"

// commit is the build provenance (short SHA of the last commit touching this
// binary's source dir), stamped via -ldflags "-X main.commit=<sha>" by
// scripts/build-zip.sh. `version` carries the semantic version (t-5c20).
var commit = "dev"

// versionString renders the human build id: "<semver> (<sha>)" when a real
// commit is stamped, else just the semver/`dev`.
func versionString() string {
	if commit != "" && commit != "dev" {
		return version + " (" + commit + ")"
	}
	return version
}

// execMtime is the Unix mtime of this daemon's own executable, captured once at
// startup (see main). The board compares it to the on-disk binary's mtime to
// detect a stale/version-drifted running daemon (t-74d6) — robust even for
// `dev` builds where the version string never changes.
var execMtime int64

// startTime is captured once at daemon boot; /version reports uptime_secs =
// seconds since this, so the Cockpit Admin panel can show daemon uptime (t-5dc2).
var startTime = time.Now()

func executableMtime() int64 {
	exe, err := os.Executable()
	if err != nil {
		return 0
	}
	st, err := os.Stat(exe)
	if err != nil {
		return 0
	}
	return st.ModTime().Unix()
}

func main() {
	versionFlag := flag.Bool("version", false, "print build version and exit")
	addr := flag.String("addr", envOr("COCKPIT_ADDR", "127.0.0.1:8455"), "loopback bind address")
	flag.Parse()
	if *versionFlag {
		fmt.Println(versionString())
		return
	}
	execMtime = executableMtime()

	if !strings.HasPrefix(*addr, "127.0.0.1:") && !strings.HasPrefix(*addr, "localhost:") && !strings.HasPrefix(*addr, "[::1]:") {
		fmt.Fprintln(os.Stderr, "refusing non-loopback bind:", *addr)
		os.Exit(2)
	}
	cfg := config{
		addr:              *addr,
		token:             envOr("COCKPIT_TOKEN", randToken()),
		sprintBin:         envOr("COCKPIT_SPRINT_BIN", "claude"),
		projectRoot:       envOr("COCKPIT_PROJECT_ROOT", mustGetwd()),
		idleTimeout:       envDurationOr("COCKPIT_IDLE_TIMEOUT", 0),
		idleTimeoutMain:   envDurationOr("COCKPIT_IDLE_TIMEOUT_MAIN", 0),
		idleCheckInterval: envDurationOr("COCKPIT_IDLE_CHECK_INTERVAL", 0),
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
	fmt.Fprintf(os.Stderr, "cockpit-daemon %s listening on %s\n", version, ln.Addr().String())
	// t-44d9: graceful teardown on SIGTERM/SIGINT so a board force-restart (a
	// pid SIGTERM) reaps every session's child process group via killSession
	// instead of orphaning the agent, then clears daemon.json before exit. (On
	// Windows the board uses `taskkill /T`, a tree-kill that reaps children
	// directly; this handler is the unix graceful path.)
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		s.shutdownAllSessions()
		os.Exit(0)
	}()
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
	// t-44d9: include the daemon's pid so the board can force-restart it (kill +
	// relaunch) cross-platform without holding the boot token (t-ddc8 preserved).
	data, _ := json.Marshal(map[string]string{"addr": addr, "token": token, "pid": strconv.Itoa(os.Getpid())})
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

// envDurationOr reads a Go duration string (e.g. "10s", "2m") from the named
// env var, falling back to def (0 means "let newServer apply its own
// default") on an unset or malformed value. t-cd06: lets an operator
// shorten idleTimeout/idleTimeoutMain to observe idle-reap live without
// waiting the real 5m/30m default.
func envDurationOr(k string, def time.Duration) time.Duration {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cockpit: ignoring invalid %s %q: %v\n", k, v, err)
		return def
	}
	return d
}

func mustGetwd() string { d, _ := os.Getwd(); return d }
