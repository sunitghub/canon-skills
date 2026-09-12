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
	"syscall"
	"time"

	pty "github.com/aymanbagabas/go-pty"
)

//go:embed web
var webFS embed.FS

var ticketRe = regexp.MustCompile(`^t-[a-z0-9]{4}$`)

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
	// previewToken authorizes ONLY GET /session/<id>/preview/<relpath> (t-b19b).
	// Separate from token for the same reason as statusToken, one level further:
	// it rides in a query string (an <iframe src> can't carry an Authorization
	// header) where the PREVIEWED PAGE'S OWN untrusted JS can read it straight off
	// location.search — it must never be able to do anything but read files under
	// the resolved preview root.
	previewToken string
	pty          pty.Pty
	cmd          *pty.Cmd
	hookDir      string // daemon-owned ephemeral --settings dir; removed when the session ends
	cwd          string // t-cd06: resolved spawn cwd — read-only after spawn(), decides idle-timeout tier
	projectRoot  string // t-391a: per-session project root (git toplevel of cwd) — scopes ticket/preview, so one daemon serves many projects (nebula model)
	agent        string // t-391a: agent kind ("claude"/"pi") for the /sessions listing
	started      time.Time // t-391a: spawn time for the /sessions listing

	mu            sync.Mutex
	buf           []byte
	max           int
	subs          map[chan frame]struct{}
	status        string // "running" | "needs-you"
	done          chan struct{}
	doneOnce      sync.Once
	exited        bool
	killed        bool      // set by handleKill so readLoop's natural-exit path skips the reaper (already deleted)
	reaping       bool      // t-2e7e: set while saveAndEndIdle is in flight, guards against a second reap goroutine
	onNaturalExit func()    // set by spawn(); schedules the reap-after-TTL cleanup
	lastActivity  time.Time // t-2e7e: bumped on PTY output and on input; idle reaper's clock
	humanInputAt  time.Time // t-2e7e: bumped ONLY by a real POST /input (not PTY output/echo);
	// lets an in-flight save-and-kill detect a human actually came back and abort
	previewRoot string // t-b19b: symlink-validated dir under projectRoot; set once via /preview-root
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
		_ = json.NewEncoder(w).Encode(map[string]any{"version": version, "commit": commit, "exe_mtime": execMtime, "uptime_secs": int64(time.Since(startTime).Seconds())})
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
				if k == "pi" {
					agentHint = "Last used: Pi \u00b7 model: pi default"
				} else {
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
	if !ticketRe.MatchString(body.Ticket) {
		http.Error(w, "invalid ticket id", http.StatusBadRequest)
		return
	}
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
	if fi, err := os.Stat(filepath.Join(s.ticketsDirIn(projectRoot), body.Ticket)); err != nil || !fi.IsDir() {
		http.Error(w, "ticket not found in project", http.StatusBadRequest)
		return
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
	if !pathsEqual(cwd, projectRoot) {
		if fi, serr := os.Stat(filepath.Join(cwd, ".tickets", body.Ticket)); serr != nil || !fi.IsDir() {
			http.Error(w, "ticket not visible in this worktree (.tickets/ is gitignored) — start from the main checkout", http.StatusBadRequest)
			return
		}
	}
	se, err := s.spawn(body.Ticket, cwd, projectRoot, kind)
	if err != nil {
		http.Error(w, "spawn failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// Record the last-used agent for the picker's default + hint (only when
	// changed). After a successful spawn, so a failed start never records.
	s.persistAgentKindIn(projectRoot, body.Ticket, kind)
	// t-7590: echo the cwd the daemon actually resolved and spawned in (may
	// differ from what the client requested — a locked in_progress ticket
	// reuses its persisted .cockpit-cwd, an empty request resolves to the main
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
	reqEcho := body.Cwd
	if reqEcho == "" {
		reqEcho = s.cfg.projectRoot
	} else if rr, rerr := filepath.EvalSymlinks(reqEcho); rerr == nil {
		reqEcho = rr
	}
	writeJSON(w, map[string]string{"session": se.sid, "token": se.token, "previewToken": se.previewToken, "cwd": cwd, "requested": reqEcho})
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
// cockpit (t-0d67). "" defaults to claude (back-compatible). Only claude and pi
// are allowed — the daemon must never resolve an arbitrary client-supplied
// program, so an unknown value is rejected (ok=false → handleStart 400s).
func agentKind(a string) (string, bool) {
	switch a {
	case "", "claude":
		return "claude", true
	case "pi":
		return "pi", true
	default:
		return "", false
	}
}

// agentSpawnArgs builds the PTY command args (after the program) for the chosen
// agent (t-0d67). claude is byte-identical to the pre-t-0d67 argv:
// [--model <m>] [--settings <path>] then (--resume <id>) or (--session-id <id>
// "sprint start <ticket>"). pi uses documented flags only (option B): a positional
// "sprint start <ticket>" for a fresh start, and `-c` (continue most recent
// session in the cwd) when the ticket is already in_progress (a resume). pi takes
// no claude-only --settings/--session-id/--model (no shell hooks; needs-you is a
// Phase-2 pi extension). Pure/side-effect-free so it is unit-testable on any host.
func agentSpawnArgs(kind, ticket string, resuming bool, claudeSessionID, gateModel, settingsPath string) []string {
	prompt := "sprint start " + ticket
	if kind == "pi" {
		if resuming {
			return []string{"-c"}
		}
		return []string{prompt}
	}
	var args []string
	if gateModel != "" {
		args = append(args, "--model", gateModel)
	}
	if settingsPath != "" {
		args = append(args, "--settings", settingsPath)
	}
	if resuming {
		args = append(args, "--resume", claudeSessionID)
	} else {
		args = append(args, "--session-id", claudeSessionID, prompt)
	}
	return args
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
	p := filepath.Join(s.ticketsDirIn(root), ticket, ".cockpit-agent")
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
	// flags only and no shell hooks.
	program := s.cfg.sprintBin // claude default / COCKPIT_SPRINT_BIN override
	if kind == "pi" {
		program = envOr("COCKPIT_PI_BIN", "pi")
		// Resume (pi -c) when the ticket is already in_progress; else a fresh
		// positional "sprint start <ticket>". Option B — see agentSpawnArgs.
		args = agentSpawnArgs("pi", ticket, s.ticketStatusIn(projectRoot, ticket) == "in_progress", "", "", "")
	} else {
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
	}
	c := p.Command(resolveSpawnBin(program), args...)
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
		hookDir: hookDir, cwd: cwd, projectRoot: projectRoot,
		agent: kind, started: time.Now(),
		pty: p, cmd: c, max: s.cfg.scrollback, status: "running",
		subs: map[chan frame]struct{}{}, done: make(chan struct{}),
		lastActivity: time.Now(), // not the zero value, or it reads as instantly idle
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
		se.mu.Unlock()
		if !exited {
			out = append(out, info)
		}
	}
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
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
func (s *server) handleSaveAndEnd(w http.ResponseWriter, r *http.Request, se *session) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if se.isExited() {
		http.Error(w, "session has exited", http.StatusGone)
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
	killProcess(se.cmd) // platform-specific: no orphaned children
	se.pty.Close()
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
func (s *server) idleTimeoutFor(cwd string) time.Duration {
	resolvedRoot, err := filepath.EvalSymlinks(s.cfg.projectRoot)
	if err != nil {
		resolvedRoot = s.cfg.projectRoot
	}
	if cwd == "" || pathsEqual(cwd, resolvedRoot) || pathsEqual(cwd, s.cfg.projectRoot) {
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
		idle := time.Since(se.lastActivity) > s.idleTimeoutFor(se.cwd)
		blocked := se.status == "needs-you"
		exited := se.exited
		alreadyReaping := se.reaping
		if idle && !blocked && !exited && !alreadyReaping {
			se.reaping = true
		}
		se.mu.Unlock()
		if !idle || blocked || exited || alreadyReaping {
			continue
		}
		go s.saveAndEnd(se)
	}
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
	prompt := "Please save your current state now: append a brief status to HANDOFF.md " +
		"(where things stand and anything unresolved). Don't re-read plan.md or acceptance.md " +
		"unless something is unresolved that they don't already capture — only then update them. " +
		"Then print the exact line " + cockpitSaveMarker + " on its own, and stop."
	se.mu.Lock()
	sentAt := len(se.buf)            // only output written AFTER the prompt counts — buf may hold an
	humanBaseline := se.humanInputAt // unrelated earlier line matching the marker verbatim (e.g. from a
	se.mu.Unlock()                   // prior conversation about this very feature) that must never trigger a false kill.
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
	deadline := time.NewTimer(s.cfg.saveFallback)
	defer deadline.Stop()
	poll := time.NewTicker(500 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-deadline.C:
			s.killSession(se)
			return
		case <-poll.C:
			se.mu.Lock()
			newOutput := se.buf
			if sentAt <= len(newOutput) {
				newOutput = newOutput[sentAt:]
			} // else: buf was trimmed to max size since sentAt — scan it all, no valid offset
			found := containsMarkerLine(newOutput, cockpitSaveMarker)
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
			if exited {
				return // already gone naturally — nothing left to kill
			}
			if humanReturned {
				return
			}
			if found {
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
				s.endSaved(se)
				return
			}
		}
	}
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

// containsMarkerLine matches a whole trimmed line exactly — a coincidental
// substring mid-sentence (the agent describing what it's about to do, incl. the
// echoed save prompt) must never count, same discipline as t-f6b6's client-side
// matcher. t-2lv7: split on "\r" OR "\n" — Claude Code's TUI positions every row
// with a bare "\r" + cursor-move escape and NEVER a "\n", so splitting on "\n"
// alone left the whole buffer as one line and the marker was never isolated,
// stalling Save & End until the fallback timeout ("saves forever"). Mirrors the
// cockpit.html fix.
func containsMarkerLine(buf []byte, marker string) bool {
	clean := ansiCSIRe.ReplaceAllString(string(buf), "")
	for _, line := range strings.FieldsFunc(clean, func(r rune) bool { return r == '\n' || r == '\r' }) {
		if strings.TrimSpace(line) == marker {
			return true
		}
	}
	return false
}

// ── preview pane (t-b19b) ────────────────────────────────────────────────
//
// Serves the containing directory of whatever file the agent reports via a
// PREVIEW_FILE marker (cockpit.html watches for it and relays the path here),
// so a small static app's sibling ./style.css/./app.js resolve the way any
// real static file server would — not just the one named file. Bounded to
// projectRoot: the daemon process already has full read access to the whole
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
// nonexistent directory, or one whose resolved real path falls outside
// projectRoot.
func previewRootFor(reportedPath, projectRoot string) (string, bool) {
	if !filepath.IsAbs(reportedPath) {
		return "", false
	}
	dir := filepath.Dir(filepath.Clean(reportedPath))
	resolvedDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", false // doesn't exist or can't be resolved — never assume safe
	}
	resolvedRoot, err := filepath.EvalSymlinks(projectRoot)
	if err != nil {
		resolvedRoot = projectRoot
	}
	rel, err := filepath.Rel(resolvedRoot, resolvedDir)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", false
	}
	return resolvedDir, true
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
	root, ok := previewRootFor(body.Path, projectRoot)
	if !ok {
		http.Error(w, "path not allowed", http.StatusBadRequest)
		return
	}
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
// was already validated to be under projectRoot at /preview-root time.
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
	return s.ticketsDirIn(s.cfg.projectRoot)
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
// regardless of what the client requested, so a live claude conversation is
// never reattached in a different directory than it started in and the
// WORKTREE picker never needs to be re-asked mid-sprint. A ticket freshly
// (re)opened from open/closed re-resolves and re-persists, same as a fresh
// (non-resumed) claude session id.
func (s *server) resolveSpawnCwdForTicket(ticket, requestedCwd, projectRoot string) (string, bool) {
	cwdPath := filepath.Join(s.ticketsDirIn(projectRoot), ticket, ".cockpit-cwd")
	if s.ticketStatusIn(projectRoot, ticket) == "in_progress" {
		if b, err := os.ReadFile(cwdPath); err == nil {
			if existing := strings.TrimSpace(string(b)); existing != "" {
				if _, err := os.Stat(existing); err == nil {
					return existing, true // already validated when first written
				}
				// persisted worktree no longer exists on disk (removed between
				// sessions) — fall through and re-resolve from the request instead
				// of spawning into a directory that's gone.
			}
		}
	}
	resolved, ok := s.resolveSpawnCwd(requestedCwd, projectRoot)
	if !ok {
		return "", false
	}
	_ = os.WriteFile(cwdPath, []byte(resolved+"\n"), 0o600)
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
	path := filepath.Join(s.ticketsDirIn(projectRoot), ticket, "cockpit-sessions.md")

	if existing, err := os.ReadFile(path); err == nil {
		lines := strings.Split(strings.TrimRight(string(existing), "\n"), "\n")
		if last := lines[len(lines)-1]; last == strings.TrimSuffix(line, "\n") {
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
	b, err := os.ReadFile(filepath.Join(s.ticketsDirIn(root), ticket, "ticket.md"))
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
	idPath := filepath.Join(s.ticketsDirIn(root), ticket, ".cockpit-session-id")
	if s.ticketStatusIn(root, ticket) == "in_progress" {
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
	plan := filepath.Join(s.ticketsDirIn(root), ticket, "plan.md")
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
