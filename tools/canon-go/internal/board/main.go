package board

import (
	"bytes"
	"canon/internal/common"
	"canon/internal/events"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"math"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

var (
	frontmatterRe    = regexp.MustCompile(`(?s)^---\s*\n(.*?)\n---\s*\n`)
	fieldRe          = regexp.MustCompile(`(?m)^(\w+):\s*(.+)$`)
	headingRe        = regexp.MustCompile(`(?m)^#{1,6}\s+(.+)$`)
	modelMentionRe   = regexp.MustCompile(`(?i)\(model:\s*([^)]+)\)`)
	baseRefRe        = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`) // also used for worktree branch names — same git-ref-name charset
	imageExts        = []string{".png", ".gif", ".jpg", ".jpeg", ".webp"}
	safeVisualName   = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	modelIDRe        = regexp.MustCompile(`^[A-Za-z0-9._-]+$`) // t-7e36: mirrors server.py's MODEL_ID_RE
	projectRoot      string
	ticketsDir       string
	handoffFile      string
	appHTML          string
	cockpitHTML      string
	modelTiersPath   string
	sprintHeadless   string
	canonGateTmpl    string
	cockpitDaemonBin string
	cockpitSprintBin string
	toolsDir         string // t-f99b: canon tools dir (for the skills link target: <toolsDir>/../skills)
	headlessRuns     = map[string]map[string]any{}
	headlessRunsMu   sync.Mutex
	shellStartTime   = time.Now() // t-ade9: this server process's own start, for Cockpit Uptime
)

type docInfo struct {
	Name string `json:"name"`
	File string `json:"file"`
}

type ticket map[string]any

// version is the build id, stamped via -ldflags "-X main.version=<sha>" by
// scripts/build-zip.sh (short SHA of the last commit touching
// the board's sources, tools/src-key.sh). A plain `go build` leaves it "dev". t-99fa.
// t-5c20: `main.version` now carries the semantic version (repo-root VERSION);
// the SHA moved to `main.commit`. canonVersion() prefers the runtime VERSION
// file (present in a canon install) and falls back to the stamped value.
var version = "dev"

// commit is the build provenance short SHA, stamped via -X main.commit (t-5c20).
var commit = "dev"

// canonVersion returns the semantic version: the repo-root VERSION file
// (resolved relative to the canon tools dir, present in a real install), else
// the stamped `version`, else "dev".
func canonVersion() string {
	if toolsDir != "" {
		if b, err := os.ReadFile(filepath.Join(toolsDir, "..", "VERSION")); err == nil {
			if v := strings.TrimSpace(string(b)); v != "" {
				return v
			}
		}
	}
	return version
}

// startupBanner is the first line the board prints. It names the installed version (canonVersion reads the install's VERSION), never the
// unset build variable that a release build leaves at "dev" (t-dec4).
func startupBanner(addr string) string {
	return fmt.Sprintf("Canon Cockpit %s  listening on %s  (project: %s)", versionString(), addr, filepath.Base(projectRoot))
}

// versionString renders "<semver> (<sha>)" when a real commit is stamped.
func versionString() string { return common.VersionString(canonVersion(), commit) }

// daemonVersion returns the cockpit-daemon binary's build id via `--version`,
// or "" if the binary isn't resolved or can't report one. Best-effort — a
// stale daemon binary is otherwise invisible in the board UI (t-99fa).
func daemonVersion() string {
	if cockpitDaemonBin == "" {
		return ""
	}
	out, err := exec.Command(cockpitDaemonBin, "--version").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// Run is the board's entry point (cmd/sprint-check, t-8020): args are the command-line arguments after the program
// name; the result is the exit code. buildVersion and buildCommit are the -X stamps cmd/sprint-check carries.
func Run(buildVersion, buildCommit string, args []string) int {
	version, commit = buildVersion, buildCommit
	if len(args) > 0 {
		switch args[0] {
		case "help", "--help", "-h":
			usage()
			return 0
		case "version", "--version", "-v":
			fmt.Println(versionString())
			return 0
		}
	}
	if code, ok := runHelper(args, os.Stdin, os.Stdout, os.Stderr); ok {
		return code
	}

	port := 8423
	if len(args) > 0 {
		if p, err := strconv.Atoi(args[0]); err == nil {
			port = p
		}
	}
	for portInUse(port) {
		port++
	}

	cwd := common.Getwd()
	// t-b2ff: a system folder, a drive root or the home folder is not a project: say so and start nothing.
	home, _ := os.UserHomeDir()
	folder := common.EnvOr("SPRINT_CHECK_ROOT", cwd)
	if why := common.NotAProject(folder); why != "" {
		abs, _ := filepath.Abs(folder)
		for _, line := range common.NotAProjectMessage("canon", abs, why, home, runtime.GOOS) {
			fmt.Fprintln(os.Stderr, line)
		}
		return 1
	}
	projectRoot = findProjectRoot(common.EnvOr("SPRINT_CHECK_ROOT", cwd))
	exe, _ := os.Executable()
	toolsDir = filepath.Dir(exe)
	if strings.HasSuffix(filepath.ToSlash(toolsDir), "/sprint-check-bin") {
		toolsDir = filepath.Dir(toolsDir)
	}
	appHTML = resolveAppHTML(toolsDir, projectRoot, cwd)
	cockpitHTML = filepath.Join(filepath.Dir(appHTML), "cockpit.html")
	modelTiersPath = filepath.Join(filepath.Dir(appHTML), "model-tiers.json")
	sprintHeadless = resolveSprintHeadless(toolsDir, projectRoot, cwd)
	canonGateTmpl = resolveCanonGateTemplate(toolsDir, projectRoot, cwd)
	cockpitDaemonBin = resolveCockpitDaemon(toolsDir, projectRoot, cwd)
	// Passes through an explicit COCKPIT_SPRINT_BIN override (e.g. a test
	// stub); otherwise empty, so the daemon's own default ("claude", t-842b)
	// applies — never the bash sprint CLI, which doesn't understand claude's
	// --settings flag (t-7bdd).
	cockpitSprintBin = os.Getenv("COCKPIT_SPRINT_BIN")
	ticketsDir = filepath.Join(projectRoot, ".tickets")
	handoffFile = filepath.Join(projectRoot, "HANDOFF.md")

	mux := http.NewServeMux()
	mux.HandleFunc("/", handle)

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	// t-68ae: refuse connections another OS user opened (Linux), on every route.
	server := &http.Server{Addr: addr, Handler: common.RequireSamePeer(mux), ConnContext: common.PeerConnContext}
	if w := common.PeerCheckWarning(); w != "" {
		fmt.Fprintln(os.Stderr, w)
	}
	url := fmt.Sprintf("http://127.0.0.1:%d", port)
	// t-6693: banner uses addr (no scheme — see server.py's mirror comment) and
	// is labeled "Canon Cockpit" not "sprint-check" — post-t-4700 every
	// supported launcher funnels into the one shared instance; there's no
	// standalone board mode left. url is still used below for the browser-open.
	fmt.Fprintln(os.Stderr, startupBanner(addr))
	fmt.Fprintf(os.Stderr, "tickets: %s\n", ticketsDir)

	if os.Getenv("SPRINT_CHECK_NO_BROWSER") != "1" {
		go func() {
			time.Sleep(400 * time.Millisecond)
			openBrowser(url)
		}()
	}

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func usage() {
	fmt.Println(`sprint-check-win — local kanban dashboard for canon projects

Usage:
  sprint-check-win        Open the dashboard for the current project
  sprint-check-win <port> Open the dashboard on a specific port
  sprint-check-win --help Show this help

Helpers (used by canon's shell tools; see helpers.go):
  headless-json, json-strings <file>, skill-check <skill-dir>,
  settings <status|add|remove> <settings.json> <allow|deny> <rule>...
  event <kind> --project <dir> --source <name> key=value...
  transcript-report <agent-transcript.jsonl> <first-line-prefix>
  integrity [--json] [--gate] [--online]
  gate-clusters [--days N] [--json]

The dashboard reads .tickets/, HANDOFF.md, and git history from the current
project. It starts a local Go HTTP server and opens the board in your default
browser.`)
}

func handle(w http.ResponseWriter, r *http.Request) {
	if !hostOK(r.Host) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	// t-9a49: no other site may frame the board (clickjacking its buttons). The CSP is added, never set, so the
	// preview's own sandbox CSP (also added) and this one are both enforced.
	w.Header().Set("X-Frame-Options", "SAMEORIGIN")
	w.Header().Add("Content-Security-Policy", "frame-ancestors 'self'")
	if r.Method == http.MethodGet {
		handleGet(w, r)
		return
	}
	if r.Method == http.MethodPost {
		handlePost(w, r)
		return
	}
	if r.Method == http.MethodDelete {
		handleDelete(w, r)
		return
	}
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

func handleDelete(w http.ResponseWriter, r *http.Request) {
	if !originOK(r.Header.Get("Origin")) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if m := apiProjectRe.FindStringSubmatch(r.URL.Path); m != nil {
		sendJSON(w, registryRemove(m[1]))
		return
	}
	http.NotFound(w, r)
}

func handleGet(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimRight(r.URL.Path, "/")
	if name, ok := strings.CutPrefix(path, "/static/"); ok {
		serveStatic(w, r, name)
		return
	}
	switch path {
	case "", "/":
		// t-5716: a top-level visit lands on the Cockpit; its tab iframes, ?standalone=1 and
		// header-less clients (curl, tools) still get the board.
		q := r.URL.Query()
		if _, standalone := q["standalone"]; r.Header.Get("Sec-Fetch-Dest") == "document" && !standalone {
			loc := "/cockpit"
			if pid := q.Get("project"); pid != "" {
				loc += "#open=" + strings.ReplaceAll(url.QueryEscape(pid), "+", "%20")
			}
			http.Redirect(w, r, loc, http.StatusFound)
			return
		}
		serveFile(w, appHTML, "text/html; charset=utf-8")
	case "/cockpit":
		if exists(cockpitHTML) {
			serveFile(w, cockpitHTML, "text/html; charset=utf-8")
		} else {
			serveFile(w, appHTML, "text/html; charset=utf-8")
		}
	case "/api/projects":
		sendJSON(w, registryLoad())
	case "/api/admin/model-tiers":
		sendJSON(w, loadModelTiers())
	case "/api/themes":
		sendJSON(w, listThemes())
	case "/api/integrity": // t-2af0: read-only; ?refresh=1 re-checks the list against getcanon.dev
		sendJSON(w, checkIntegrity(defaultIntegrityDeps(filepath.Dir(toolsDir), r.URL.Query().Get("refresh") == "1")))
	case "/api/tickets":
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		tickets := loadTickets(root)
		// Annotate BEFORE dropping archived: the cached scan is keyed by ids, so an
		// ?all=1 request inside the TTL must not miss archived tickets.
		annotateBranchDivergence(tickets, root)
		annotateLiveDocs(tickets, root)
		if !queryHasAll(r.URL.RawQuery) {
			filtered := make([]ticket, 0, len(tickets))
			for _, t := range tickets {
				if fmt.Sprint(t["status"]) != "archived" {
					filtered = append(filtered, t)
				}
			}
			tickets = filtered
		}
		sendJSON(w, tickets)
	case "/api/handoff":
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, loadHandoff(root))
	case "/api/logbook": // t-c6bb: HANDOFF.md and LEARNINGS.md text for the Logbook (logbook.go)
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, loadLogbook(root))
	case "/api/tags": // t-37e8: the starter tags and the project's own (tags.go)
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, tagsAnswer(root))
	case "/api/track-changes":
		root, errMsg, ok := trackChangesRoot(r)
		if !ok {
			if errMsg == "" {
				http.Error(w, "unknown project", http.StatusBadRequest)
			} else {
				sendJSONStatus(w, map[string]any{"ok": false, "error": errMsg}, http.StatusBadRequest)
			}
			return
		}
		sendJSON(w, trackChangesState(root))
	case "/api/git":
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, loadGit(root))
	case "/api/why":
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, loadWhy(r.URL.Query().Get("file"), root))
	case "/api/project-stats":
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, projectStats(root))
	case "/api/browse-dirs":
		// t-1b88/t-340d: read-only dir listing for the Add-Project Browse picker.
		h := strings.ToLower(r.URL.Query().Get("hidden"))
		sendJSON(w, browseDirs(r.URL.Query().Get("path"), h == "1" || h == "true"))
	case "/api/cockpit":
		sendJSON(w, cockpitDiscover())
	case "/api/cockpit-changes": // t-5a4b
		id := r.URL.Query().Get("id")
		if !common.SessionIDRe.MatchString(id) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, cockpitChanges(root, id))
	case "/api/cockpit-sessions":
		q := r.URL.Query()
		sessions := cockpitSessions()
		if sid := q.Get("id"); sid != "" { // t-180d: one session (canon wait); root= narrows it to one project
			if !common.SessionIDRe.MatchString(sid) {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			sessions = cockpitSessionsFor(sessions, sid, q.Get("root"))
		}
		switch q.Get("format") {
		case "state":
			state := "exited"
			if len(sessions) > 0 {
				state, _ = sessions[0]["state"].(string)
				if state == "" {
					state = "running"
				}
			}
			sendText(w, state)
		case "text":
			sendText(w, cockpitSessionsText(sessions))
		default:
			sendJSON(w, sessions)
		}
	case "/api/cockpit-status":
		st := cockpitStatus()
		if r.URL.Query().Get("format") == "text" {
			sendText(w, cockpitStatusText(st))
		} else {
			sendJSON(w, st)
		}
	case "/api/cockpit-interrupted":
		sendJSON(w, cockpitInterrupted())
	case "/api/version":
		sendJSON(w, map[string]string{"version": canonVersion(), "commit": commit, "daemon": daemonVersion()})
	case "/api/worktrees":
		wtTicket := r.URL.Query().Get("ticket")
		if !ticketCommitIDRe.MatchString(wtTicket) {
			wtTicket = ""
		}
		root, ok := effectiveRoot(r)
		if !ok {
			http.Error(w, "unknown project", http.StatusBadRequest)
			return
		}
		sendJSON(w, listWorktrees(wtTicket, root))
	default:
		if strings.HasPrefix(path, "/api/ticket-commit/") {
			tid := strings.TrimPrefix(path, "/api/ticket-commit/")
			if !ticketCommitIDRe.MatchString(tid) {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			root, ok := effectiveRoot(r)
			if !ok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			sendJSON(w, ticketCommitPlan(tid, root))
			return
		}
		if screenshotPathRe.MatchString(path) {
			serveFile(w, filepath.Join(projectRoot, filepath.FromSlash(strings.TrimPrefix(path, "/"))), mime.TypeByExtension(filepath.Ext(path)))
			return
		}
		if m := apiCommitRe.FindStringSubmatch(path); m != nil {
			root, ok := effectiveRoot(r)
			if !ok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			sendJSON(w, loadCommit(m[1], root))
			return
		}
		if m := apiDocRe.FindStringSubmatch(path); m != nil {
			root, ok := effectiveRoot(r)
			if !ok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			doc := unescape(m[1])
			if hasDotDotSegment(doc) {
				http.Error(w, "bad doc path", http.StatusBadRequest)
				return
			}
			content, etag, dok := readDocWithEtag(doc, root)
			if !dok {
				http.NotFound(w, r)
				return
			}
			sendJSON(w, map[string]string{"content": content, "etag": etag})
			return
		}
		if m := apiTicketImageRe.FindStringSubmatch(path); m != nil {
			root, rok := effectiveRoot(r)
			if !rok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			ticketID, relpath := m[1], unescape(m[2])
			p, ok := safeTicketDocIn(ticketID+"/"+relpath, root, imageExts...)
			if !ok || !exists(p) {
				http.NotFound(w, r)
				return
			}
			serveFile(w, p, mime.TypeByExtension(filepath.Ext(p)))
			return
		}
		if m := apiTicketFeatureRe.FindStringSubmatch(path); m != nil {
			root, rok := effectiveRoot(r)
			if !rok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			ticketID, relpath := m[1], unescape(m[2])
			p, ok := safeTicketDocIn(ticketID+"/"+relpath, root, ".feature")
			if !ok || !exists(p) {
				http.NotFound(w, r)
				return
			}
			data, err := os.ReadFile(p)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			sendJSON(w, map[string]string{"content": string(data)})
			return
		}
		if m := apiGitHubGetRe.FindStringSubmatch(path); m != nil || path == "/api/github/doctor" || path == "/api/github/intake" {
			// t-d271: these run git and gh, so a page on another site must not fire them blind.
			if !originOK(r.Header.Get("Origin")) || r.Header.Get("Sec-Fetch-Site") == "cross-site" {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
			groot, ok := effectiveRoot(r)
			if !ok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			if path == "/api/github/doctor" {
				sendJSON(w, githubDoctor(groot))
				return
			}
			if path == "/api/github/intake" {
				sendJSON(w, githubIntake(groot))
				return
			}
			switch m[2] {
			case "send-preview":
				sendJSON(w, runTkt(groot, []string{"send-issue", m[1], "--dry-run"}))
			case "merge":
				sendJSON(w, getMergeRunState(groot, m[1]))
			case "status":
				sendJSON(w, githubStatus(groot, m[1]))
			default:
				pr, ok := prArg(r.URL.Query().Get("pr"))
				if !ok {
					http.Error(w, "bad request", http.StatusBadRequest)
					return
				}
				sendJSON(w, runTkt(groot, append([]string{"merge-pr", m[1], "--check"}, pr...)))
			}
			return
		}
		if m := apiHeadlessRunRe.FindStringSubmatch(path); m != nil {
			sendJSON(w, getHeadlessRunState(m[1]))
			return
		}
		// t-b9a7: Skill Eval (skilleval.go).
		if path == "/api/skill-eval/status" || path == "/api/skill-eval/report" || path == "/api/skill-eval/report.html" {
			root, ok := effectiveRoot(r)
			if !ok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			raw := r.URL.Query().Get("skill_dir")
			switch path {
			case "/api/skill-eval/status":
				sendJSON(w, getSkillEvalState(root, raw))
			case "/api/skill-eval/report":
				sendJSON(w, getSkillEvalReport(root, raw))
			default:
				rep := getSkillEvalReport(root, raw)
				var body []byte
				if rep["ok"] == true {
					body, _ = os.ReadFile(rep["report_path"].(string))
				}
				if body == nil {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				// The report is generated from a user-picked skill's content: render it in an
				// opaque origin (sandbox without allow-same-origin) so it cannot reach this API.
				w.Header().Add("Content-Security-Policy", "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:")
				w.Header().Set("X-Content-Type-Options", "nosniff")
				w.Header().Set("Content-Length", strconv.Itoa(len(body)))
				w.Write(body)
			}
			return
		}
		if m := apiWorktreeLockRe.FindStringSubmatch(path); m != nil {
			root, ok := effectiveRoot(r)
			if !ok {
				http.Error(w, "unknown project", http.StatusBadRequest)
				return
			}
			sendJSON(w, worktreeLockStatus(m[1], root))
			return
		}
		if m := apiCockpitDocsRe.FindStringSubmatch(path); m != nil {
			cwd := r.URL.Query().Get("cwd")
			if cwd == "" {
				http.Error(w, "cwd required", http.StatusBadRequest)
				return
			}
			docs, ok := cockpitDocs(m[1], cwd)
			if !ok {
				http.Error(w, "cwd not a registered worktree", http.StatusBadRequest)
				return
			}
			sendJSON(w, docs)
			return
		}
		http.NotFound(w, r)
	}
}

func handlePost(w http.ResponseWriter, r *http.Request) {
	if !originOK(r.Header.Get("Origin")) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	// t-f889: Open themes folder reads no body, before the shared parse (mirrors server.py: the two parsers disagree
	// on null, NaN and UTF-16 bodies). A JSON content type is still required (a cross-site page needs a preflight).
	if path := r.URL.Path; path == "/api/themes/open" {
		if strings.ToLower(strings.TrimSpace(strings.SplitN(r.Header.Get("Content-Type"), ";", 2)[0])) != "application/json" {
			sendJSONStatus(w, map[string]any{"ok": false, "error": "expected application/json"}, http.StatusUnsupportedMediaType)
			return
		}
		res := openThemesFolder()
		status := http.StatusOK
		if ok, _ := res["ok"].(bool); !ok {
			status = http.StatusBadRequest
		}
		sendJSONStatus(w, res, status)
		return
	}
	var payload map[string]any
	body, err := io.ReadAll(r.Body)
	if err != nil || json.Unmarshal(body, &payload) != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	path := r.URL.Path
	// t-d538: git init targets an explicitly named folder — never the default by omission.
	// Handled before the shared ?project resolution so `default` (a standalone board naming
	// its own folder) isn't rejected as an unknown id. Mirrors server.py's do_POST order.
	if path == "/api/track-changes" {
		root, errMsg, ok := trackChangesRoot(r)
		if !ok {
			if errMsg == "" {
				http.Error(w, "unknown project", http.StatusBadRequest)
			} else {
				sendJSONStatus(w, map[string]any{"ok": false, "error": errMsg}, http.StatusBadRequest)
			}
			return
		}
		res := trackChanges(root, payload["confirm"])
		status := http.StatusOK
		if res["ok"] != true {
			status = http.StatusBadRequest
		}
		sendJSONStatus(w, res, status)
		return
	}
	// t-8485: project-scoped writes — resolve ?project once (400 on unknown id;
	// absent → process default). Resolved before any route (mirrors server.py's
	// do_POST ordering) so an unknown ?project 400s identically on both backends.
	// Passed to the editable-tab write fns below; /api/projects ignores it.
	eroot, erootOK := effectiveRoot(r)
	if !erootOK {
		http.Error(w, "unknown project", http.StatusBadRequest)
		return
	}
	if path == "/api/projects" {
		res := registryAdd(stringValue(payload, "path", ""), stringValue(payload, "description", ""))
		status := http.StatusOK
		if ok, _ := res["ok"].(bool); !ok {
			status = http.StatusBadRequest
		}
		sendJSONStatus(w, res, status)
		return
	}
	if path == "/api/admin/model-tiers" {
		res := saveModelTiers(payload)
		status := http.StatusOK
		if ok, _ := res["ok"].(bool); !ok {
			status = http.StatusBadRequest
		}
		sendJSONStatus(w, res, status)
		return
	}
	// t-d40b: retire (the alias and defaults move to the replacement, the old entry goes legacy) and Remove with a move.
	// t-d40b: Refresh fetches the saved sources and answers with a proposal (nothing is written); Apply writes the chosen part of it.
	// The request never carries a URL: sources come from the saved registry.
	if path == "/api/admin/model-tiers/refresh" {
		only := -1
		if f, ok := payload["index"].(float64); ok {
			only = int(f)
		}
		doc := loadModelTiers()
		res, st := refreshSources(doc, only, fetchOpts{})
		res["ok"], res["sources"] = true, st
		fresh := recordOnFresh(anySlice(doc["sources"]), st, time.Now())
		if saved := saveModelTiers(fresh); saved["ok"] == true {
			res["data"] = fresh // the registry now carries the check times
		}
		sendJSON(w, res)
		return
	}
	if path == "/api/admin/model-tiers/apply" {
		var adds []map[string]any
		for _, a := range anySlice(payload["add"]) {
			if m, ok := a.(map[string]any); ok {
				adds = append(adds, m)
			}
		}
		var pairs [][2]string
		for _, r := range anySlice(payload["retire"]) {
			if m, ok := r.(map[string]any); ok {
				pairs = append(pairs, [2]string{fmt.Sprint(m["old"]), fmt.Sprint(m["new"])})
			}
		}
		res := registryMove(func(doc map[string]any) error { return applyProposal(doc, adds, pairs) })
		status := http.StatusOK
		if ok, _ := res["ok"].(bool); !ok {
			status = http.StatusBadRequest
		}
		sendJSONStatus(w, res, status)
		return
	}
	if path == "/api/admin/model-tiers/retire" || path == "/api/admin/model-tiers/remove" {
		var res map[string]any
		if path == "/api/admin/model-tiers/retire" {
			res = registryMove(func(doc map[string]any) error {
				return retireModel(doc, fmt.Sprint(payload["old"]), fmt.Sprint(payload["new"]))
			})
		} else {
			moveTo, _ := payload["move_to"].(string)
			res = registryMove(func(doc map[string]any) error {
				return removeModel(doc, fmt.Sprint(payload["id"]), moveTo)
			})
		}
		status := http.StatusOK
		if ok, _ := res["ok"].(bool); !ok {
			status = http.StatusBadRequest
		}
		sendJSONStatus(w, res, status)
		return
	}
	// t-7485: register the fixed `sprint` skill into the tab's project. eroot is
	// the registry-resolved root (unknown id already 400'd above); the skill name
	// t-7485/t-96c3: register a canon skill into the tab's project. eroot is the
	// registry-resolved root (unknown id already 400'd above); the skill comes
	// from the client but registerSkill validates it against a fixed allowlist.
	if path == "/api/register-skill" {
		skill := r.URL.Query().Get("skill")
		if skill == "" {
			skill = stringValue(payload, "skill", "sprint")
		}
		sendJSON(w, registerSkill(eroot, skill))
		return
	}
	if m := apiTicketStatusRe.FindStringSubmatch(path); m != nil {
		if handled, st, res := writeLiveTicket(m[1], "status", payload, eroot); handled { // t-8be2: a bound ticket's fields live in its worktree
			sendJSONStatus(w, res, st)
			return
		}
		sendJSON(w, map[string]bool{"ok": writeStatus(m[1], fmt.Sprint(payload["status"]), eroot)})
		return
	}
	if m := apiTicketBodyRe.FindStringSubmatch(path); m != nil {
		if handled, st, res := writeLiveTicket(m[1], "body", payload, eroot); handled {
			sendJSONStatus(w, res, st)
			return
		}
		sendJSON(w, map[string]bool{"ok": writeBody(m[1], fmt.Sprint(payload["body"]), eroot)})
		return
	}
	if m := apiTicketVisualRe.FindStringSubmatch(path); m != nil {
		sendJSON(w, writeVisual(m[1], stringValue(payload, "filename", ""), stringValue(payload, "data", ""), eroot))
		return
	}
	if path == "/api/tags" { // t-37e8: add one tag to the project's list
		tag, _ := payload["tag"].(string)
		if err := addProjectTag(eroot, tag); err != nil {
			sendTagError(w, err)
			return
		}
		sendJSON(w, tagsAnswer(eroot))
		return
	}
	if m := apiTicketTagsRe.FindStringSubmatch(path); m != nil { // t-37e8: replace a ticket's tags
		csv, ok := tagsPayload(payload["tags"])
		if !ok {
			sendTagError(w, fmt.Errorf("tags must be a list of text"))
			return
		}
		tags, err := normalizeTags(csv)
		if err != nil {
			sendTagError(w, err)
			return
		}
		if handled, st, res := writeLiveTicket(m[1], "tags", map[string]any{"tags": tags}, eroot); handled {
			sendJSONStatus(w, res, st)
			return
		}
		if !writeTags(m[1], tags, eroot) {
			sendJSONStatus(w, map[string]any{"ok": false, "error": "that ticket was not found"}, http.StatusNotFound)
			return
		}
		sendJSON(w, map[string]any{"ok": true, "tags": tags})
		return
	}
	if m := apiTicketDemoRe.FindStringSubmatch(path); m != nil {
		if handled, st, res := writeLiveTicket(m[1], "demo", payload, eroot); handled {
			sendJSONStatus(w, res, st)
			return
		}
		sendJSON(w, map[string]bool{"ok": writeDemo(m[1], boolValue(payload["demo"]), eroot)})
		return
	}
	if m := apiDocRe.FindStringSubmatch(path); m != nil {
		doc := unescape(m[1])
		if hasDotDotSegment(doc) {
			sendJSONStatus(w, map[string]any{"ok": false, "error": "bad doc path"}, http.StatusBadRequest)
			return
		}
		if handled, st, res := writeLiveDoc(doc, payload, eroot); handled { // t-26f9: a bound ticket's docs are written in its worktree, guarded by base_hash
			sendJSONStatus(w, res, st)
			return
		}
		sendJSON(w, map[string]bool{"ok": writeDoc(doc, fmt.Sprint(payload["content"]), eroot)})
		return
	}
	if path == "/api/github/sync" {
		args := []string{"sync-issues"}
		// t-b045: the only key this route reads is "issues". Any other key (a wrong-case "Issues", say) is a bad request, never
		// a silent "no list" that would create every waiting issue.
		for k := range payload {
			if k != "issues" {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
		}
		// The dialog's ticked rows. A list that is not 1-200 positive integers is a bad request; nothing is built from it
		// but digits, and tkt still refuses a number that is not waiting.
		if v, present := payload["issues"]; present {
			nums, ok := issueNumbers(v)
			if !ok {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			args = append(args, "--only", nums)
		}
		sendJSON(w, runTkt(eroot, args))
		return
	}
	if path == "/api/github/push-main" { // t-24b1: the merged dialog's push to the canon.mirror remotes, after its confirm
		sendJSON(w, runTkt(eroot, []string{"push-main"}))
		return
	}
	if m := apiGitHubPostRe.FindStringSubmatch(path); m != nil {
		id := m[1]
		// t-718b: a write changes the stage, so the next status call must not serve the cached one: dropped before
		// (a stale hit) and after (a status read during the write cached the old stage).
		dropStatus := func() {
			mergeRunsMu.Lock()
			delete(statusCache, mergeKey{eroot, id})
			mergeRunsMu.Unlock()
		}
		dropStatus()
		defer dropStatus()
		switch m[2] {
		case "merge-stop":
			sendJSON(w, stopMergeRun(eroot, id))
			return
		case "send":
			args := []string{"send-issue", id}
			if b, _ := payload["public"].(bool); b {
				args = append(args, "--public")
			}
			sendJSON(w, runTkt(eroot, args))
			return
		case "open-pr":
			sendJSON(w, runTkt(eroot, []string{"open-pr", id}))
			return
		case "land":
			pr, ok := prArg(payload["pr"])
			if !ok {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			args := append([]string{"land", id}, pr...)
			// t-6623: finish and fix are booleans; anything else is a bad request, never a flag built from a payload.
			for _, flag := range []string{"finish", "fix"} {
				v, present := payload[flag]
				if !present {
					continue
				}
				on, isBool := v.(bool)
				if !isBool {
					http.Error(w, "bad request", http.StatusBadRequest)
					return
				}
				if on {
					args = append(args, "--"+flag)
				}
			}
			sendJSON(w, runTkt(eroot, args))
			return
		case "take-back":
			args := []string{"take-back", id}
			if b, _ := payload["close_issue"].(bool); b {
				args = append(args, "--close-issue")
			}
			sendJSON(w, runTkt(eroot, args))
			return
		}
		pr, ok := prArg(payload["pr"])
		if !ok {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if m[2] == "import" {
			sendJSON(w, runTkt(eroot, append([]string{"import-results", id}, pr...)))
			return
		}
		sendJSON(w, startMergeRun(eroot, id, pr))
		return
	}
	if m := apiHeadlessRunRe.FindStringSubmatch(path); m != nil {
		baseRef := fmt.Sprint(payload["base_ref"])
		if !baseRefRe.MatchString(baseRef) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		sendJSON(w, startHeadlessRun(m[1], baseRef))
		return
	}
	if path == "/api/skill-eval/check" {
		raw := ""
		if v, ok := payload["skill_dir"]; ok {
			raw = pyStr(v)
		}
		sendJSON(w, skillEvalCheck(eroot, raw))
		return
	}
	if path == "/api/skill-eval/run" {
		sendJSON(w, startSkillEvalRun(eroot, payload))
		return
	}
	if path == "/api/ci-workflow" {
		sendJSON(w, writeCIWorkflow())
		return
	}
	if path == "/api/cockpit" {
		sendJSON(w, ensureCockpit())
		return
	}
	if path == "/api/cockpit-restart" {
		sendJSON(w, cockpitRestart(boolValue(payload["force"])))
		return
	}
	if path == "/api/cockpit-debug" {
		sendJSON(w, cockpitSetDebug(boolValue(payload["enabled"])))
		return
	}
	if path == "/api/cockpit-interrupted-dismiss" {
		id, _ := payload["id"].(string)
		result := cockpitInterruptedDismiss(id)
		if result["ok"] != true {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(result)
			return
		}
		sendJSON(w, result)
		return
	}
	if path == "/api/cockpit-stop" {
		sendJSON(w, cockpitStop(boolValue(payload["force"])))
		return
	}
	if path == "/api/worktrees" {
		branch := stringValue(payload, "branch", "")
		if !validBranchName(branch) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		sendJSON(w, createWorktree(branch, eroot))
		return
	}
	if strings.HasPrefix(path, "/api/ticket-commit/") {
		tid := strings.TrimPrefix(path, "/api/ticket-commit/")
		if !ticketCommitIDRe.MatchString(tid) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		result, status := ticketCommit(tid, payload["paths"], eroot)
		sendJSONStatus(w, result, status)
		return
	}
	if m := apiWorktreeUnlockRe.FindStringSubmatch(path); m != nil {
		if !ticketCommitIDRe.MatchString(m[1]) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		sendJSON(w, worktreeUnlock(m[1], eroot))
		return
	}
	if path == "/api/tickets" {
		typ := stringValue(payload, "type", "task")
		body := stringValue(payload, "body", "")
		if v, ok := payload["body"]; !ok || v == nil { // absent or null: the skeleton (t-b0c9); an empty body stays empty
			body = ticketSkeleton(typ)
		}
		csv, tagsOK := tagsPayload(payload["tags"])
		newTags, tagsErr := normalizeTags(csv)
		if !tagsOK {
			tagsErr = fmt.Errorf("tags must be a list of text")
		}
		if tagsErr != nil { // t-37e8: refuse before anything is written
			sendTagError(w, tagsErr)
			return
		}
		sendJSON(w, createTicket(
			stringValue(payload, "title", "Untitled"),
			typ,
			stringValue(payload, "status", "open"),
			intValue(payload["priority"], 2),
			body,
			boolValue(payload["ci"]),
			stringValue(payload, "gate", "full"),
			boolValue(payload["demo"]),
			stringValue(payload, "skills", ""),
			stringValue(payload, "worktree_preference", ""),
			newTags,
			eroot,
		))
		return
	}
	http.NotFound(w, r)
}

func parseTicket(path string) (ticket, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := string(raw)
	t := ticket{}
	body := text
	if m := frontmatterRe.FindStringSubmatchIndex(text); m != nil {
		fm := text[m[2]:m[3]]
		for _, match := range fieldRe.FindAllStringSubmatch(fm, -1) {
			if match[1] == "priority" {
				if v, err := strconv.Atoi(strings.TrimSpace(match[2])); err == nil {
					t[match[1]] = v
					continue
				}
			}
			t[match[1]] = unquoteYAMLScalar(strings.TrimSpace(match[2]))
		}
		body = strings.TrimSpace(text[m[1]:])
	}
	title := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	if m := headingRe.FindStringSubmatch(body); m != nil {
		title = strings.TrimSpace(m[1])
	}
	if _, ok := t["title"]; !ok {
		t["title"] = title
	}
	t["body"] = body

	docs := []docInfo{}
	if filepath.Base(path) == "ticket.md" && filepath.Dir(path) != ticketsDir {
		id := fmt.Sprint(t["id"])
		if id == "" || id == "<nil>" {
			id = filepath.Base(filepath.Dir(path))
		}
		t["id"] = id
		setDefault(t, "status", "open")
		t["layout"] = "folder"
		files, _ := filepath.Glob(filepath.Join(filepath.Dir(path), "*.md"))
		sort.Strings(files)
		sort.SliceStable(files, func(i, j int) bool { return docRank(files[i]) < docRank(files[j]) })
		for _, f := range files {
			if filepath.Base(f) == "ticket.md" {
				continue
			}
			docs = append(docs, docInfo{Name: docName(f), File: filepath.ToSlash(filepath.Join(filepath.Base(filepath.Dir(path)), filepath.Base(f)))})
		}
		t["acceptance_has_items"] = nil
		t["acceptance_unchecked"] = nil
		t["models_used"] = []string{}
		if acc, err := os.ReadFile(filepath.Join(filepath.Dir(path), "acceptance.md")); err == nil {
			accText := string(acc)
			t["acceptance_has_items"] = checkboxItemRe.MatchString(section(accText, "Criteria")) && checkboxItemRe.MatchString(section(accText, "Test Plan"))
			t["acceptance_unchecked"] = uncheckedItemRe.MatchString(accText)
			t["models_used"] = modelsUsed(section(accText, "Wrapup Gates"))
		}
		t["plan_has_approach"] = nil
		t["plan_approved"] = nil
		if plan, err := os.ReadFile(filepath.Join(filepath.Dir(path), "plan.md")); err == nil {
			planText := string(plan)
			t["plan_has_approach"] = usefulText(section(planText, "Approach"))
			t["plan_approved"] = sectionHasCheckedItem(planText, "Sign-off")
		}
	} else {
		stem := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		setDefault(t, "id", stem)
		setDefault(t, "status", "open")
		t["layout"] = "flat"
		files, _ := filepath.Glob(filepath.Join(filepath.Dir(path), stem+"-*.md"))
		sort.Strings(files)
		for _, f := range files {
			name := strings.TrimPrefix(strings.TrimSuffix(filepath.Base(f), ".md"), stem+"-")
			docs = append(docs, docInfo{Name: titleCase(strings.ReplaceAll(name, "-", " ")), File: filepath.Base(f)})
		}
	}
	t["docs"] = docs
	return t, nil
}

// t-1699: /api/tickets (and every /api/doc, through liveForDocFull) re-read and re-parsed every ticket on each
// poll, so board CPU grew with the number of tickets (1124 tickets: ~77 % mean under a spec run). A parse is reused
// while the mtime and size of everything parseTicket reads are unchanged: ticket.md, acceptance.md, plan.md, and the
// folder, whose mtime moves when a doc is added, removed or renamed (the docs list). A write that keeps both mtime
// and size is missed until the next change.
type ticketCacheEntry struct {
	key string
	t   ticket
}

var ticketCache sync.Map // ticket.md path -> ticketCacheEntry

func ticketCacheKey(path string) (string, bool) {
	dir := filepath.Dir(path)
	var b strings.Builder
	for i, f := range []string{path, dir, filepath.Join(dir, "acceptance.md"), filepath.Join(dir, "plan.md")} {
		st, err := os.Stat(f)
		if err != nil {
			if i < 2 || !errors.Is(err, os.ErrNotExist) {
				return "", false // the ticket or its folder is unreadable, or a doc errs: parse fresh, cache nothing
			}
			b.WriteString("-|")
			continue
		}
		fmt.Fprintf(&b, "%d:%d|", st.ModTime().UnixNano(), st.Size())
	}
	return b.String(), true
}

// cloneTicket copies the top-level map: callers (loadTickets, the overlays) only set keys, never edit nested values.
func cloneTicket(t ticket) ticket {
	c := make(ticket, len(t)+4)
	for k, v := range t {
		c[k] = v
	}
	return c
}

func parseTicketCached(path string) (ticket, error) {
	key, ok := ticketCacheKey(path)
	if ok {
		if e, hit := ticketCache.Load(path); hit && e.(ticketCacheEntry).key == key {
			return cloneTicket(e.(ticketCacheEntry).t), nil
		}
	}
	t, err := parseTicket(path)
	if err != nil || !ok {
		ticketCache.Delete(path)
		return t, err
	}
	ticketCache.Store(path, ticketCacheEntry{key: key, t: cloneTicket(t)})
	return t, nil
}

// evictTicketCache drops entries under td whose ticket is no longer listed (deleted or moved).
func evictTicketCache(td string, listed []string) {
	keep := make(map[string]bool, len(listed))
	for _, p := range listed {
		keep[p] = true
	}
	prefix := td + string(os.PathSeparator)
	ticketCache.Range(func(k, _ any) bool {
		if p := k.(string); strings.HasPrefix(p, prefix) && !keep[p] {
			ticketCache.Delete(p)
		}
		return true
	})
}

func ticketPaths(root string) []string {
	td := ticketsDirForRoot(root)
	if st, err := os.Stat(td); err != nil || !st.IsDir() {
		return nil
	}
	var paths []string
	seen := map[string]bool{}
	filepath.WalkDir(td, func(path string, d os.DirEntry, err error) error {
		if err != nil || path == td {
			return nil
		}
		rel, _ := filepath.Rel(td, path)
		if d.IsDir() {
			if strings.Count(rel, string(os.PathSeparator)) >= 1 {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Base(path) == "ticket.md" && strings.Count(rel, string(os.PathSeparator)) == 1 {
			paths = append(paths, path)
			seen[filepath.Base(filepath.Dir(path))] = true
		}
		return nil
	})
	files, _ := filepath.Glob(filepath.Join(td, "*.md"))
	for _, f := range files {
		stem := strings.TrimSuffix(filepath.Base(f), filepath.Ext(f))
		if seen[stem] || docSuffixRe.MatchString(stem) {
			continue
		}
		paths = append(paths, f)
	}
	sort.Strings(paths)
	return paths
}

func evalFailCount(t ticket) int {
	switch v := t["eval_fail_count"].(type) {
	case int:
		return v
	case string:
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
			return n
		}
	}
	return 0
}

// typeOutcomeStats: per-type {closed, clean} counts over closed tickets. clean = eval_fail_count 0/missing.
func typeOutcomeStats(tickets []ticket) map[string]map[string]int {
	stats := map[string]map[string]int{}
	for _, t := range tickets {
		if t["status"] != "closed" {
			continue
		}
		ttype, _ := t["type"].(string)
		if ttype == "" {
			continue
		}
		entry, ok := stats[ttype]
		if !ok {
			entry = map[string]int{"closed": 0, "clean": 0}
			stats[ttype] = entry
		}
		entry["closed"]++
		if evalFailCount(t) == 0 {
			entry["clean"]++
		}
	}
	return stats
}

func loadTickets(root string) []ticket {
	// Must stay a non-nil slice — Go's encoding/json marshals a nil slice as
	// `null`, not `[]`, unlike server.py's load_tickets (always `tickets = []`);
	// the frontend's renderHeader crashes on `null.filter(...)` when zero
	// tickets exist, which aborts the whole board render (t-626d).
	tickets := []ticket{}
	paths := ticketPaths(root)
	for _, p := range paths {
		if t, err := parseTicketCached(p); err == nil {
			tickets = append(tickets, t)
		}
	}
	evictTicketCache(ticketsDirForRoot(root), paths)
	outcomeStats := typeOutcomeStats(tickets)
	for _, t := range tickets {
		status, _ := t["status"].(string)
		if status != "open" && status != "in_progress" {
			continue
		}
		ttype, _ := t["type"].(string)
		if entry, ok := outcomeStats[ttype]; ok && entry["closed"] >= 2 {
			t["type_outcome"] = entry
		}
	}
	host, _ := os.Hostname()
	annotateWorking(ticketsDirForRoot(root), tickets, time.Now(), host, pidAlive)
	headlessRunsMu.Lock()
	running := map[string]bool{}
	for id, state := range headlessRuns {
		if state["status"] == "running" {
			running[id] = true
		}
	}
	headlessRunsMu.Unlock()
	if len(running) > 0 {
		for _, t := range tickets {
			if id, ok := t["id"].(string); ok && running[id] {
				t["headless_running"] = true
			}
		}
	}
	return tickets
}

func loadHandoff(root string) map[string]any {
	hf := handoffFile
	if root != "" {
		hf = filepath.Join(root, "HANDOFF.md")
	}
	raw, err := os.ReadFile(hf)
	if err != nil {
		return map[string]any{"focus": nil, "raw": ""}
	}
	text := string(raw)
	focus := ""
	if m := currentFocusRe.FindStringSubmatch(text); m != nil {
		lines := []string{}
		for _, line := range strings.Split(strings.TrimSpace(m[1]), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "<!--") {
				lines = append(lines, line)
			}
			if len(lines) == 3 {
				break
			}
		}
		focus = strings.Join(lines, " ")
		if len(focus) > 80 {
			focus = focus[:80]
		}
	}
	var focusAny any
	if focus != "" {
		focusAny = focus
	}
	return map[string]any{"focus": focusAny, "raw": text}
}

func loadGit(root string) map[string]any {
	status := runGitIn(root, "status", "--porcelain")
	modified := 0
	for _, line := range strings.Split(status, "\n") {
		if strings.TrimSpace(line) != "" {
			modified++
		}
	}
	log := []map[string]string{}
	for _, line := range strings.Split(runGitIn(root, "log", "--oneline", "-40"), "\n") {
		parts := strings.SplitN(line, " ", 2)
		if len(parts) == 2 && !strings.HasPrefix(parts[1], "chore: auto-update handoff") && !strings.HasPrefix(parts[1], "chore: auto-handoff") {
			log = append(log, map[string]string{"hash": parts[0], "message": parts[1]})
			if len(log) == 8 {
				break
			}
		}
	}
	// t-5a4b: a project with no git has no branch — report "" rather than inventing "main".
	isGit := strings.TrimSpace(runGitIn(root, "rev-parse", "--is-inside-work-tree")) == "true"
	branch := runGitIn(root, "rev-parse", "--abbrev-ref", "HEAD")
	if branch == "" && isGit {
		branch = "main"
	}
	var totalCommits any
	if n, err := strconv.Atoi(strings.TrimSpace(runGitIn(root, "rev-list", "--count", "HEAD"))); err == nil {
		totalCommits = n
	}
	cwd := rootOr(root)
	// t-d218: parity with server.py — a repo with no commits yet has no total_commits but IS git (isGit above).
	return map[string]any{"branch": branch, "project": filepath.Base(cwd), "root": cwd, "modified": modified, "log": log, "total_commits": totalCommits, "is_git": isGit}
}

func loadCommit(hash string, root string) map[string]any {
	msg := runGitIn(root, "log", "-1", "--format=%B", hash)
	lines := strings.Split(msg, "\n")
	subject := ""
	if len(lines) > 0 {
		subject = lines[0]
	}
	body := ""
	if len(lines) > 2 {
		body = strings.TrimSpace(strings.Join(lines[2:], "\n"))
	}
	files := nonEmpty(strings.Split(runGitIn(root, "diff-tree", "--no-commit-id", "-r", "--name-only", hash), "\n"))
	related := map[string]bool{}
	for _, m := range ticketRefGroupRe.FindAllStringSubmatch(msg, -1) {
		related[m[1]] = true
	}
	for _, f := range files {
		parts := strings.Split(filepath.ToSlash(f), "/")
		if len(parts) >= 2 && parts[0] == ".tickets" {
			related[strings.TrimSuffix(filepath.Base(f), ".md")] = true
		}
	}
	return map[string]any{"hash": hash, "subject": subject, "body": body, "author": runGitIn(root, "log", "-1", "--format=%an", hash), "date": firstN(runGitIn(root, "log", "-1", "--format=%ci", hash), 10), "files": files, "related_ticket_ids": sortedKeys(related)}
}

func basenameCandidates(basename string, root string) []string {
	out := runGitIn(root, "log", "--all", "--name-only", "--format=")
	seen := map[string]bool{}
	for _, line := range nonEmpty(strings.Split(out, "\n")) {
		if filepath.Base(line) == basename {
			seen[line] = true
		}
	}
	return sortedKeys(seen)
}

func loadWhy(file string, root string) map[string]any {
	target := strings.TrimSpace(file)
	if target == "" {
		return map[string]any{"file": "", "results": []any{}, "message": "Enter a file path."}
	}
	if filepath.IsAbs(target) || strings.Contains(filepath.ToSlash(target), "../") {
		return map[string]any{"file": target, "results": []any{}, "message": "Use a project-relative file path."}
	}
	queryTarget := target
	subjects := runGitIn(root, "log", "--follow", "--format=%s", "--", queryTarget)
	var resolvedPath string
	var alternatives []string
	if subjects == "" {
		basename := filepath.Base(target)
		candidates := []string{}
		if basename != "" && basename != "." {
			candidates = basenameCandidates(basename, root)
		}
		if len(candidates) == 1 {
			queryTarget = candidates[0]
			resolvedPath = queryTarget
			subjects = runGitIn(root, "log", "--follow", "--format=%s", "--", queryTarget)
		} else if len(candidates) > 1 {
			type ranked struct {
				count int
				path  string
			}
			var items []ranked
			for _, c := range candidates {
				out := runGitIn(root, "log", "--oneline", "--", c)
				n := 0
				if out != "" {
					n = len(strings.Split(strings.TrimSpace(out), "\n"))
				}
				items = append(items, ranked{n, c})
			}
			sort.Slice(items, func(i, j int) bool { return items[i].count > items[j].count })
			queryTarget = items[0].path
			resolvedPath = queryTarget
			for i, item := range items[1:] {
				if i >= 5 {
					break
				}
				alternatives = append(alternatives, item.path)
			}
			subjects = runGitIn(root, "log", "--follow", "--format=%s", "--", queryTarget)
		}
	}
	if subjects == "" {
		return map[string]any{"file": target, "results": []any{}, "message": "No git history found for " + target + "."}
	}
	known := map[string]bool{}
	byID := map[string]ticket{}
	byPath := map[string]string{}
	for _, p := range ticketPaths(root) {
		if t, err := parseTicket(p); err == nil {
			id := fmt.Sprint(t["id"])
			known[id] = true
			byID[id] = t
			byPath[id] = p
		}
	}
	ids := []string{}
	seen := map[string]bool{}
	for _, m := range ticketRefRe.FindAllString(subjects, -1) {
		if known[m] && !seen[m] {
			ids = append(ids, m)
			seen[m] = true
		}
	}
	if len(ids) == 0 {
		stop := map[string]bool{
			"update": true, "change": true, "changed": true, "refact": true,
			"clean": true, "minor": true, "patch": true, "revert": true,
			"merge": true, "commit": true, "sprint": true, "feature": true,
			"implement": true, "style": true, "docs": true, "chore": true,
			"ticket": true, "tickets": true,
		}
		words := keywordSet(subjects, stop)
		type score struct {
			value float64
			id    string
		}
		var scored []score
		if len(words) > 0 {
			for id, t := range byID {
				titleWords := keywordSet(fmt.Sprint(t["title"]), stop)
				hits := 0
				for word := range words {
					if titleWords[word] {
						hits++
					}
				}
				if hits > 0 {
					denom := len(titleWords)
					if denom == 0 {
						denom = 1
					}
					scored = append(scored, score{value: float64(hits) / float64(denom), id: id})
				}
			}
		}
		sort.Slice(scored, func(i, j int) bool {
			if scored[i].value == scored[j].value {
				return scored[i].id > scored[j].id
			}
			return scored[i].value > scored[j].value
		})
		for i, item := range scored {
			if i == 5 {
				break
			}
			ids = append(ids, item.id)
		}
	}
	capped, more := capWithMore(ids, 10)
	results := []map[string]any{}
	for _, id := range capped {
		t := byID[id]
		results = append(results, map[string]any{"id": id, "status": t["status"], "title": t["title"], "decision": planDecision(byPath[id])})
	}
	msg := ""
	if len(results) == 0 {
		msg = "No tickets found for " + target + "."
	}
	_, statErr := os.Stat(filepath.Join(projectRoot, queryTarget))
	result := map[string]any{"file": target, "results": results, "more": more, "file_exists": statErr == nil, "message": msg}
	if resolvedPath != "" {
		result["resolved_path"] = resolvedPath
	}
	if len(alternatives) > 0 {
		result["alternatives"] = alternatives
	}
	return result
}

// capWithMore truncates items to maxN, assuming items is already in the
// desired display order (e.g. most-recent-first) — this only truncates,
// never re-sorts. Returns (capped_items, more_count).
func capWithMore(items []string, maxN int) ([]string, int) {
	if len(items) <= maxN {
		return items, 0
	}
	return items[:maxN], len(items) - maxN
}

func writeStatus(id, status string, root string) bool {
	from := ""
	ok := replaceTicket(id, root, func(text string) string {
		if m := statusFieldRe.FindStringSubmatch(text); m != nil {
			from = m[2]
		}
		return statusFieldRe.ReplaceAllString(text, "${1}"+status)
	})
	if ok {
		updateActive(canonicalTicketID(id, root), status, root)
		emitStatusChanged(canonicalTicketID(id, root), from, status, root)
	}
	return ok
}

// emitEvent records one event (t-f182) after the write it describes succeeded. Observer-only: the result is ignored.
func emitEvent(kind, root string, data map[string]string) {
	abs, err := filepath.Abs(root) // a relative root ("." in tests) would resolve to itself
	if err != nil {
		abs = root
	}
	events.Emit(events.Home(), kind, "board", resolvedOrAbs(abs), data)
}

// emitStatusChanged records a status move, and ticket.closed as well when it moves to closed.
func emitStatusChanged(id, from, to, root string) {
	emitEvent("ticket.status_changed", root, map[string]string{"ticket": id, "from": from, "to": to})
	if to == "closed" {
		emitEvent("ticket.closed", root, map[string]string{"ticket": id})
	}
}

// writeDemo toggles the boolean `demo` frontmatter field on an existing ticket. ON ensures a
// `demo: true` line (appended as the last frontmatter field); OFF removes any `demo:` line
// (absent = false, matching `tkt demo`). Returns true if the ticket exists (idempotent).
// t-64a0: the byte layout is pinned by tests/sprint-check-api.sh.
func writeDemo(id string, want bool, root string) bool {
	path := findTicketPath(id, root)
	if path == "" {
		return false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	text := string(raw)
	m := frontmatterRe.FindStringSubmatchIndex(text)
	if m == nil {
		return false
	}
	var kept []string
	for _, ln := range strings.Split(text[m[2]:m[3]], "\n") {
		if strings.HasPrefix(ln, "demo:") {
			continue
		}
		kept = append(kept, ln)
	}
	if want {
		kept = append(kept, "demo: true")
	}
	updated := "---\n" + strings.Join(kept, "\n") + "\n---\n" + text[m[1]:]
	if updated != text {
		if err := os.WriteFile(path, []byte(updated), 0644); err != nil {
			return false
		}
	}
	return true
}

func canonicalTicketID(id string, root string) string {
	if p := findTicketPath(id, root); p != "" {
		if t, err := parseTicket(p); err == nil {
			if canonical, ok := t["id"]; ok {
				return fmt.Sprint(canonical)
			}
		}
	}
	return id
}

// updateActive mirrors tkt's set_active/clear_active_if: in_progress claims
// ACTIVE, any other status clears it if this ticket currently holds it.
func updateActive(canonicalID, status string, root string) {
	activePath := filepath.Join(ticketsDirForRoot(root), "ACTIVE")
	if status == "in_progress" {
		os.WriteFile(activePath, []byte(canonicalID+"\n"), 0644)
		return
	}
	if raw, err := os.ReadFile(activePath); err == nil {
		if strings.TrimSpace(string(raw)) == canonicalID {
			os.Remove(activePath)
		}
	}
}

func writeBody(id, body string, root string) bool {
	return replaceTicket(id, root, func(text string) string {
		if m := frontmatterRe.FindStringIndex(text); m != nil {
			return text[:m[1]] + strings.TrimSpace(body) + "\n"
		}
		return strings.TrimSpace(body) + "\n"
	})
}

func writeDoc(docFile, content string, root string) bool {
	p, ok := safeTicketDoc2(docFile, root)
	if !ok {
		var legacyOK bool
		p, legacyOK = legacyDocTarget(docFile, root)
		if !legacyOK {
			return false
		}
	}
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		return false
	}
	return os.WriteFile(p, []byte(strings.TrimSpace(content)+"\n"), 0644) == nil
}

// t-626d: behaviour pinned by tests/sprint-check-api.sh.
const maxVisualBytes = 8 * 1024 * 1024

// dedupeVisualName returns a collision-free filename under .tickets/<id>/visuals/,
// auto-suffixing before the extension (never overwrites). "" if filename is unsafe.
func dedupeVisualName(ticketID, filename string, root string) string {
	ext := strings.ToLower(filepath.Ext(filename))
	stem := strings.TrimSuffix(filename, filepath.Ext(filename))
	extOK := false
	for _, e := range imageExts {
		if ext == e {
			extOK = true
			break
		}
	}
	if !safeVisualName.MatchString(filename) || !extOK {
		return ""
	}
	candidate := filename
	for n := 2; ; n++ {
		target, ok := safeTicketDocIn(ticketID+"/visuals/"+candidate, root, imageExts...)
		if !ok {
			return ""
		}
		if !exists(target) {
			return candidate
		}
		candidate = fmt.Sprintf("%s-%d%s", stem, n, ext)
	}
}

// writeVisual decodes a base64-encoded image and writes it to
// .tickets/<id>/visuals/, auto-suffixing on filename collision.
func writeVisual(ticketID, filename, dataB64 string, root string) map[string]any {
	raw, err := base64.StdEncoding.DecodeString(dataB64)
	if err != nil || len(raw) == 0 || len(raw) > maxVisualBytes {
		return map[string]any{"ok": false}
	}
	name := dedupeVisualName(ticketID, filename, root)
	if name == "" {
		return map[string]any{"ok": false}
	}
	target, ok := safeTicketDocIn(ticketID+"/visuals/"+name, root, imageExts...)
	if !ok {
		return map[string]any{"ok": false}
	}
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return map[string]any{"ok": false}
	}
	if os.WriteFile(target, raw, 0644) != nil {
		return map[string]any{"ok": false}
	}
	return map[string]any{"ok": true, "filename": name}
}

// t-b0c9: the intent skeleton a ticket starts with when a create request carries no body. Same text as tools/tkt
// ticket_skeleton and the board's TYPE_TEMPLATES; tests/ticket-skeleton.sh keeps the three identical.
const skeletonRest = "## Outcome\n<!-- What is true when this is done? -->\n\n" +
	"## Constraints\n<!-- Limits the solution must respect. -->\n\n" +
	"## Open questions\n<!-- Anything to decide before planning. The plan answers or carries forward each one. -->\n"

func ticketSkeleton(typ string) string {
	if typ == "bug" {
		return "## Problem\n<!-- What is broken, and for whom? -->\n\n## Expected\n<!-- What should happen. -->\n\n" +
			"## Actual\n<!-- What happens instead, and the steps to see it. -->\n\n" + skeletonRest
	}
	return "## Problem\n<!-- What is wrong or missing, and for whom? -->\n\n" + skeletonRest
}

func createTicket(title, typ, status string, priority int, body string, ci bool, gate string, demo bool, skills string, worktreePreference string, tags []string, root string) ticket {
	td := ticketsDirForRoot(root)
	os.MkdirAll(td, 0755)
	existing := map[string]bool{}
	for _, p := range ticketPaths(root) {
		stem := strings.TrimSuffix(filepath.Base(p), filepath.Ext(p))
		existing[stem] = true
		if filepath.Base(p) == "ticket.md" {
			existing[filepath.Base(filepath.Dir(p))] = true
		}
	}
	if entries, err := os.ReadDir(td); err == nil {
		for _, entry := range entries {
			if entry.IsDir() {
				existing[entry.Name()] = true
			}
		}
	}
	id := "t-" + randomID(4)
	for {
		if !existing[id] {
			break
		}
		id = "t-" + randomID(4)
	}
	title = strings.TrimSpace(strings.ReplaceAll(title, "\n", " "))
	if title == "" || title == "<nil>" {
		title = "Untitled"
	}
	if typ == "" || typ == "<nil>" {
		typ = "task"
	}
	if status == "" || status == "<nil>" {
		status = "open"
	}
	dir := filepath.Join(td, id)
	os.MkdirAll(dir, 0755)
	ciLine := ""
	if ci {
		ciLine = "ci: true\n"
	}
	gateLine := ""
	if strings.ToLower(gate) == "eval" {
		gateLine = "gate: eval\n"
	}
	demoLine := ""
	if demo {
		demoLine = "demo: true\n"
	}
	// t-354b: maintenance skills (chore multi-select) — csv, allowlisted to the
	// three repo-hygiene skills (parity with server.py create_ticket). Order-
	// preserving dedupe; absent line = none (same present/absent convention).
	skillsLine := ""
	{
		allowed := map[string]bool{"context-check": true, "context-doctor": true, "dead-code-cleanup": true}
		seen := map[string]bool{}
		var picked []string
		for _, s := range strings.Split(skills, ",") {
			s = strings.TrimSpace(s)
			if allowed[s] && !seen[s] {
				seen[s] = true
				picked = append(picked, s)
			}
		}
		if len(picked) > 0 {
			skillsLine = "skills: " + strings.Join(picked, ",") + "\n"
		}
	}
	// t-644a: a declared worktree preference, applied only later at first
	// Start (see renderCockpitWorktree's pre-fill) -- present/absent
	// convention, parity with server.py's create_ticket.
	wtLine := ""
	if wt := strings.TrimSpace(strings.ReplaceAll(worktreePreference, "\n", " ")); wt != "" {
		wtLine = "worktree_preference: " + wt + "\n"
	}
	tagsLine := ""
	if l := tagsFrontmatterLine(tags); l != "" { // t-37e8: already validated by the caller (normalizeTags)
		tagsLine = l + "\n"
	}
	evalLine := "eval_override: false"
	text := fmt.Sprintf("---\nid: %s\ntitle: %s\nstatus: %s\ntype: %s\npriority: %d\ncreated: %s\n%s%s%s%s%s%s%s\n---\n\n%s\n", id, strings.ReplaceAll(title, "\n", " "), status, typ, priority, time.Now().UTC().Format("2006-01-02T15:04:05Z"), ciLine, gateLine, demoLine, skillsLine, wtLine, tagsLine, evalLine, strings.TrimSpace(body))
	path := filepath.Join(dir, "ticket.md")
	if os.WriteFile(path, []byte(text), 0644) == nil {
		emitEvent("ticket.created", root, map[string]string{"ticket": id, "title": title, "type": typ, "priority": strconv.Itoa(priority)})
	}
	t, _ := parseTicket(path)
	return t
}

// canonRefPlaceholder in canon-gate-template.yml becomes v<VERSION> when the board writes the workflow (t-04f4).
const canonRefPlaceholder = "__CANON_REF__"

// releaseVersionRe is a release VERSION: exactly x.y.z, the form canon-skills tags as v<x.y.z>.
var releaseVersionRe = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

// writeCIWorkflow copies the shipped canon-gate workflow template to the
// project's .github/workflows/canon-gate.yml. Fixed target path (no traversal);
// refuses rather than clobbering an existing workflow. Mirror of server.py's
// write_ci_workflow.
func writeCIWorkflow() map[string]any {
	rel := ".github/workflows/canon-gate.yml"
	dest := filepath.Join(projectRoot, ".github", "workflows", "canon-gate.yml")
	if _, err := os.Stat(dest); err == nil {
		return map[string]any{"ok": false, "reason": "exists", "path": rel}
	}
	data, err := os.ReadFile(canonGateTmpl)
	if err != nil {
		return map[string]any{"ok": false, "reason": err.Error(), "path": rel}
	}
	// t-04f4: the workflow checks canon out at the release tag of this install, never a moving branch.
	ver := canonVersion()
	if !releaseVersionRe.MatchString(ver) {
		return map[string]any{"ok": false, "reason": "this canon has no release version (" + ver + "), so the workflow cannot pin canon; run Set up CI gate from a released install", "path": rel}
	}
	if n := strings.Count(string(data), canonRefPlaceholder); n != 1 {
		return map[string]any{"ok": false, "reason": fmt.Sprintf("the canon-gate template has %d %s placeholders, want 1", n, canonRefPlaceholder), "path": rel}
	}
	data = []byte(strings.Replace(string(data), canonRefPlaceholder, "v"+ver, 1))
	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return map[string]any{"ok": false, "reason": err.Error(), "path": rel}
	}
	if err := os.WriteFile(dest, data, 0644); err != nil {
		return map[string]any{"ok": false, "reason": err.Error(), "path": rel}
	}
	return map[string]any{"ok": true, "path": rel}
}

func replaceTicket(id string, root string, fn func(string) string) bool {
	path := findTicketPath(id, root)
	if path == "" {
		return false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	next := fn(string(raw))
	if next == string(raw) {
		return false
	}
	return os.WriteFile(path, []byte(next), 0644) == nil
}

func findTicketPath(id string, root string) string {
	td := ticketsDirForRoot(root)
	candidates := []string{filepath.Join(td, id, "ticket.md"), filepath.Join(td, id+".md")}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	for _, p := range ticketPaths(root) {
		if t, err := parseTicket(p); err == nil && fmt.Sprint(t["id"]) == id {
			return p
		}
	}
	return ""
}

// readDocWithEtag also returns the etag a write must echo back as base_hash. For a bound ticket it describes the
// WORKTREE file (sha256 of its bytes, or "absent"), even when the text shown falls back to main's copy, so saving
// an edit of a doc the worktree does not have yet works; "" means the doc is not writable from the board.
func readDocWithEtag(docFile string, root string) (string, string, bool) {
	dir, _, wtPath, live := liveForDocFull(docFile, root)
	if live && !liveSafe(strings.SplitN(filepath.ToSlash(docFile), "/", 2)[0], dir, wtPath) {
		live = false // t-8be2: never read through a linked ticket folder; a write to it is refused on its own
	}
	etag := ""
	if live {
		if target, derr := liveDocTargetFrom(docFile, dir, wtPath); derr == nil {
			if e, err := liveDocEtagOf(target); err == nil {
				etag = e
			}
		}
	}
	// t-e78b: a worktree-bound ticket's docs come from that worktree's copy.
	if live {
		clean := filepath.Clean(filepath.FromSlash(docFile))
		if !filepath.IsAbs(clean) && !strings.HasPrefix(clean, "..") && strings.ToLower(filepath.Ext(clean)) == ".md" {
			if target, err := filepath.EvalSymlinks(filepath.Join(filepath.Dir(dir), clean)); err == nil {
				if rel, err := filepath.Rel(dir, target); err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
					if raw, err := os.ReadFile(target); err == nil {
						return string(raw), etag, true
					}
				}
			}
		}
	}
	p, ok := safeTicketDoc2(docFile, root)
	if !ok || !exists(p) {
		if legacy, legacyOK := legacyDocTarget(docFile, root); legacyOK {
			p = legacy
		} else {
			return "", "", false
		}
	}
	raw, err := os.ReadFile(p)
	if !live {
		etag = docEtag(raw)
	}
	return string(raw), etag, err == nil
}

// hasDotDotSegment: a decoded doc path with a ".." segment (t-8020). Go's router used to answer such a path with a 301 to the
// cleaned one before a handler saw it, but only under the pre-1.22 router a build without a go.mod gets; a module build
// (every release) passes `t-x/..%2Fplan.md` through, so the doc routes refuse it themselves.
func hasDotDotSegment(doc string) bool {
	for _, seg := range strings.Split(strings.ReplaceAll(doc, "\\", "/"), "/") {
		if seg == ".." {
			return true
		}
	}
	return false
}

// Behaviour pinned by tests/sprint-check-api.sh: re-run it after a change.
func safeTicketDoc2(docFile string, root string) (string, bool) {
	return safeTicketDocIn(docFile, root)
}

func safeTicketDocIn(docFile string, root string, exts ...string) (string, bool) {
	td := ticketsDirForRoot(root)
	if len(exts) == 0 {
		exts = []string{".md"}
	}
	clean := filepath.Clean(filepath.FromSlash(docFile))
	ext := strings.ToLower(filepath.Ext(clean))
	extOK := false
	for _, e := range exts {
		if ext == e {
			extOK = true
			break
		}
	}
	if filepath.IsAbs(clean) || strings.HasPrefix(clean, ".."+string(os.PathSeparator)) || !extOK {
		return "", false
	}
	p := filepath.Join(td, clean)
	rel, err := filepath.Rel(td, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", false
	}
	if !containedAfterSymlinksIn(p, td) {
		return "", false
	}
	return p, true
}

// containedAfterSymlinks resolves symlinks on the deepest existing ancestor
// of p (walking upward past any not-yet-created components — an EXISTING
// intermediate directory further up the chain could be a symlink, so a
// single-level parent check is not enough) and confirms the result still
// lies within ticketsDir. This is the Go equivalent of Python's
// Path.resolve(strict=False)-based containment check.
//
// Resolution failure is ALWAYS treated as unsafe (reject), never as "nothing
// to escape through" — that includes a dangling symlink at the leaf itself
// (Lstat succeeds on the symlink, but EvalSymlinks fails because its target
// doesn't exist): an attacker-planted dangling symlink pointing outside
// ticketsDir must not be treated as safe just because its target is missing
// *right now* — os.WriteFile on such a path creates the target on write,
// landing outside ticketsDir. The walk-up only exists so a legitimately
// not-yet-created leaf (and its not-yet-created parent directories) doesn't
// spuriously fail; it always bottoms out at an existing entity — worst case
// ticketsDir itself, which always exists in practice — so EvalSymlinks on
// whatever the walk finds should never fail for a legitimate write.
func containedAfterSymlinksIn(p string, td string) bool {
	target := p
	for {
		if _, err := os.Lstat(target); err == nil {
			break
		}
		parent := filepath.Dir(target)
		if parent == target {
			break // reached filesystem root without finding anything that exists
		}
		target = parent
	}
	resolved, err := filepath.EvalSymlinks(target)
	if err != nil {
		return false // exists per Lstat but can't be resolved — reject, never assume safe
	}
	root, err := filepath.EvalSymlinks(td)
	if err != nil {
		root = td
	}
	rel, err := filepath.Rel(root, resolved)
	return err == nil && !strings.HasPrefix(rel, "..")
}

func legacyDocTarget(docFile string, root string) (string, bool) {
	td := ticketsDirForRoot(root)
	safe := filepath.Base(filepath.FromSlash(docFile))
	if filepath.Ext(safe) != ".md" {
		return "", false
	}
	if m := ticketDocNameRe.FindStringSubmatch(safe); m != nil {
		folderTicket := filepath.Join(td, m[1], "ticket.md")
		if exists(folderTicket) {
			return filepath.Join(td, m[1], m[2]+".md"), true
		}
	}
	return filepath.Join(td, safe), true
}

// t-1699: compiled once at start-up, not on every request or ticket line.
var (
	apiProjectRe        = regexp.MustCompile(`^/api/projects/([0-9a-f]{12})$`)
	screenshotPathRe    = regexp.MustCompile(`^/meta/screenshots/[A-Za-z0-9_-]+\.(png|gif|jpg|jpeg|webp)$`)
	apiCommitRe         = regexp.MustCompile(`^/api/commit/([0-9a-f]{4,40})$`)
	apiDocRe            = regexp.MustCompile(`^/api/doc/(.+)$`)
	apiTicketImageRe    = regexp.MustCompile(`^/api/ticket-image/(t-[a-z0-9]{4})/(.+)$`)
	apiTicketFeatureRe  = regexp.MustCompile(`^/api/ticket-feature/(t-[a-z0-9]{4})/(.+)$`)
	apiGitHubGetRe      = regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/github/(send-preview|merge-check|merge|status)$`)
	apiHeadlessRunRe    = regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/headless-run$`)
	apiWorktreeLockRe   = regexp.MustCompile(`^/api/worktree-lock/(t-[a-z0-9]{4})$`)
	apiCockpitDocsRe    = regexp.MustCompile(`^/api/cockpit-docs/(t-[a-z0-9]{4})$`)
	apiTicketStatusRe   = regexp.MustCompile(`^/api/ticket/([^/]+)/status$`)
	apiTicketBodyRe     = regexp.MustCompile(`^/api/ticket/([^/]+)/body$`)
	apiTicketVisualRe   = regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/visual$`)
	apiTicketDemoRe     = regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/demo$`)
	apiTicketTagsRe     = regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/tags$`)
	apiGitHubPostRe     = regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/github/(send|import|merge|merge-stop|take-back|open-pr|land)$`)
	apiWorktreeUnlockRe = regexp.MustCompile(`^/api/worktree-unlock/([^/]+)$`)
	checkboxItemRe      = regexp.MustCompile(`(?m)^\s*[-*]\s+\[[ xX]\]\s+\S`)
	uncheckedItemRe     = regexp.MustCompile(`(?m)^\s*[-*]\s+\[ \]\s+\S`)
	docSuffixRe         = regexp.MustCompile(`^.+-(blueprint|acceptance|plan|decisions|qa|notes)$`)
	currentFocusRe      = regexp.MustCompile(`(?s)##\s+Current Focus\s*\n+(.+?)(?:\n##|\z)`)
	ticketRefGroupRe    = regexp.MustCompile(`\b([A-Za-z]+-[a-z0-9]{3,})\b`)
	ticketRefRe         = regexp.MustCompile(`\b[A-Za-z]+-[a-z0-9]{3,}\b`)
	statusFieldRe       = regexp.MustCompile(`(?m)^(status:\s*)(\S+)$`)
	ticketDocNameRe     = regexp.MustCompile(`^([A-Za-z]+-[A-Za-z0-9]+)-(.+)\.md$`)
	htmlCommentRe       = regexp.MustCompile(`(?s)<!--.*?-->`)
	checkedItemRe       = regexp.MustCompile(`(?m)^\s*[-*]\s+\[[xX]\]\s+\S`)
	decisionsSectionRe  = regexp.MustCompile(`(?ms)^##\s+Decisions\s*$([\s\S]*)`)
	wordRe              = regexp.MustCompile(`[a-z]{4,}`)
	pathSepRe           = regexp.MustCompile(`[\\/]+`)
)

// headingLineRes caches section()'s `^##\s+<heading>\s*$` per heading: callers pass a handful of constant headings.
var headingLineRes sync.Map

func headingLineRe(heading string) *regexp.Regexp {
	if re, ok := headingLineRes.Load(heading); ok {
		return re.(*regexp.Regexp)
	}
	re, _ := headingLineRes.LoadOrStore(heading, regexp.MustCompile(`^##\s+`+regexp.QuoteMeta(heading)+`\s*$`))
	return re.(*regexp.Regexp)
}

func section(text, heading string) string {
	lines := strings.Split(text, "\n")
	active := false
	var out []string
	headingRe := headingLineRe(heading)
	for _, line := range lines {
		if headingRe.MatchString(line) {
			active = true
			continue
		}
		if active && strings.HasPrefix(line, "## ") {
			break
		}
		if active {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

func usefulText(text string) bool {
	text = htmlCommentRe.ReplaceAllString(text, "")
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) != "" {
			return true
		}
	}
	return false
}

func sectionHasCheckedItem(text, heading string) bool {
	return checkedItemRe.MatchString(section(text, heading))
}

func modelsUsed(acceptanceText string) []string {
	seen := []string{}
	seenSet := map[string]bool{}
	for _, m := range modelMentionRe.FindAllStringSubmatch(acceptanceText, -1) {
		name := strings.ToLower(strings.TrimSpace(m[1]))
		if name != "" && !seenSet[name] {
			seenSet[name] = true
			seen = append(seen, name)
		}
	}
	return seen
}

func unquoteYAMLScalar(value string) string {
	if len(value) >= 2 && value[0] == value[len(value)-1] && (value[0] == '"' || value[0] == '\'') {
		return value[1 : len(value)-1]
	}
	return value
}

func planDecision(ticketPath string) string {
	if ticketPath == "" {
		return ""
	}
	planPath := ""
	if filepath.Base(ticketPath) == "ticket.md" {
		planPath = filepath.Join(filepath.Dir(ticketPath), "plan.md")
	} else {
		stem := strings.TrimSuffix(filepath.Base(ticketPath), filepath.Ext(ticketPath))
		planPath = filepath.Join(filepath.Dir(ticketPath), stem+"-plan.md")
	}
	raw, err := os.ReadFile(planPath)
	if err != nil {
		return ""
	}
	m := decisionsSectionRe.FindStringSubmatch(string(raw))
	if m == nil {
		return ""
	}
	for _, line := range strings.Split(m[1], "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "### ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "### "))
		}
	}
	return ""
}

func keywordSet(text string, stop map[string]bool) map[string]bool {
	words := map[string]bool{}
	for _, word := range wordRe.FindAllString(strings.ToLower(text), -1) {
		if !stop[word] {
			words[word] = true
		}
	}
	return words
}

func findProjectRoot(start string) string {
	dir, _ := filepath.Abs(start)
	startAbs := dir
	home, _ := os.UserHomeDir()
	for {
		// t-5738/t-dec4: a .tickets in a drive root or system folder, or in home when the walk did not start there, is not this project's;
		// skip it, as tickets_dir does
		if exists(filepath.Join(dir, ".git")) || (exists(filepath.Join(dir, ".tickets")) && !common.SkipTickets(dir, start, home)) {
			return dir
		}
		// t-dec4: a folder under home is its own project, so the walk stops at home; nothing above it can be its project
		if dir != startAbs && common.IsHome(dir, home) {
			return start
		}
		next := filepath.Dir(dir)
		if next == dir {
			return start
		}
		dir = next
	}
}

func openBrowser(u string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	case "darwin":
		cmd = exec.Command("open", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	_ = cmd.Start()
}

// t-cd06: the worktree list/create API, pinned by tests/sprint-check-worktrees.sh and tests/sprint-check-api.sh.

func validBranchName(name string) bool {
	return name != "" && baseRefRe.MatchString(name) && !strings.HasPrefix(name, "-") && !strings.Contains(name, "..")
}

// ── Branch/worktree status divergence (t-6328) — mirrors server.py ─────────
var (
	grepStatusRe = regexp.MustCompile(`^\.tickets/([^/]+)/ticket\.md:status:\s*(.+?)\s*$`)
	fmStatusRe   = regexp.MustCompile(`(?m)^status:\s*(.+?)\s*$`)
)

// The board shows the served checkout's copy of each ticket.md; where `.tickets/`
// is tracked, a live worktree or unmerged branch can hold a different status.
// Read-only, bounded (branch cap) and TTL-cached: /api/tickets is the hottest route.
const (
	divergenceBranchCap   = 8
	divergenceWorktreeCap = 8
)

type divergenceCand struct {
	branch, status, where string
	merged, dirty         bool
}

type divergenceCacheEntry struct {
	expires time.Time
	scan    map[string][]divergenceCand
}

var (
	divergenceCache   = map[string]divergenceCacheEntry{}
	divergenceCacheMu sync.Mutex
)

func divergenceTTL() time.Duration {
	if v := os.Getenv("SPRINT_CHECK_DIVERGENCE_TTL"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			if f < 0 {
				f = 0
			}
			return time.Duration(f * float64(time.Second))
		}
	}
	return 10 * time.Second
}

// gitCtx runs git with a 5s bound (server.py's run() uses the same timeout).
func gitCtx(root string, args ...string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = rootOr(root)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err == nil
}

func frontmatterStatus(text string) string {
	m := frontmatterRe.FindStringSubmatch(text)
	if m == nil {
		return ""
	}
	sm := fmStatusRe.FindStringSubmatch(m[1])
	if sm == nil {
		return ""
	}
	return unquoteYAMLScalar(sm[1])
}

var changedTicketRe = regexp.MustCompile(`^\.tickets/([^/]+)/ticket\.md$`)

// changedTicketIDs returns the ticket ids named by `git diff --name-only` lines.
func changedTicketIDs(diffOut string, ids map[string]bool) map[string]bool {
	out := map[string]bool{}
	for _, line := range strings.Split(diffOut, "\n") {
		if m := changedTicketRe.FindStringSubmatch(strings.TrimSpace(line)); m != nil && ids[m[1]] {
			out[m[1]] = true
		}
	}
	return out
}

// scanTicketSafe: the scan may read <worktree>/.tickets/<id>/ticket.md only when it is a plain file in plain folders
// (the t-8be2 liveSafe check); a resolve error counts as not safe. t-9c87.
func scanTicketSafe(wt, id string) bool {
	real, err := filepath.EvalSymlinks(wt)
	if err != nil {
		return false
	}
	return liveSafe(id, filepath.Join(real, ".tickets", id), wt) // liveTargetFrom's Lstat sees a junction (ModeIrregular)
}

// scanOtherCheckouts returns statuses for every live non-main worktree and every
// unmerged local branch (no worktree) that itself CHANGED a ticket since its fork
// point from HEAD — an older branch also holds stale copies of tickets that have
// since advanced on main, which is not a divergence worth flagging.
func scanOtherCheckouts(root string, ids map[string]bool) map[string][]divergenceCand {
	out := map[string][]divergenceCand{}
	if inside, _ := gitCtx(root, "rev-parse", "--is-inside-work-tree"); inside == "" {
		return out
	}
	if ignored, _ := gitCtx(root, "check-ignore", ".tickets"); ignored != "" {
		return out // untracked tickets: no other checkout can carry a different copy
	}
	seenBranches := map[string]bool{}
	scannedWorktrees := 0
	for _, e := range listWorktreesBase("", root) {
		if isMain, _ := e["is_main"].(bool); isMain {
			continue
		}
		if scannedWorktrees >= divergenceWorktreeCap {
			break
		}
		scannedWorktrees++
		head, _ := e["head"].(string)
		branch, _ := e["branch"].(string)
		seenBranches[branch] = true
		if branch == "" {
			branch = "(detached)"
			if len(head) >= 7 {
				branch = head[:7]
			}
		}
		tdir := filepath.Join(fmt.Sprint(e["path"]), ".tickets")
		if head == "" {
			continue
		}
		base, _ := gitCtx(root, "merge-base", "HEAD", head)
		if base == "" {
			continue
		}
		// base vs the WORKING TREE, so an uncommitted status edit counts too.
		diffOut, _ := gitCtx(fmt.Sprint(e["path"]), "diff", "--name-only", base, "--", ".tickets/*/ticket.md")
		_, merged := gitCtx(root, "merge-base", "--is-ancestor", head, "HEAD")
		// t-2241: uncommitted (non-runtime) work means "not merged" in any honest sense.
		dirty := worktreeDirty(fmt.Sprint(e["path"]))
		names := []string{}
		for id := range changedTicketIDs(diffOut, ids) {
			names = append(names, id)
		}
		sort.Strings(names)
		for _, id := range names {
			if !scanTicketSafe(fmt.Sprint(e["path"]), id) {
				continue // t-9c87: never read a status through a link or junction an agent made in the worktree
			}
			raw, err := os.ReadFile(filepath.Join(tdir, id, "ticket.md"))
			if err != nil {
				continue
			}
			if st := frontmatterStatus(string(raw)); st != "" {
				out[id] = append(out[id], divergenceCand{branch, st, "worktree", merged, dirty})
			}
		}
	}
	refs, _ := gitCtx(root, "for-each-ref", "--no-merged=HEAD", "--format=%(refname:short)", "refs/heads")
	scanned := 0
	for _, b := range strings.Split(refs, "\n") {
		if b == "" || strings.HasPrefix(b, "-") || seenBranches[b] {
			continue
		}
		if scanned >= divergenceBranchCap {
			break
		}
		scanned++
		base, _ := gitCtx(root, "merge-base", "HEAD", b)
		if base == "" {
			continue
		}
		diffOut, _ := gitCtx(root, "diff", "--name-only", base, b, "--", ".tickets/*/ticket.md")
		changed := changedTicketIDs(diffOut, ids)
		if len(changed) == 0 {
			continue
		}
		first := map[string]string{}
		grepOut, _ := gitCtx(root, "grep", "-I", "-e", "^status:", b, "--", ".tickets/*/ticket.md")
		for _, line := range strings.Split(grepOut, "\n") {
			if !strings.HasPrefix(line, b+":") {
				continue
			}
			m := grepStatusRe.FindStringSubmatch(line[len(b)+1:])
			if m == nil || !changed[m[1]] {
				continue
			}
			if _, dup := first[m[1]]; !dup {
				first[m[1]] = unquoteYAMLScalar(m[2])
			}
		}
		for tid, st := range first {
			out[tid] = append(out[tid], divergenceCand{b, st, "branch", false, false})
		}
	}
	return out
}

// annotateBranchDivergence adds `branch_divergence` to tickets whose status
// differs on another worktree/unmerged branch. A git failure means no field.
func annotateBranchDivergence(tickets []ticket, root string) {
	main := map[string]string{}
	ids := map[string]bool{}
	for _, t := range tickets {
		if t["layout"] != "folder" {
			continue
		}
		if id, ok := t["id"].(string); ok && id != "" {
			main[id] = fmt.Sprint(t["status"])
			ids[id] = true
		}
	}
	if len(ids) == 0 {
		return
	}
	ttl := divergenceTTL()
	key := rootOr(root)
	var scan map[string][]divergenceCand
	if ttl > 0 {
		divergenceCacheMu.Lock()
		if hit, ok := divergenceCache[key]; ok && time.Now().Before(hit.expires) {
			scan = hit.scan
		}
		divergenceCacheMu.Unlock()
	}
	if scan == nil {
		scan = scanOtherCheckouts(root, ids)
		if ttl > 0 {
			divergenceCacheMu.Lock()
			divergenceCache[key] = divergenceCacheEntry{time.Now().Add(ttl), scan}
			divergenceCacheMu.Unlock()
		}
	}
	// Prefer a live worktree over a branch, then a terminal status, then branch name —
	// a stable order, so every call picks the same entry.
	better := func(a, b divergenceCand) bool {
		if (a.where == "worktree") != (b.where == "worktree") {
			return a.where == "worktree"
		}
		aTerm, bTerm := a.status == "closed" || a.status == "cancelled", b.status == "closed" || b.status == "cancelled"
		if aTerm != bTerm {
			return aTerm
		}
		return a.branch < b.branch
	}
	for _, t := range tickets {
		id, _ := t["id"].(string)
		var best *divergenceCand
		for i := range scan[id] {
			c := scan[id][i]
			if c.status != main[id] && (best == nil || better(c, *best)) {
				best = &c
			}
		}
		if best != nil {
			t["branch_divergence"] = map[string]any{
				"branch": best.branch, "status": best.status, "where": best.where, "merged": best.merged, "dirty": best.dirty,
			}
		}
	}
}

// t-1780: root scopes this to the requesting tab's own project (empty ->
// rootOr falls back to the shell's own boot-time projectRoot). Without it,
// every caller saw the shell's launch project regardless of which registered
// project's tab actually asked.
// listWorktrees is listWorktreesBase plus the t-2241 hold annotation (what the
// pickers need). Callers that only need the worktree set use the base.
func listWorktrees(ticketID, root string) []map[string]any {
	entries := listWorktreesBase(ticketID, root)
	annotateWorktreeHolds(entries, ticketID, rootOr(root))
	return entries
}

func listWorktreesBase(ticketID, root string) []map[string]any {
	raw := runGitIn(root, "worktree", "list", "--porcelain")
	var entries []map[string]any
	var cur map[string]any
	flush := func() {
		if cur != nil {
			entries = append(entries, cur)
		}
	}
	for _, line := range strings.Split(raw, "\n") {
		switch {
		case strings.HasPrefix(line, "worktree "):
			flush()
			cur = map[string]any{"path": strings.TrimPrefix(line, "worktree ")}
		case strings.HasPrefix(line, "branch ") && cur != nil:
			ref := strings.TrimPrefix(line, "branch ")
			cur["branch"] = strings.TrimPrefix(ref, "refs/heads/")
		case strings.HasPrefix(line, "HEAD ") && cur != nil:
			cur["head"] = strings.TrimPrefix(line, "HEAD ")
		case line == "detached" && cur != nil:
			cur["detached"] = true
		}
	}
	flush()
	mainRoot := rootOr(root)
	if resolved, err := filepath.EvalSymlinks(mainRoot); err == nil {
		mainRoot = resolved
	}
	for _, e := range entries {
		resolved, err := filepath.EvalSymlinks(fmt.Sprint(e["path"]))
		e["is_main"] = err == nil && resolved == mainRoot
	}
	// t-e5ff: parity with server.py — a git worktree materializes only tracked
	// files, so when `.tickets/` is gitignored a non-main worktree can't see any
	// ticket dir. `git check-ignore .tickets` prints the path when ignored, empty
	// otherwise (runGitIn ignores exit status); a non-git dir yields empty ->
	// treated as visible so the common single-checkout case is never blocked.
	ticketsIgnored := runGitIn(root, "check-ignore", ".tickets") != ""
	for _, e := range entries {
		isMain, _ := e["is_main"].(bool)
		e["tickets_visible"] = isMain || !ticketsIgnored
	}
	// t-2a1c: parity with server.py — ticket-scoped physical presence mirroring
	// the daemon's handleStart guard (stat <cwd>/.tickets/<id>, must be a dir),
	// so the board gates Start on the EFFECTIVE run cwd, not just check-ignore.
	// Only computed when a ticket id is given; the main checkout is exempt (it
	// physically holds .tickets/ even when gitignored). Field absent otherwise.
	if ticketID != "" {
		for _, e := range entries {
			if isMain, _ := e["is_main"].(bool); isMain {
				e["ticket_present"] = true
				continue
			}
			fi, err := os.Stat(filepath.Join(fmt.Sprint(e["path"]), ".tickets", ticketID))
			e["ticket_present"] = err == nil && fi.IsDir()
		}
	}
	if entries == nil {
		entries = []map[string]any{}
	}
	return entries
}

// ── Live docs of a worktree-bound ticket (t-e78b) ─────────────────────────
// Mirrors server.py's annotate_live_docs / _live_worktree / _live_for_doc
// (parity-tested by tests/sprint-check-live-docs.sh). The .cockpit-cwd lock is
// agent-writable, so a bound path must be a registered non-main worktree and
// every read stays inside <worktree>/.tickets/<id>/.
var docOverlayFields = []string{"docs", "acceptance_has_items", "acceptance_unchecked",
	"models_used", "plan_has_approach", "plan_approved"}

// t-8be2: the worktree copy also owns the ticket's own fields (title is the body's first heading).
var ticketOverlayFields = []string{"status", "title", "body", "demo", "tags"}

func registeredWorktrees(root string) []map[string]any {
	out := []map[string]any{}
	for _, e := range listWorktreesBase("", root) {
		if isMain, _ := e["is_main"].(bool); isMain {
			continue
		}
		if fi, err := os.Stat(fmt.Sprint(e["path"])); err == nil && fi.IsDir() {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return fmt.Sprint(out[i]["path"]) < fmt.Sprint(out[j]["path"]) })
	return out
}

// liveWorktreeFull returns (<wt>/.tickets/<id> resolved, branch, the bound worktree's own path, true) for a bound ticket (t-26f9: the write path re-checks the
// unresolved .tickets and ticket folders under it).
func liveWorktreeFull(t ticket, root string, wts []map[string]any) (string, string, string, bool) {
	tid, _ := t["id"].(string)
	if t["layout"] != "folder" || tid == "" || tid == "." || tid == ".." || strings.ContainsAny(tid, "/\\") {
		return "", "", "", false
	}
	var cand map[string]any
	if raw, err := os.ReadFile(filepath.Join(ticketsDirForRoot(root), tid, ".cockpit-cwd")); err == nil {
		if cwd := strings.TrimSpace(string(raw)); cwd != "" {
			key := pathKey(cwd)
			for _, e := range wts {
				if pathKey(fmt.Sprint(e["path"])) == key {
					cand = e
					break
				}
			}
		}
	}
	if cand == nil {
		if d, ok := t["branch_divergence"].(map[string]any); ok && d["where"] == "worktree" && d["status"] == "in_progress" {
			for _, e := range wts {
				if e["branch"] == d["branch"] {
					cand = e
					break
				}
			}
		}
	}
	if cand == nil {
		return "", "", "", false
	}
	base, err := filepath.EvalSymlinks(filepath.Join(fmt.Sprint(cand["path"]), ".tickets"))
	if err != nil {
		return "", "", "", false
	}
	dir, err := filepath.EvalSymlinks(filepath.Join(base, tid))
	if err != nil {
		return "", "", "", false
	}
	if rel, err := filepath.Rel(base, dir); err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", "", "", false
	}
	if fi, err := os.Stat(filepath.Join(dir, "ticket.md")); err != nil || fi.IsDir() {
		return "", "", "", false
	}
	branch, _ := cand["branch"].(string)
	return dir, branch, fmt.Sprint(cand["path"]), true
}

// ── Writing a worktree-bound ticket's docs from the board (t-26f9) ─────────
// Replaces t-e78b's read-only rule: the worktree copy owns a bound ticket's docs, and the board may edit them.
// Every write is guarded by the etag the client read (sha256 of the file's exact bytes, or "absent"), so the board
// and the agent can never silently overwrite each other; the target is re-validated here, at the point of use,
// because the .cockpit-cwd lock that binds the ticket is agent-writable.
const (
	docEtagAbsent   = "absent"
	liveDocMaxBytes = 1 << 20
)

var liveDocNames = map[string]bool{"acceptance.md": true, "plan.md": true, "research.md": true}
var liveDocMu sync.Mutex

func docEtag(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

type liveDocErr struct {
	status int
	code   string
	msg    string
}

// liveDocTargetFrom returns the file a board write to docFile would replace in the bound worktree, or why not.
// dir is liveWorktreeFull's resolved <worktree>/.tickets/<id>; wtPath is the worktree itself.
func liveDocTargetFrom(docFile, dir, wtPath string) (string, *liveDocErr) {
	return liveTargetFrom(docFile, dir, wtPath, liveDocNames)
}

// liveTargetFrom is liveDocTargetFrom for an arbitrary exact-name allowlist (t-8be2: a bound ticket's own ticket.md).
func liveTargetFrom(docFile, dir, wtPath string, names map[string]bool) (string, *liveDocErr) {
	bad := &liveDocErr{http.StatusBadRequest, "bad_doc", "that doc can't be written from the board"}
	parts := strings.Split(docFile, "/")
	// The raw name, compared exactly: NTFS ignores a trailing dot or space and treats `:` as a stream, so a
	// normalised comparison would let `plan.md.`, `plan.md::$DATA` or `TICKET~1.MD` through.
	if strings.ContainsAny(docFile, "\\:\x00") || len(parts) != 2 || parts[0] == "" || parts[0] == "." || parts[0] == ".." {
		return "", bad
	}
	name := strings.ToLower(parts[1])
	if !names[name] {
		return "", bad
	}
	trust := &liveDocErr{http.StatusForbidden, "unsafe_path", "that ticket folder is not a plain folder inside its worktree"}
	realWT, err := filepath.EvalSymlinks(wtPath)
	if err != nil {
		return "", trust
	}
	ticketsDir := filepath.Join(wtPath, ".tickets")
	tDir := filepath.Join(ticketsDir, parts[0])
	for _, q := range []string{ticketsDir, tDir} {
		fi, err := os.Lstat(q)
		if err != nil || !fi.IsDir() || fi.Mode()&(os.ModeSymlink|os.ModeIrregular) != 0 {
			return "", trust // a symlink or a junction (reparse point), however Lstat reports it
		}
	}
	// Belt and braces: the resolved folder must be exactly where the worktree says it is.
	if pathKey(dir) != pathKey(filepath.Join(realWT, ".tickets", parts[0])) {
		return "", trust
	}
	target := filepath.Join(dir, name)
	if fi, err := os.Lstat(target); err == nil && !fi.Mode().IsRegular() {
		return "", trust
	}
	return target, nil
}

// liveDocEtagOf is "absent" ONLY when the file does not exist: any other read error (permissions, a Windows sharing
// violation) must not read as absent, or a write with base_hash "absent" would bypass the guard.
func liveDocEtagOf(target string) (string, error) {
	raw, err := os.ReadFile(target)
	if errors.Is(err, os.ErrNotExist) {
		return docEtagAbsent, nil
	}
	if err != nil {
		return "", err
	}
	return docEtag(raw), nil
}

// atomicWriteFile writes via a temp file in the same folder and a rename, so no reader ever sees a half-written
// doc. Windows refuses to replace a file another process has open, so the rename is retried briefly.
func atomicWriteFile(target string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(target), ".board-*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, werr := tmp.Write(data)
	if werr == nil {
		werr = tmp.Sync()
	}
	if cerr := tmp.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		os.Remove(name)
		return werr
	}
	mode := os.FileMode(0o644) // a new doc; an existing one keeps the mode it had
	if fi, err := os.Stat(target); err == nil {
		mode = fi.Mode().Perm()
	}
	_ = os.Chmod(name, mode)
	var rerr error
	for i := 0; i < 6; i++ {
		if rerr = os.Rename(name, target); rerr == nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	os.Remove(name)
	return rerr
}

// writeLiveDoc handles POST /api/doc/<doc> for a worktree-bound ticket. handled is false for an unbound one.
func writeLiveDoc(docFile string, payload map[string]any, root string) (handled bool, status int, res map[string]any) {
	dir, _, wtPath, live := liveForDocFull(docFile, root)
	if !live {
		return false, 0, nil
	}
	fail := func(st int, code, msg string) (bool, int, map[string]any) {
		return true, st, map[string]any{"ok": false, "code": code, "error": msg}
	}
	target, derr := liveDocTargetFrom(docFile, dir, wtPath)
	if derr != nil {
		return fail(derr.status, derr.code, derr.msg)
	}
	content, isStr := payload["content"].(string)
	if !isStr {
		return fail(http.StatusBadRequest, "bad_content", "content must be text")
	}
	if len(content) > liveDocMaxBytes {
		return fail(http.StatusBadRequest, "too_large", "that doc is too large to save from the board")
	}
	base, _ := payload["base_hash"].(string)
	liveDocMu.Lock()
	defer liveDocMu.Unlock()
	cur, rerr := liveDocEtagOf(target)
	if rerr != nil {
		return fail(http.StatusInternalServerError, "read_failed", "couldn't read "+filepath.Base(target)+" to check it hasn't changed — is another program holding it open? Try again")
	}
	if base == "" || base != cur {
		return fail(http.StatusConflict, "stale", filepath.Base(target)+" changed since you read it — reload it and try again")
	}
	data := []byte(strings.TrimSpace(content) + "\n")
	if err := atomicWriteFile(target, data); err != nil {
		return fail(http.StatusInternalServerError, "write_failed", "couldn't save "+filepath.Base(target)+" — is another program holding it open? Try again")
	}
	return true, http.StatusOK, map[string]any{"ok": true, "etag": docEtag(data)}
}

// ── Writing a worktree-bound ticket's own fields from the board (t-8be2) ───
// Tested by tests/sprint-check-live-ticket.sh. The worktree copy owns a
// bound ticket's status, Description and Demo too. status/demo are single-field edits of the bytes on disk at that
// moment; a body save is guarded by base_hash like a doc. ACTIVE follows tkt's per-checkout file.
var liveTicketNames = map[string]bool{"ticket.md": true}
var liveTicketStatuses = map[string]bool{"open": true, "in_progress": true, "closed": true, "cancelled": true, "archived": true}
var liveStatusLineRe = regexp.MustCompile(`^(status:[ \t]*)(\S+)([ \t\r]*)$`)

// liveSafe: a bound ticket's folder is plain (no link or junction at .tickets, the ticket folder or ticket.md). Reads
// (the overlay, a doc's text) require it, because the board must not show a file outside the worktree through a link
// an agent made; a write re-checks on its own and answers 403.
func liveSafe(id, dir, wtPath string) bool {
	_, derr := liveTargetFrom(id+"/ticket.md", dir, wtPath, liveTicketNames)
	return derr == nil
}

// liveClosedMarker is tkt's close marker (t-dec8): `closed: <UTC time>` while closed, none otherwise. The
// pre-commit hook blocks a staged ticket.md that says `status: closed` without it.
func liveClosedMarker(lines []string, status string) []string {
	out := make([]string, 0, len(lines)+1)
	for _, ln := range lines {
		if !strings.HasPrefix(ln, "closed:") {
			out = append(out, ln)
		}
	}
	if status == "closed" {
		out = append(out, "closed: "+time.Now().UTC().Format("2006-01-02T15:04:05Z"))
	}
	return out
}

// liveBodyOf is the Description as /api/tickets shows it: everything after the frontmatter, trimmed.
func liveBodyOf(text string) string {
	if m := frontmatterRe.FindStringIndex(text); m != nil {
		text = text[m[1]:]
	}
	return strings.ToValidUTF8(strings.TrimSpace(text), "\uFFFD")
}

// liveActivePath is <worktree>/.tickets/ACTIVE when it is safe to write or remove (absent or a plain file).
func liveActivePath(wtPath string) (string, bool) {
	p := filepath.Join(wtPath, ".tickets", "ACTIVE")
	if fi, err := os.Lstat(p); err == nil && !fi.Mode().IsRegular() {
		return "", false
	}
	return p, true
}

// liveSetActive is tkt's set_active / clear_active_if on the worktree's own file.
func liveSetActive(active, id, status string) error {
	if status == "in_progress" {
		return atomicWriteFile(active, []byte(id+"\n"))
	}
	raw, err := os.ReadFile(active)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(raw)) == id {
		return os.Remove(active)
	}
	return nil
}

// writeLiveTicket handles POST /api/ticket/<id>/{status,demo,body} for a worktree-bound ticket. handled is false
// for an unbound one (the caller then writes main's copy as before).
func writeLiveTicket(id, kind string, payload map[string]any, root string) (handled bool, status int, res map[string]any) {
	dir, _, wtPath, live := liveForDocFull(id+"/ticket.md", root)
	if !live {
		return false, 0, nil
	}
	fail := func(st int, code, msg string) (bool, int, map[string]any) {
		return true, st, map[string]any{"ok": false, "code": code, "error": msg}
	}
	target, derr := liveTargetFrom(id+"/ticket.md", dir, wtPath, liveTicketNames)
	if derr != nil {
		return fail(derr.status, derr.code, derr.msg)
	}
	var newStatus, oldStatus, newBody, active string
	switch kind {
	case "status":
		var isStr bool
		newStatus, isStr = payload["status"].(string)
		if !isStr || !liveTicketStatuses[newStatus] {
			return fail(http.StatusBadRequest, "bad_status", "that is not a ticket status")
		}
		var ok bool
		if active, ok = liveActivePath(wtPath); !ok {
			return fail(http.StatusForbidden, "unsafe_path", "that worktree's ACTIVE file is not a plain file")
		}
	case "body":
		var isStr bool
		newBody, isStr = payload["body"].(string)
		if !isStr {
			return fail(http.StatusBadRequest, "bad_content", "body must be text")
		}
		newBody = strings.TrimSpace(newBody) // what is written is what is measured (as in server.py)
		if len(newBody) > liveDocMaxBytes {
			return fail(http.StatusBadRequest, "too_large", "that description is too large to save from the board")
		}
	}
	liveDocMu.Lock()
	defer liveDocMu.Unlock()
	raw, rerr := os.ReadFile(target)
	if errors.Is(rerr, os.ErrNotExist) {
		return fail(http.StatusNotFound, "not_found", "that ticket has no ticket.md in its worktree")
	}
	if rerr != nil {
		return fail(http.StatusInternalServerError, "read_failed", "couldn't read ticket.md — is another program holding it open? Try again")
	}
	text := string(raw)
	m := frontmatterRe.FindStringSubmatchIndex(text)
	if m == nil {
		return fail(http.StatusConflict, "bad_ticket", "that ticket.md has no frontmatter")
	}
	var updated string
	switch kind {
	case "body":
		base, _ := payload["base_hash"].(string)
		if base == "" || base != docEtag(raw) {
			return fail(http.StatusConflict, "stale", "ticket.md changed since you read it — reload it and try again")
		}
		updated = text[:m[1]] + newBody + "\n"
	case "status":
		lines := strings.Split(text[m[2]:m[3]], "\n")
		found := false
		for i, ln := range lines {
			if sm := liveStatusLineRe.FindStringSubmatch(ln); sm != nil {
				oldStatus = sm[2]
				lines[i] = sm[1] + newStatus + sm[3]
				found = true
				break
			}
		}
		if !found {
			return fail(http.StatusConflict, "bad_ticket", "that ticket.md has no status line")
		}
		updated = text[:m[2]] + strings.Join(liveClosedMarker(lines, newStatus), "\n") + text[m[3]:]
	case "tags": // t-37e8: the route validated payload["tags"] ([]string); check again, this writes a file
		tags, ok := payload["tags"].([]string)
		if !ok {
			return fail(http.StatusBadRequest, "bad_tags", "tags must be a list of text")
		}
		if _, err := normalizeTags(strings.Join(tags, ",")); err != nil {
			return fail(http.StatusBadRequest, "bad_tags", err.Error())
		}
		updated = text[:m[2]] + strings.Join(setTagsLine(strings.Split(text[m[2]:m[3]], "\n"), tags), "\n") + text[m[3]:]
	default:
		var kept []string
		for _, ln := range strings.Split(text[m[2]:m[3]], "\n") {
			if !strings.HasPrefix(ln, "demo:") {
				kept = append(kept, ln)
			}
		}
		if boolValue(payload["demo"]) {
			kept = append(kept, "demo: true")
		}
		updated = text[:m[2]] + strings.Join(kept, "\n") + text[m[3]:]
	}
	data := []byte(updated)
	if updated == text {
		data = raw
	}
	var werr error
	if updated != text {
		werr = atomicWriteFile(target, data)
	}
	if werr == nil && kind == "status" {
		werr = liveSetActive(active, id, newStatus)
	}
	if werr != nil {
		return fail(http.StatusInternalServerError, "write_failed", "couldn't save ticket.md — is another program holding it open? Try again")
	}
	if kind == "status" && updated != text {
		emitStatusChanged(id, oldStatus, newStatus, root)
	}
	out := map[string]any{"ok": true, "etag": docEtag(data)}
	if kind != "body" {
		// The page keeps its text and its etag as a pair: hand back the Description this etag describes, so a later
		// edit never starts from older text under a newer etag.
		out["body"] = liveBodyOf(updated)
	}
	return true, http.StatusOK, out
}

func annotateLiveDocs(tickets []ticket, root string) {
	root = rootOr(root)
	wts := registeredWorktrees(root)
	if len(wts) == 0 {
		return
	}
	for _, t := range tickets {
		dir, branch, wtPath, ok := liveWorktreeFull(t, root, wts)
		if !ok || !liveSafe(fmt.Sprint(t["id"]), dir, wtPath) {
			continue
		}
		// Read the bytes BEFORE parsing: an etag older than the text shown can only make a save stale, never let
		// it overwrite a newer write.
		raw, rerr := os.ReadFile(filepath.Join(dir, "ticket.md"))
		if rerr != nil {
			continue
		}
		w, err := parseTicket(filepath.Join(dir, "ticket.md"))
		if err != nil {
			continue
		}
		for _, k := range docOverlayFields {
			t[k] = w[k]
		}
		for _, k := range ticketOverlayFields {
			t[k] = w[k]
		}
		t["ticket_etag"] = docEtag(raw)
		t["docs_from"] = map[string]any{"branch": branch}
	}
}

// liveForDocFull computes a doc's ticket binding exactly like /api/tickets (full
// load + divergence, so the TTL-cached scan is never seeded with a partial set).
func liveForDocFull(docFile, root string) (string, string, string, bool) {
	root = rootOr(root)
	parts := strings.Split(filepath.ToSlash(filepath.Clean(filepath.FromSlash(docFile))), "/")
	if len(parts) == 0 || parts[0] == "" {
		return "", "", "", false
	}
	tickets := loadTickets(root)
	annotateBranchDivergence(tickets, root)
	for _, t := range tickets {
		if t["id"] == parts[0] {
			wts := registeredWorktrees(root)
			if len(wts) == 0 {
				return "", "", "", false
			}
			return liveWorktreeFull(t, root, wts)
		}
	}
	return "", "", "", false
}

// ── Worktree holds (t-2241) ───────────────────────────────────────────────
// Tested by tests/sprint-check-worktree-holds.sh: which non-main worktrees another ticket
// still needs — bound via .cockpit-cwd and not done ("in progress"), chosen by an
// open ticket's worktree_preference ("reserved"), dirty ignoring runtime noise
// ("uncommitted changes"), or unmerged ("branch not merged"). The requesting
// ticket's own worktree is marked own and never held.
var wtPrefRe = regexp.MustCompile(`(?m)^worktree_preference:\s*(.+?)\s*$`)

func pathKey(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		p = r
	}
	return strings.ToLower(strings.TrimRight(strings.ReplaceAll(p, "\\", "/"), "/"))
}

func isWorktreeNoise(path string) bool {
	return isCanonRuntimePath(path) || path[strings.LastIndex(path, "/")+1:] == "cockpit-sessions.md"
}

// isCanonSkillsLink: t-07a8 — canon links its skills into every worktree it
// creates, so a project that does not gitignore them sees UNTRACKED
// .agents/skills and .claude/skills (a Windows junction lists its contents
// under --untracked-files=all). That is canon's own, not user work. Only an
// untracked entry at exactly those paths; a tracked or modified file there, or
// a sibling like .claude/notes.md, still counts. Known trade-off: the prefix
// match also hides a user's NEW untracked file inside a tracked, project-local
// skills directory; the junction case needs the prefix, and the hold only
// guards against offering a worktree that carries work, which reuse does not
// destroy. Parity with server.py's
// _is_canon_skills_link.
func isCanonSkillsLink(status, path string) bool {
	if status != "??" {
		return false
	}
	for _, d := range []string{".agents/skills", ".claude/skills"} {
		if path == d || strings.HasPrefix(path, d+"/") {
			return true
		}
	}
	return false
}

func worktreeDirty(path string) bool {
	out, _, err := gitOutIn(path, 10*time.Second, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return false
	}
	tokens := strings.Split(out, "\x00")
	for i := 0; i < len(tokens); i++ {
		entry := tokens[i]
		if len(entry) < 4 {
			continue
		}
		if strings.ContainsAny(entry[:2], "RC") {
			i++
		}
		if !isWorktreeNoise(entry[3:]) && !isCanonSkillsLink(entry[:2], entry[3:]) {
			return true
		}
	}
	return false
}

// ticketFM returns (status, worktree_preference) from a ticket.md's frontmatter;
// ok is false when the file is missing or has no frontmatter.
func ticketFM(path string) (string, string, bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", "", false
	}
	m := frontmatterRe.FindStringSubmatch(string(raw))
	if m == nil {
		return "", "", false
	}
	pref := ""
	if pm := wtPrefRe.FindStringSubmatch(m[1]); pm != nil {
		pref = unquoteYAMLScalar(pm[1])
	}
	return frontmatterStatus(string(raw)), pref, true
}

func annotateWorktreeHolds(entries []map[string]any, ticketID, root string) {
	hasOther := false
	for _, e := range entries {
		if isMain, _ := e["is_main"].(bool); !isMain {
			hasOther = true
		}
	}
	if !hasOther {
		return
	}
	tdir := ticketsDirForRoot(root)
	bound := map[string][]string{}
	preferred := map[string][]string{}
	mainStatus := map[string]string{}
	dirs, _ := os.ReadDir(tdir)
	names := []string{}
	for _, d := range dirs {
		if d.IsDir() {
			names = append(names, d.Name())
		}
	}
	sort.Strings(names)
	for _, id := range names {
		st, pref, ok := ticketFM(filepath.Join(tdir, id, "ticket.md"))
		if !ok {
			continue
		}
		mainStatus[id] = st
		if st == "open" && pref != "" {
			preferred[pref] = append(preferred[pref], id)
		}
		if raw, err := os.ReadFile(filepath.Join(tdir, id, ".cockpit-cwd")); err == nil {
			if cwd := strings.TrimSpace(string(raw)); cwd != "" {
				k := pathKey(cwd)
				bound[k] = append(bound[k], id)
			}
		}
	}
	for _, e := range entries {
		if isMain, _ := e["is_main"].(bool); isMain {
			continue
		}
		path := fmt.Sprint(e["path"])
		branch, _ := e["branch"].(string)
		// A deleted worktree folder still appears in `git worktree list` (marked
		// prunable) until `git worktree prune`; with no folder it reads as clean and
		// merged, i.e. falsely free. Nobody can use it.
		if fi, err := os.Stat(path); err != nil || !fi.IsDir() {
			e["held_by"] = map[string]any{"ticket": "", "reason": "folder missing"}
			continue
		}
		binders := bound[pathKey(path)]
		statusOf := func(id string) string {
			if st, _, ok := ticketFM(filepath.Join(path, ".tickets", id, "ticket.md")); ok && st != "" {
				return st
			}
			return mainStatus[id]
		}
		active := []string{}
		for _, id := range binders {
			if st := statusOf(id); st != "closed" && st != "cancelled" {
				active = append(active, id)
			}
		}
		reservers := preferred[branch]
		named := ""
		if strings.HasPrefix(branch, "sprint/") {
			if _, ok := mainStatus[strings.TrimPrefix(branch, "sprint/")]; ok {
				named = strings.TrimPrefix(branch, "sprint/")
			}
		}
		if ticketID != "" {
			own := named == ticketID
			for _, list := range [][]string{active, reservers, binders} {
				for _, id := range list {
					own = own || id == ticketID
				}
			}
			// Another ticket actively running here always wins over a mere preference.
			for _, id := range active {
				own = own && id == ticketID
			}
			if own {
				e["own"] = true
				continue
			}
			kept := []string{}
			for _, id := range active {
				if id != ticketID {
					kept = append(kept, id)
				}
			}
			active = kept
		}
		reason, holder := "", ""
		switch {
		case len(active) > 0:
			reason, holder = "in progress", active[0]
		case len(reservers) > 0:
			reason, holder = "reserved", reservers[0]
		default:
			owner := named
			if len(binders) > 0 {
				owner = binders[0]
			}
			head, _ := e["head"].(string)
			if worktreeDirty(path) {
				reason, holder = "uncommitted changes", owner
			} else if head != "" {
				if _, merged := gitCtx(root, "merge-base", "--is-ancestor", head, "HEAD"); !merged {
					reason, holder = "branch not merged", owner
				}
			}
		}
		if reason != "" {
			e["held_by"] = map[string]any{"ticket": holder, "reason": reason}
		}
	}
}

// cockpitDocs (t-1357) reads a cockpit ticket's plan.md / acceptance.md /
// HANDOFF.md from the WORKTREE the session runs in, not the board's main
// checkout. A worktree sprint writes those on its own branch, so the main
// .tickets/<id>/ shows only the committed ticket.md; the cockpit rail should
// reflect the tree the agent is actually editing. Returns ok=false (caller ->
// 400) when cwd is not a real registered worktree — the board never reads an
// arbitrary client-supplied directory (same trust model as the daemon's
// resolveSpawnCwd). Read-only; each doc path is contained under <cwd>/.tickets.
// Behaviour pinned by tests/sprint-check-api.sh.
func cockpitDocs(ticketID, cwd string) (map[string]any, bool) {
	cwdReal, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		return nil, false
	}
	// t-1780: run from cwdReal itself, not the global projectRoot — `git
	// worktree list` reports every sibling of whichever repo it's run inside,
	// so this is correct for any project without a separate ?project= lookup.
	isWorktree := false
	for _, e := range listWorktreesBase("", cwdReal) {
		if wt, err := filepath.EvalSymlinks(fmt.Sprint(e["path"])); err == nil && wt == cwdReal {
			isWorktree = true
			break
		}
	}
	if !isWorktree {
		return nil, false
	}
	tickets := filepath.Join(cwdReal, ".tickets")
	read := func(rel string) any {
		p := filepath.Join(tickets, filepath.FromSlash(rel))
		if r, err := filepath.Rel(tickets, p); err != nil || strings.HasPrefix(r, "..") {
			return nil
		}
		if resolved, err := filepath.EvalSymlinks(p); err == nil {
			if r2, err2 := filepath.Rel(tickets, resolved); err2 != nil || strings.HasPrefix(r2, "..") {
				return nil
			}
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		return string(b)
	}
	var plan, acceptance any
	if fi, err := os.Stat(filepath.Join(tickets, ticketID)); err == nil && fi.IsDir() {
		plan = read(ticketID + "/plan.md")
		acceptance = read(ticketID + "/acceptance.md")
	} else {
		plan = read(ticketID + "-plan.md")
		acceptance = read(ticketID + "-acceptance.md")
	}
	var handoff any
	if b, err := os.ReadFile(filepath.Join(cwdReal, "HANDOFF.md")); err == nil {
		handoff = string(b)
	}
	return map[string]any{"plan": plan, "acceptance": acceptance, "handoff": handoff}, true
}

// isCanonRuntimePath reports whether a git-porcelain path (repo-root-relative,
// forward-slashed) is one of canon's own per-machine runtime files under
// .tickets/ that churn every session (t-2f53): .tickets/ACTIVE and any
// .tickets/**/.cockpit-* (.cockpit-cwd/.cockpit-agent/.cockpit-session-id).
// These must not count as user "uncommitted changes" in the carry-over warning.
// Parity with server.py's _is_canon_runtime_path.
func isCanonRuntimePath(path string) bool {
	p := strings.ReplaceAll(strings.Trim(strings.TrimSpace(path), "\""), "\\", "/")
	if p == ".tickets/ACTIVE" {
		return true
	}
	if strings.HasPrefix(p, ".tickets/") {
		base := p[strings.LastIndex(p, "/")+1:]
		if strings.HasPrefix(base, ".cockpit-") {
			return true
		}
	}
	return false
}

// mainDirtyIgnoringRuntime computes main_dirty for the worktree carry-over
// warning, ignoring canon-owned runtime files (t-2f53). --untracked-files=all
// so a fresh/untracked runtime file lists individually (default porcelain
// collapses a fully-untracked dir to "?? dir/", hiding it); a deleted tracked
// runtime file lists individually regardless. A porcelain line is "XY <path>"
// (2 status chars + space), so the path starts at index 3. Parity with
// server.py's _main_dirty_ignoring_runtime. t-1780: root scopes this to the
// requesting tab's own project.
func mainDirtyIgnoringRuntime(root string) bool {
	status := runGitIn(root, "status", "--porcelain", "--untracked-files=all")
	for _, line := range strings.Split(status, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		path := line
		if len(line) > 3 {
			path = line[3:]
		}
		if !isCanonRuntimePath(path) {
			return true
		}
	}
	return false
}

// (t-cd06 amendment) — the daemon owns writing that file and already ignores
// a locked ticket's requested cwd; this just lets the board warn before the
// choice is made for an in_progress ticket's first resume, since a worktree
// checkout only carries committed history.
// t-1780: root scopes this to the requesting tab's own project.
func worktreeLockStatus(ticketID, root string) map[string]any {
	cwdPath := filepath.Join(ticketsDirForRoot(root), ticketID, ".cockpit-cwd")
	var cwd any
	if b, err := os.ReadFile(cwdPath); err == nil {
		if trimmed := strings.TrimSpace(string(b)); trimmed != "" {
			cwd = trimmed
		}
	}
	dirty := mainDirtyIgnoringRuntime(root)
	return map[string]any{"locked": cwd != nil, "cwd": cwd, "main_dirty": dirty}
}

// worktreeUnlock clears a ticket's worktree lock — both .cockpit-cwd and
// .cockpit-session-id (t-fe3c; t-9203) — parity with server.py's worktree_unlock. The daemon reuses that persisted cwd for every
// start of an in_progress ticket and ignores the client's request, so deleting
// it is the only way to redirect a ticket to a different worktree (or the main
// checkout) — e.g. one locked to a worktree that can't see .tickets/ (t-e5ff).
// Advisory + reversible; a running session is unaffected. Idempotent. A real
// delete failure (permissions, read-only fs) is reported as ok:false rather
// than silently claimed as success (review finding, t-fe3c) — matches
// server.py, where unlink()'s exception isn't swallowed either.
// t-1780: root scopes this to the requesting tab's own project — a stale
// global ticketsDir meant unlocking a non-primary project's ticket looked in
// the wrong project's .tickets/ and silently no-op'd.
func worktreeUnlock(ticketID, root string) map[string]any {
	// t-9203: clear BOTH .cockpit-cwd AND .cockpit-session-id. Clearing the cwd
	// alone lets the next start re-resolve the directory, but the persisted
	// session id would still make claude --resume (or pi continue) the prior
	// conversation *in the new directory* — the cross-dir reattach the daemon's
	// invariant forbids. Dropping the session id too means the next Start is a
	// genuinely fresh session in the worktree the user picks next.
	// Gate each on "regular file" (not just stat success) — matches Python's
	// is_file() (false for a directory), so a directory at either path yields
	// unlocked:false without an os.Remove attempt (parity, t-fe3c).
	td := ticketsDirForRoot(root)
	paths := []string{
		filepath.Join(td, ticketID, ".cockpit-cwd"),
		filepath.Join(td, ticketID, ".cockpit-session-id"),
	}
	unlocked := false
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil || info.IsDir() {
			continue
		}
		if err := os.Remove(p); err != nil {
			return map[string]any{"ok": false, "error": err.Error()}
		}
		unlocked = true
	}
	return map[string]any{"ok": true, "unlocked": unlocked}
}

// createWorktree assumes branch already passed validBranchName (checked by
// the caller, which 400s on malformed input before this runs — mirrors
// server.py's create_worktree/_valid_branch_name split). t-1780: root scopes
// this to the requesting tab's own project.
func createWorktree(branch, root string) map[string]any {
	root = rootOr(root)
	siblingRoot := filepath.Join(filepath.Dir(root), filepath.Base(root)+"-worktrees")
	path := filepath.Join(siblingRoot, strings.ReplaceAll(branch, "/", "-"))
	if exists(path) {
		return map[string]any{"ok": false, "error": "path already exists"}
	}
	if err := os.MkdirAll(siblingRoot, 0o755); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	run := func(args ...string) error {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("%s", strings.TrimSpace(stderr.String()))
		}
		return nil
	}
	if err := run("worktree", "add", path, "-b", branch); err != nil {
		if err2 := run("worktree", "add", path, branch); err2 != nil {
			msg := err2.Error()
			if len(msg) > 500 {
				msg = msg[:500]
			}
			return map[string]any{"ok": false, "error": msg}
		}
	}
	copied := copyWorktreeIncludeFiles(path, root)
	linkSkillsIntoWorktree(path)
	return map[string]any{"ok": true, "path": path, "branch": branch, "worktreeinclude_copied": copied}
}

// ── Commit a ticket before branching (t-d254) ────────────────────────────
// Tested by tests/sprint-check-ticket-commit.sh: GET
// classifies the ticket's uncommitted files, POST commits a chosen subset
// path-scoped (`--only`), re-deriving eligibility itself rather than trusting
// the client's list.
var ticketCommitIDRe = regexp.MustCompile(`^t-[a-z0-9]{4}$`)

const otherDirtyCap = 20

// gitOutIn is runGitIn without the trim (porcelain lines start with a space)
// and with the exit status, which runGitIn discards. GIT_TERMINAL_PROMPT=0: the
// board has no terminal, so a credential prompt must fail, not hang.
func gitOutIn(root string, timeout time.Duration, args ...string) (string, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		err = ctx.Err()
	}
	return out.String(), errb.String(), err
}

func ticketCommitBlocked(root string) string {
	if runGitIn(root, "rev-parse", "--is-inside-work-tree") != "true" {
		return "not a git repository"
	}
	if runGitIn(root, "check-ignore", ".tickets") != "" {
		return ".tickets/ is gitignored"
	}
	if runGitIn(root, "rev-parse", "-q", "--verify", "HEAD") == "" {
		return "the repository has no commits yet"
	}
	if _, _, err := gitOutIn(root, 10*time.Second, "symbolic-ref", "-q", "HEAD"); err != nil {
		return "HEAD is detached"
	}
	for _, marker := range []string{"MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"} {
		p := runGitIn(root, "rev-parse", "--git-path", marker)
		if p == "" {
			continue
		}
		if !filepath.IsAbs(p) {
			p = filepath.Join(root, p)
		}
		if exists(p) {
			return "a merge, rebase or cherry-pick is in progress"
		}
	}
	return ""
}

// inHead: is path in the last commit. whitespaceOnlyChange (t-b59d): path (already in HEAD) differs from HEAD
// in whitespace only (trailing spaces, the amount of space between words, CR/LF endings). The diff OUTPUT
// decides (`-b --numstat` prints nothing for such a change), not an exit status. A failed git call counts as
// a real change, so nothing is hidden by accident. Parity with server.py's _whitespace_only_change.
func inHead(path, root string) bool {
	_, _, err := gitOutIn(root, 10*time.Second, "cat-file", "-e", "HEAD:"+path)
	return err == nil
}

func whitespaceOnlyChange(path, root string) bool {
	out, _, err := gitOutIn(root, 10*time.Second, "diff", "-b", "--numstat", "HEAD", "--", path)
	return err == nil && strings.TrimSpace(out) == ""
}

func ticketCommitPlan(ticketID, root string) map[string]any {
	root = rootOr(root)
	required, recommended, optional, other := []string{}, []string{}, []string{}, []string{}
	plan := map[string]any{"required": required, "recommended": recommended, "optional": optional,
		"other_dirty": other, "other_dirty_count": 0, "message": "", "blocked": ticketCommitBlocked(root),
		"ticket_in_head": false}
	if b := plan["blocked"]; b == "not a git repository" || b == ".tickets/ is gitignored" {
		return plan
	}
	out, _, err := gitOutIn(root, 10*time.Second, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		plan["blocked"] = "git status failed"
		return plan
	}
	prefix := ".tickets/" + ticketID + "/"
	untrackedRequired := false
	tokens := strings.Split(out, "\x00")
	for i := 0; i < len(tokens); i++ {
		entry := tokens[i]
		if len(entry) < 4 {
			continue
		}
		xy, path := entry[:2], entry[3:]
		if strings.ContainsAny(xy, "RC") {
			i++ // -z puts a rename/copy's source path in the next token
		}
		switch {
		case strings.HasPrefix(path, prefix):
			name := path[strings.LastIndex(path, "/")+1:]
			if name == "cockpit-sessions.md" || strings.HasPrefix(name, ".cockpit-") {
				optional = append(optional, path)
			} else if xy != "??" && inHead(path, root) && whitespaceOnlyChange(path, root) {
				continue // t-b59d: a committed file with a whitespace-only edit needs no commit
			} else {
				required = append(required, path)
				untrackedRequired = untrackedRequired || xy == "??"
			}
		case path == ".tickets/.gitignore":
			recommended = append(recommended, path)
		default:
			other = append(other, path)
		}
	}
	sort.Strings(required)
	sort.Strings(recommended)
	sort.Strings(optional)
	sort.Strings(other)
	plan["ticket_in_head"] = inHead(prefix+"ticket.md", root) // t-b59d: a new worktree has the last committed version
	plan["required"], plan["recommended"], plan["optional"] = required, recommended, optional
	plan["other_dirty_count"] = len(other)
	if len(other) > otherDirtyCap {
		other = other[:otherDirtyCap]
	}
	plan["other_dirty"] = other
	if len(required) > 0 {
		verb := "update"
		if untrackedRequired {
			verb = "add"
		}
		plan["message"] = "chore: " + verb + " ticket " + ticketID
	}
	return plan
}

// ticketCommit returns (json, http status), like server.py's ticket_commit.
func ticketCommit(ticketID string, raw any, root string) (map[string]any, int) {
	root = rootOr(root)
	fail := func(msg string, status int) (map[string]any, int) {
		return map[string]any{"ok": false, "error": msg}, status
	}
	list, ok := raw.([]any)
	if !ok || len(list) == 0 {
		return fail("paths must be a non-empty list", http.StatusBadRequest)
	}
	seen := map[string]bool{}
	for _, v := range list {
		s, ok := v.(string)
		if !ok {
			return fail("paths must be a non-empty list", http.StatusBadRequest)
		}
		seen[s] = true
	}
	chosen := make([]string, 0, len(seen))
	for s := range seen {
		chosen = append(chosen, s)
	}
	sort.Strings(chosen)
	plan := ticketCommitPlan(ticketID, root)
	if b, _ := plan["blocked"].(string); b != "" {
		return fail(b, http.StatusConflict)
	}
	required := plan["required"].([]string)
	if len(required) == 0 {
		return fail("the ticket has no uncommitted files", http.StatusConflict)
	}
	eligible := map[string]bool{}
	for _, k := range []string{"required", "recommended", "optional"} {
		for _, p := range plan[k].([]string) {
			eligible[p] = true
		}
	}
	var bad, missing []string
	for _, p := range chosen {
		if !eligible[p] {
			bad = append(bad, p)
		}
	}
	if len(bad) > 0 {
		if len(bad) > 5 {
			bad = bad[:5]
		}
		return fail("not eligible for this commit: "+strings.Join(bad, ", "), http.StatusBadRequest)
	}
	for _, p := range required {
		if !seen[p] {
			missing = append(missing, p)
		}
	}
	if len(missing) > 0 {
		if len(missing) > 5 {
			missing = missing[:5]
		}
		return fail("required files missing: "+strings.Join(missing, ", "), http.StatusBadRequest)
	}
	if _, _, err := gitOutIn(root, 10*time.Second, append([]string{"add", "-A", "--"}, chosen...)...); err != nil {
		return fail("git add failed", http.StatusInternalServerError)
	}
	message := plan["message"].(string)
	stdout, stderr, err := gitOutIn(root, 120*time.Second, append([]string{"commit", "--only", "-m", message, "--"}, chosen...)...)
	if err == context.DeadlineExceeded {
		return fail("git commit timed out (a commit hook may be slow)", http.StatusInternalServerError)
	}
	if err != nil {
		msg := strings.TrimSpace(stderr + stdout)
		if len(msg) > 800 {
			msg = msg[len(msg)-800:]
		}
		if msg == "" {
			msg = "git commit failed"
		}
		return fail(msg, http.StatusInternalServerError)
	}
	return map[string]any{"ok": true, "commit": runGitIn(root, "rev-parse", "--short", "HEAD"),
		"committed": chosen, "message": message}, http.StatusOK
}

// linkSkillsIntoWorktree creates the canon skills link inside a freshly-created
// worktree so it resolves to CURRENT canon (t-f99b). The skill mirror is
// gitignored (never committed), so a git worktree has no mirror of its own —
// without this, an agent there finds no skills, or (pre-fix) a stale committed
// copy. Done INLINE rather than shelling out to `skills.sh link-worktree`
// because the board may run without `bash` on PATH on Windows (the platform this
// bug affects), where a shell-out would silently no-op. Best-effort; non-fatal.
func linkSkillsIntoWorktree(path string) {
	target := filepath.Join(toolsDir, "..", "skills")
	if !exists(target) {
		return
	}
	for _, rel := range []string{".agents/skills", ".claude/skills"} {
		link := filepath.Join(path, filepath.FromSlash(rel))
		if exists(link) {
			// t-9e55: REPLACE a git-tracked committed canon mirror (carries the
			// sprint/SKILL.md marker) so the worktree serves CURRENT canon —
			// `git worktree add` materializes the stale committed copy before this
			// runs, so the old skip served stale skills. Untrack it in the
			// worktree's own index (main untouched; durable cross-checkout fix is
			// the consumer's `skills.sh refresh` + commit). PRESERVE a genuine
			// project-local skills dir / an already-correct link.
			if isCommittedCanonMirror(path, rel, link) {
				gitInDir(path, "rm", "-r", "--cached", "--quiet", "--", rel)
				_ = os.RemoveAll(link)
			} else {
				continue
			}
		}
		_ = os.MkdirAll(filepath.Dir(link), 0o755)
		if runtime.GOOS == "windows" {
			// Junction (no elevated rights); mklink needs cmd. MSYS path issues
			// don't apply here (Go exec, not Git Bash).
			_ = exec.Command("cmd", "/c", "mklink", "/J", link, target).Run()
		} else {
			_ = os.Symlink(target, link)
		}
	}
}

// isCommittedCanonMirror (t-9e55) reports whether a materialized mirror path in a
// worktree is the git-tracked committed canon mirror t-f99b forbids: tracked in
// the worktree's index AND carrying the canon marker (sprint/SKILL.md). A genuine
// project-local skills dir (untracked, or lacking the marker) returns false and is
// preserved. Parity with server.py's _is_committed_canon_mirror and project.sh.
func isCommittedCanonMirror(worktree, rel, link string) bool {
	out, err := gitInDirOutput(worktree, "ls-files", "--", rel)
	if err != nil || strings.TrimSpace(out) == "" {
		return false
	}
	return exists(filepath.Join(link, "sprint", "SKILL.md"))
}

// gitInDir runs a git command scoped to a specific worktree (best-effort).
func gitInDir(dir string, args ...string) {
	_ = exec.Command("git", append([]string{"-C", dir}, args...)...).Run()
}

// gitInDirOutput runs a git command scoped to a worktree and returns stdout.
func gitInDirOutput(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), err
}

func worktreeIncludePatterns(root string) []string {
	data, err := os.ReadFile(filepath.Join(root, ".worktreeinclude"))
	if err != nil {
		return nil
	}
	var patterns []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			patterns = append(patterns, line)
		}
	}
	return patterns
}

// copyWorktreeIncludeFiles mirrors server.py's _copy_worktreeinclude_files —
// see its docstring for the full rationale (Claude Code's / Codex's own
// .worktreeinclude convention: copy a gitignored file into a fresh worktree
// only when it's both pattern-matched and actually gitignored).
func copyWorktreeIncludeFiles(dest, root string) []string {
	patterns := worktreeIncludePatterns(root)
	if len(patterns) == 0 {
		return nil
	}
	ignored := runGitIn(root, "ls-files", "--others", "--ignored", "--exclude-standard")
	var copied []string
	for _, relpath := range strings.Split(ignored, "\n") {
		relpath = strings.TrimSpace(relpath)
		if relpath == "" {
			continue
		}
		matched := false
		base := filepath.Base(relpath)
		for _, pat := range patterns {
			if ok, _ := filepath.Match(pat, relpath); ok {
				matched = true
				break
			}
			if ok, _ := filepath.Match(pat, base); ok {
				matched = true
				break
			}
		}
		if !matched {
			continue
		}
		src := filepath.Join(root, relpath)
		dst := filepath.Join(dest, relpath)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			continue // best-effort — a copy failure never blocks worktree creation
		}
		data, err := os.ReadFile(src)
		if err != nil {
			continue
		}
		info, err := os.Stat(src)
		mode := os.FileMode(0o644)
		if err == nil {
			mode = info.Mode()
		}
		if os.WriteFile(dst, data, mode) == nil {
			copied = append(copied, relpath)
		}
	}
	return copied
}

func portInUse(port int) bool {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return true
	}
	ln.Close()
	return false
}

// originOK is the CSRF guard for every write (POST/DELETE, t-957a): the Origin
// must be EXACTLY a loopback origin, optionally with a port — the old prefix test
// let http://127.0.0.1.attacker.example through. Mirrors server.py's _origin_ok
// and cockpit-daemon's originIsLoopback (minus [::1], which hostOK rejects too).
// No Origin → allowed (curl, the CLI, tests). RE2's $ is end-of-text only.
var originOKRe = regexp.MustCompile(`^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?$`)

func originOK(origin string) bool {
	return origin == "" || originOKRe.MatchString(origin)
}

func hostOK(host string) bool {
	h := host
	if strings.Contains(h, ":") {
		h, _, _ = net.SplitHostPort(host)
	}
	return h == "127.0.0.1" || h == "localhost"
}

func resolveAppHTML(toolsDir, root string, extraRoots ...string) string {
	candidates := []string{
		filepath.Join(toolsDir, "sprint-check-app", "app.html"),
		filepath.Join(root, "tools", "sprint-check-app", "app.html"),
	}
	for _, extraRoot := range extraRoots {
		candidates = append(candidates, filepath.Join(extraRoot, "tools", "sprint-check-app", "app.html"))
	}
	for _, candidate := range candidates {
		if exists(candidate) {
			return candidate
		}
	}
	return candidates[0]
}

// resolveSprintHeadless finds the sprint-headless binary. SPRINT_HEADLESS_BIN
// overrides (used by tests to point at a stub, t-1781 — replaces a prior
// pattern of overwriting the real on-disk script in place); default is the
// real script under toolsDir/root.
func resolveSprintHeadless(toolsDir, root string, extraRoots ...string) string {
	if b := os.Getenv("SPRINT_HEADLESS_BIN"); b != "" {
		return b
	}
	candidates := []string{
		filepath.Join(toolsDir, "sprint-headless"),
		filepath.Join(root, "tools", "sprint-headless"),
	}
	for _, extraRoot := range extraRoots {
		candidates = append(candidates, filepath.Join(extraRoot, "tools", "sprint-headless"))
	}
	for _, candidate := range candidates {
		if exists(candidate) {
			return candidate
		}
	}
	return candidates[0]
}

// resolveCanonGateTemplate finds canon-gate-template.yml. Deliberately
// independent of SPRINT_HEADLESS_BIN (t-1781) — that override only redirects
// which binary gets *executed*, it must not also redirect where this sibling
// static asset is read from (a stub path outside tools/ has no such file
// next to it).
func resolveCanonGateTemplate(toolsDir, root string, extraRoots ...string) string {
	candidates := []string{
		filepath.Join(toolsDir, "canon-gate-template.yml"),
		filepath.Join(root, "tools", "canon-gate-template.yml"),
	}
	for _, extraRoot := range extraRoots {
		candidates = append(candidates, filepath.Join(extraRoot, "tools", "canon-gate-template.yml"))
	}
	for _, candidate := range candidates {
		if exists(candidate) {
			return candidate
		}
	}
	return candidates[0]
}

// ── Cockpit daemon integration (t-ddc8) ─────────────────────────────────────
// The board never owns a PTY (t-1262 lesson): it discovers/launches the shipped
// cockpit-daemon (which owns the PTY) and the frontend iframes its /cockpit
// page. The board reads only the daemon's addr from the 0600 daemon.json; the
// token stays daemon-side. The spawn argv is fixed — no board/user input is
// interpolated. Behaviour pinned by tests/sprint-check-api.sh.

// resolveCockpitDaemon finds the cockpit-daemon binary. COCKPIT_DAEMON_BIN
// overrides (used by tests to point at a stub); otherwise the first existing of
// cockpitDaemonCandidates, falling back to the first candidate for the
// (not-found) error path.
func resolveCockpitDaemon(toolsDir, root string, extraRoots ...string) string {
	if b := os.Getenv("COCKPIT_DAEMON_BIN"); b != "" {
		return b
	}
	candidates := cockpitDaemonCandidates(toolsDir, root, runtime.GOOS, extraRoots...)
	for _, candidate := range candidates {
		if exists(candidate) {
			return candidate
		}
	}
	return candidates[0]
}

// cockpitDaemonCandidates returns the ordered daemon-binary paths to try for a
// given GOOS. On Windows the shipped, git-tracked tools/cockpit-daemon-win.exe
// (built by scripts/build-zip.sh, mirroring the sprint-check-win.exe convention)
// comes FIRST, then the dev build tools/cockpit-daemon/cockpit-daemon.exe. On
// Unix it is the built tools/cockpit-daemon/cockpit-daemon. goos is a parameter
// (not runtime.GOOS) so the Windows ordering is unit-testable on any host.
func cockpitDaemonCandidates(toolsDir, root, goos string, extraRoots ...string) []string {
	toolsDirs := []string{toolsDir, filepath.Join(root, "tools")}
	for _, er := range extraRoots {
		toolsDirs = append(toolsDirs, filepath.Join(er, "tools"))
	}
	var candidates []string
	if goos == "windows" {
		for _, td := range toolsDirs { // shipped prebuilt first
			candidates = append(candidates, filepath.Join(td, "cockpit-daemon-win.exe"))
		}
		for _, td := range toolsDirs { // dev build fallback
			candidates = append(candidates, filepath.Join(td, "cockpit-daemon", "cockpit-daemon.exe"))
		}
	} else {
		for _, td := range toolsDirs {
			candidates = append(candidates, filepath.Join(td, "cockpit-daemon", "cockpit-daemon"))
		}
	}
	return candidates
}

// cockpitStateDir is where the board expects the daemon to publish daemon.json.
// COCKPIT_STATE_DIR overrides (tests); the default is the daemon's per-user folder (t-68ae).
func cockpitStateDir() string {
	if d := os.Getenv("COCKPIT_STATE_DIR"); d != "" {
		return d
	}
	return common.DefaultCockpitStateDir()
}

// cockpitStateFile is name inside the state folder, or "" when the folder fails common.SecureStateDir: the board
// never reads an address, pid or session list from a folder another account could have written (t-68ae).
func cockpitStateFile(name string) string {
	dir := cockpitStateDir()
	if common.SecureStateDir(dir) != nil {
		return ""
	}
	return filepath.Join(dir, name)
}

func cockpitHealthy(addr string) bool {
	if addr == "" {
		return false
	}
	client := &http.Client{Timeout: 400 * time.Millisecond}
	resp, err := client.Get("http://" + addr + "/healthz")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// discoverCockpitAddr reads the daemon addr from daemon.json (only the addr —
// never the token) and reports whether that daemon answers /healthz.
func discoverCockpitAddr() (string, bool) {
	raw, err := os.ReadFile(cockpitStateFile("daemon.json"))
	if err != nil {
		return "", false
	}
	var st struct {
		Addr string `json:"addr"`
	}
	if json.Unmarshal(raw, &st) != nil {
		return "", false
	}
	return st.Addr, cockpitHealthy(st.Addr)
}

func cockpitDiscover() map[string]any {
	addr, ok := discoverCockpitAddr()
	var addrAny any
	if addr != "" {
		addrAny = addr
	}
	out := map[string]any{"running": ok, "addr": addrAny,
		"shell_uptime_secs": int64(time.Since(shellStartTime).Seconds())}
	if ok {
		for k, v := range cockpitBuildStatus(addr) {
			out[k] = v
		}
	}
	return out
}

// cockpitSessions proxies the daemon's unauthenticated /sessions (t-391a) — the
// active cockpit sessions across EVERY project the one daemon serves (nebula's
// model). Addr-only discovery, no token (mirrors cockpitDiscover). Returns a
// non-nil empty slice when no healthy daemon or on any error, so the board (and
// the parity check) always sees a JSON array.
func cockpitSessions() []map[string]any {
	empty := []map[string]any{}
	addr, ok := discoverCockpitAddr()
	if !ok || addr == "" {
		return empty
	}
	client := &http.Client{Timeout: 600 * time.Millisecond}
	resp, err := client.Get("http://" + addr + "/sessions")
	if err != nil {
		return empty
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return empty
	}
	var sessions []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&sessions); err != nil || sessions == nil {
		return empty
	}
	return sessions
}

// cockpitChanges proxies the daemon's read-only GET /changes (t-5a4b): what changed in a project without
// git since a session's baseline. The daemon applies the /session/start trust rule to root. Mirror of
// server.py cockpit_changes: {"tracked": false, ...} when no healthy daemon or on any error.
func cockpitChanges(root, id string) map[string]any {
	empty := map[string]any{"tracked": false, "files": []any{}, "note": "Changes are not available right now."}
	addr, ok := discoverCockpitAddr()
	if !ok || addr == "" {
		return empty
	}
	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := client.Get("http://" + addr + "/changes?" + url.Values{"id": {id}, "root": {root}}.Encode())
	if err != nil {
		return empty
	}
	defer resp.Body.Close()
	var out map[string]any
	if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&out) != nil || out == nil {
		return empty
	}
	return out
}

// ── t-03a8: `canon status` / `canon sessions` — mirrors server.py's cockpit_status /
// cockpit_status_text / cockpit_sessions_text byte for byte, so the CLI stays curl-only.

var stateOrder = []string{"needs-you", "working", "done", "idle", "running"}

func fmtSecs(v any) string {
	f, ok := v.(float64)
	if i, isInt := v.(int64); isInt {
		f, ok = float64(i), true
	}
	if !ok || f < 0 {
		return "-"
	}
	n := int64(f)
	switch {
	case n >= 86400:
		return fmt.Sprintf("%dd %dh", n/86400, n%86400/3600)
	case n >= 3600:
		return fmt.Sprintf("%dh %dm", n/3600, n%3600/60)
	case n >= 60:
		return fmt.Sprintf("%dm", n/60)
	}
	return fmt.Sprintf("%ds", n)
}

// termSafe is text for a terminal: control characters (escape sequences) become '?';
// width > 0 keeps that many characters.
func termSafe(v any, width int) string {
	s := ""
	if v != nil {
		s = fmt.Sprint(v)
	}
	out := make([]rune, 0, len(s))
	for _, c := range s {
		if c < 32 || c == 127 {
			c = '?'
		}
		out = append(out, c)
	}
	if width > 0 && len(out) > width {
		out = out[:width]
	}
	return string(out)
}

func cockpitStatus() map[string]any {
	d := cockpitDiscover()
	sessions := cockpitSessions()
	byState := map[string]int{}
	for _, x := range sessions {
		st, _ := x["state"].(string)
		if st == "" {
			st = "running"
		}
		byState[st]++
	}
	running, _ := d["running"].(bool)
	stale, _ := d["stale"].(bool)
	return map[string]any{
		"board":    map[string]any{"version": canonVersion(), "uptime_secs": d["shell_uptime_secs"]},
		"daemon":   map[string]any{"running": running, "addr": d["addr"], "stale": stale},
		"sessions": map[string]any{"total": len(sessions), "by_state": byState},
	}
}

func cockpitStatusText(st map[string]any) string {
	b, dm, ss := st["board"].(map[string]any), st["daemon"].(map[string]any), st["sessions"].(map[string]any)
	lines := []string{fmt.Sprintf("board:    running (version %s, up %s)", termSafe(b["version"], 0), fmtSecs(b["uptime_secs"]))}
	if dm["running"] == true {
		note := ""
		if dm["stale"] == true {
			note = " (stale build: restart it with `canon restart`)"
		}
		lines = append(lines, fmt.Sprintf("daemon:   running at %s%s", termSafe(dm["addr"], 0), note))
	} else {
		lines = append(lines, "daemon:   not running")
	}
	byState := ss["by_state"].(map[string]int)
	var order, rest []string
	for _, k := range stateOrder {
		if _, ok := byState[k]; ok {
			order = append(order, k)
		}
	}
	for k := range byState {
		if !slices.Contains(stateOrder, k) {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	var parts []string
	for _, k := range append(order, rest...) {
		parts = append(parts, fmt.Sprintf("%d %s", byState[k], termSafe(k, 0)))
	}
	line := fmt.Sprintf("sessions: %d", ss["total"])
	if len(parts) > 0 {
		line += " (" + strings.Join(parts, ", ") + ")"
	}
	return strings.Join(append(lines, line), "\n") + "\n"
}

func rootKey(p string) string {
	return strings.ToLower(strings.TrimRight(strings.ReplaceAll(p, "\\", "/"), "/"))
}

// cockpitSessionsFor is the live rows for one ticket/scratch id, optionally in one project (t-180d).
func cockpitSessionsFor(sessions []map[string]any, sid, root string) []map[string]any {
	out := []map[string]any{}
	for _, x := range sessions {
		t, _ := x["ticket"].(string)
		pr, _ := x["project_root"].(string)
		if t == sid && (root == "" || rootKey(pr) == rootKey(root)) {
			out = append(out, x)
		}
	}
	return out
}

func cockpitSessionsText(sessions []map[string]any) string {
	if len(sessions) == 0 {
		return "No sessions running.\n"
	}
	rows := [][7]string{{"ID", "STATE", "FOR", "AGENT", "PROJECT", "SIGNAL", "TITLE"}}
	for _, x := range sessions {
		root := strings.TrimRight(strings.ReplaceAll(termSafe(x["project_root"], 0), "\\", "/"), "/")
		state := x["state"]
		if s, _ := state.(string); s == "" {
			state = "running"
		}
		rows = append(rows, [7]string{termSafe(x["ticket"], 8), termSafe(state, 10), fmtSecs(x["state_secs"]),
			termSafe(x["agent"], 8), termSafe(root[strings.LastIndex(root, "/")+1:], 20), termSafe(x["signal"], 12), termSafe(x["title"], 50)})
	}
	var widths [6]int
	for _, r := range rows {
		for i := 0; i < 6; i++ {
			if n := utf8.RuneCountInString(r[i]); n > widths[i] {
				widths[i] = n
			}
		}
	}
	var sb strings.Builder
	for _, r := range rows {
		line := ""
		for i := 0; i < 6; i++ {
			line += r[i] + strings.Repeat(" ", widths[i]-utf8.RuneCountInString(r[i])) + "  "
		}
		line += r[6]
		sb.WriteString(strings.TrimSuffix(line, "  ") + "\n")
	}
	return sb.String()
}

// ── t-d9e6: sessions running when the daemon stopped ──────────────────────────
// Mirrors server.py's cockpit_interrupted*: the daemon moves its leftover live-session
// snapshot into interrupted.json at start and never touches it again; the board owns it
// from there (list + dismiss), with no daemon token.

var interruptedMu sync.Mutex

func interruptedPath() string { return cockpitStateFile("interrupted.json") }

func readInterrupted() []map[string]any {
	var es []map[string]any
	if b, err := os.ReadFile(interruptedPath()); err == nil {
		_ = json.Unmarshal(b, &es)
	}
	return es
}

// interruptedReason says why an entry can't be resumed ("" when it can) — the checks Start makes.
func interruptedReason(id, root, cwd, agent string) string {
	if strings.HasPrefix(id, "s-") && agent == "term" {
		return "terminal — it ended when the daemon stopped; open a new one with the Terminal button"
	}
	if strings.HasPrefix(id, "s-") {
		return "scratch session — its conversation can't be resumed; its changes stay in " + cwd
	}
	b, err := os.ReadFile(filepath.Join(root, ".tickets", id, "ticket.md"))
	if err != nil {
		return "ticket no longer exists in " + root
	}
	if frontmatterStatus(string(b)) == "closed" {
		return "ticket is closed"
	}
	if fi, err := os.Stat(cwd); cwd == "" || err != nil || !fi.IsDir() {
		return "working directory " + cwd + " no longer exists"
	}
	return ""
}

func cockpitInterrupted() []map[string]any {
	live := map[string]bool{}
	for _, s := range cockpitSessions() {
		live[fmt.Sprint(s["ticket"])+"\x00"+fmt.Sprint(s["project_root"])] = true
	}
	out := []map[string]any{}
	for _, raw := range readInterrupted() {
		e := map[string]any{}
		str := map[string]string{}
		for _, k := range []string{"id", "project_root", "cwd", "agent", "started"} {
			v, _ := raw[k].(string)
			str[k] = v
			e[k] = v
		}
		if !common.SessionIDRe.MatchString(str["id"]) || str["project_root"] == "" || live[str["id"]+"\x00"+str["project_root"]] {
			continue
		}
		reason := interruptedReason(str["id"], str["project_root"], str["cwd"], str["agent"])
		e["resumable"] = reason == ""
		e["reason"] = reason
		out = append(out, e)
	}
	return out
}

func cockpitInterruptedDismiss(id string) map[string]any {
	if !common.SessionIDRe.MatchString(id) {
		return map[string]any{"ok": false, "error": "invalid session id"}
	}
	interruptedMu.Lock()
	defer interruptedMu.Unlock()
	es := readInterrupted()
	kept := []map[string]any{}
	for _, e := range es {
		if v, _ := e["id"].(string); v != id {
			kept = append(kept, e)
		}
	}
	p := interruptedPath()
	if len(kept) == 0 {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return map[string]any{"ok": false, "error": err.Error()}
		}
	} else if len(kept) != len(es) {
		b, _ := json.MarshalIndent(kept, "", "  ")
		tmp := p + ".tmp"
		if err := os.WriteFile(tmp, b, 0o600); err != nil {
			return map[string]any{"ok": false, "error": err.Error()}
		}
		if err := os.Rename(tmp, p); err != nil {
			return map[string]any{"ok": false, "error": err.Error()}
		}
	}
	return map[string]any{"ok": true}
}

// readDaemonPID reads the daemon's own pid from daemon.json (t-44d9) so the board
// can force-restart it via OS process control — never the boot token (t-ddc8).
func readDaemonPID() int {
	raw, err := os.ReadFile(cockpitStateFile("daemon.json"))
	if err != nil {
		return 0
	}
	var st struct {
		Pid string `json:"pid"`
	}
	if json.Unmarshal(raw, &st) != nil {
		return 0
	}
	n, _ := strconv.Atoi(st.Pid)
	return n
}

// killDaemonPID is the cross-platform pid-kill shared by cockpitRestart/
// cockpitStop (t-44d9/t-a30c): unix SIGTERM (the daemon's graceful handler
// reaps agent children); Windows `taskkill /T` (tree-kill reaps children
// directly). Waits for it to exit (its handler clears daemon.json / stops
// answering). OS process control only, never the boot token (t-ddc8 preserved).
func killDaemonPID(pid int) {
	if runtime.GOOS == "windows" {
		_ = exec.Command("taskkill", "/PID", strconv.Itoa(pid), "/T", "/F").Run()
	} else {
		_ = exec.Command("kill", "-TERM", strconv.Itoa(pid)).Run()
	}
	for i := 0; i < 50; i++ {
		if _, ok := discoverCockpitAddr(); !ok {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// cockpitRestart force-restarts the cockpit daemon (t-44d9): warn (busy) when
// sessions are live unless force, then killDaemonPID and relaunch via
// ensureCockpit.
func cockpitRestart(force bool) map[string]any {
	if n := len(cockpitSessions()); n > 0 && !force {
		return map[string]any{"ok": false, "busy": true, "sessions": n}
	}
	if pid := readDaemonPID(); pid > 0 {
		killDaemonPID(pid)
	}
	out := ensureCockpit()
	// Honest signal: only "restarted" if a fresh daemon actually launched — if the
	// kill didn't take and ensureCockpit reused the live one, say so (reviewer t-44d9).
	out["restarted"] = boolValue(out["launched"])
	return out
}

// cockpitStop stops the cockpit daemon WITHOUT relaunching it (t-a30c) — saves
// a manual Ctrl-C in the terminal it was started from. Same busy-confirm gate
// and pid-kill as cockpitRestart, minus the ensureCockpit() relaunch. The
// daemon still comes back on demand next time a cockpit tab is opened
// (ensureCockpit), so this is not a permanent kill switch. Never touches the
// daemon's token-gated /shutdown — OS process control only (t-ddc8).
func cockpitStop(force bool) map[string]any {
	if n := len(cockpitSessions()); n > 0 && !force {
		return map[string]any{"ok": false, "busy": true, "sessions": n}
	}
	pid := readDaemonPID()
	if pid <= 0 {
		return map[string]any{"ok": true, "stopped": false, "running": false}
	}
	killDaemonPID(pid)
	_, running := discoverCockpitAddr()
	return map[string]any{"ok": true, "stopped": !running, "running": running}
}

// cockpitBinaryMtime is the on-disk daemon binary's mtime (unix) — the "latest"
// build the board would launch. 0 if unresolvable. (t-74d6)
func cockpitBinaryMtime() int64 {
	st, err := os.Stat(cockpitDaemonBin)
	if err != nil {
		return 0
	}
	return st.ModTime().Unix()
}

// cockpitRunningBuild fetches the RUNNING daemon's unauthenticated /version JSON
// ({version, exe_mtime}). nil if unreachable or not JSON (a daemon predating
// this build). The board never reads the daemon token; /version needs none.
var buildStampRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

func cockpitRunningBuild(addr string) map[string]any {
	if addr == "" {
		return nil
	}
	client := &http.Client{Timeout: 400 * time.Millisecond}
	resp, err := client.Get("http://" + addr + "/version")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	var v struct {
		Version         string `json:"version"`
		Commit          any    `json:"commit"`
		ExeMtime        int64  `json:"exe_mtime"`
		UptimeSecs      int64  `json:"uptime_secs"`
		DebugEnabled    bool   `json:"debug_enabled"`
		IdleTimeout     int64  `json:"idle_timeout_secs"`
		IdleTimeoutMain int64  `json:"idle_timeout_main_secs"`
	}
	if json.NewDecoder(resp.Body).Decode(&v) != nil {
		return nil
	}
	// t-4487: the build stamp `cockpit-daemon --version` prints: a plain stamp (hex, or "dev") or "" for an older daemon, a non-string, odd text
	// or an oversized value (parity with server.py)
	commit, _ := v.Commit.(string)
	if !buildStampRe.MatchString(commit) {
		commit = ""
	}
	return map[string]any{"version": v.Version, "commit": commit, "exe_mtime": v.ExeMtime, "uptime_secs": v.UptimeSecs, "debug_enabled": v.DebugEnabled,
		"idle_timeout_secs": v.IdleTimeout, "idle_timeout_main_secs": v.IdleTimeoutMain}
}

// cockpitSetDebug forwards the Admin panel's debug-logging toggle to the
// daemon's POST /admin/debug (t-ffb9). Token-free, mirroring
// cockpitRunningBuild above — the board never holds the daemon's token
// (t-ddc8); the daemon's own loopback-only bind is what gates this endpoint,
// not per-request auth. Parity with server.py's cockpit_set_debug.
func cockpitSetDebug(enabled bool) map[string]any {
	addr, ok := discoverCockpitAddr()
	if !ok {
		return map[string]any{"ok": false, "error": "daemon unavailable"}
	}
	body, _ := json.Marshal(map[string]bool{"enabled": enabled})
	client := &http.Client{Timeout: 600 * time.Millisecond}
	resp, err := client.Post("http://"+addr+"/admin/debug", "application/json", bytes.NewReader(body))
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	defer resp.Body.Close()
	var out struct {
		Enabled bool `json:"enabled"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return map[string]any{"ok": true, "enabled": out.Enabled}
}

// cockpitBuildStatus reports {stale, running_build, latest_build} for a healthy
// daemon. Stale when the running exec-mtime differs from the on-disk binary's,
// or when the daemon exposes no JSON /version. Parity with server.py's
// _cockpit_build_status — the drift signal is the exec-mtime, NOT the version
// string (local `dev` builds all match). (t-74d6)
func cockpitBuildStatus(addr string) map[string]any {
	latestMtime := cockpitBinaryMtime()
	latest := map[string]any{"exe_mtime": latestMtime}
	running := cockpitRunningBuild(addr)
	if running == nil {
		return map[string]any{"stale": true, "running_build": nil, "latest_build": latest}
	}
	rm, _ := running["exe_mtime"].(int64)
	stale := latestMtime != 0 && rm != latestMtime
	return map[string]any{"stale": stale, "running_build": running, "latest_build": latest}
}

// ensureCockpit returns a running daemon's addr, launching one on demand if
// none is healthy. The spawn argv is fixed (["-addr","127.0.0.1:0"]); the
// project root + sprint bin are passed via env, never argv.
func ensureCockpit() map[string]any {
	if addr, ok := discoverCockpitAddr(); ok {
		out := map[string]any{"running": true, "addr": addr, "launched": false}
		for k, v := range cockpitBuildStatus(addr) {
			out[k] = v
		}
		return out
	}
	if !exists(cockpitDaemonBin) {
		return map[string]any{"running": false, "addr": nil, "error": "cockpit daemon binary not found; run `canon update` to fetch it"}
	}
	stateDir := cockpitStateDir()
	if err := common.SecureStateDir(stateDir); err != nil {
		return map[string]any{"running": false, "addr": nil, "error": err.Error()}
	}
	os.Remove(filepath.Join(stateDir, "daemon.json")) // clear any stale addr
	cmd := exec.Command(cockpitDaemonBin, "-addr", "127.0.0.1:0")
	env := append(os.Environ(),
		"COCKPIT_STATE_DIR="+stateDir,
		"COCKPIT_PROJECT_ROOT="+projectRoot,
	)
	if cockpitSprintBin != "" {
		env = append(env, "COCKPIT_SPRINT_BIN="+cockpitSprintBin)
	}
	cmd.Env = env
	detachDaemon(cmd)
	if err := cmd.Start(); err != nil {
		return map[string]any{"running": false, "addr": nil, "error": err.Error()}
	}
	// Detach: don't Wait — the daemon must outlive the board (agent survives the
	// browser tab, nebula's model). Reap the child in the background so a fast
	// exit (e.g. bind failure) doesn't leave a zombie.
	go func() { _ = cmd.Wait() }()
	for i := 0; i < 50; i++ {
		if addr, ok := discoverCockpitAddr(); ok {
			out := map[string]any{"running": true, "addr": addr, "launched": true}
			for k, v := range cockpitBuildStatus(addr) {
				out[k] = v
			}
			return out
		}
		time.Sleep(100 * time.Millisecond)
	}
	return map[string]any{"running": false, "addr": nil, "error": "daemon did not become ready"}
}

// ── Headless grading runs (t-200b) ──────────────────────────────────────────

// ticketGate reads a ticket's headless gate mode ("eval" or "full") from
// frontmatter. Absent = "full" (the default 3-gate pipeline), mirroring ci.
func ticketGate(ticketID string) string {
	raw, err := os.ReadFile(filepath.Join(ticketsDir, ticketID, "ticket.md"))
	if err != nil {
		return "full"
	}
	if m := frontmatterRe.FindStringSubmatchIndex(string(raw)); m != nil {
		fm := string(raw)[m[2]:m[3]]
		for _, match := range fieldRe.FindAllStringSubmatch(fm, -1) {
			if match[1] == "gate" {
				if unquoteYAMLScalar(strings.TrimSpace(match[2])) == "eval" {
					return "eval"
				}
				return "full"
			}
		}
	}
	return "full"
}

func runHeadless(ticketID, baseRef string) {
	// Pick the eval-only tool when the ticket's gate is "eval", else the full pipeline.
	// SPRINT_HEADLESS_EVAL_BIN overrides (t-1781), mirroring SPRINT_HEADLESS_BIN above.
	tool := sprintHeadless
	if ticketGate(ticketID) == "eval" {
		if b := os.Getenv("SPRINT_HEADLESS_EVAL_BIN"); b != "" {
			tool = b
		} else {
			tool = filepath.Join(filepath.Dir(sprintHeadless), "sprint-headless-eval")
		}
	}
	output, err := exec.Command(tool, ticketID, "--base-ref", baseRef).CombinedOutput()
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			output = []byte(fmt.Sprintf("Error: could not start %s: %v", filepath.Base(tool), err))
			exitCode = 1
		}
	}
	headlessRunsMu.Lock()
	defer headlessRunsMu.Unlock()
	headlessRuns[ticketID]["status"] = "done"
	headlessRuns[ticketID]["output"] = string(output)
	headlessRuns[ticketID]["exit_code"] = exitCode
}

func startHeadlessRun(ticketID, baseRef string) map[string]any {
	headlessRunsMu.Lock()
	if existing, ok := headlessRuns[ticketID]; ok && existing["status"] == "running" {
		headlessRunsMu.Unlock()
		return getHeadlessRunState(ticketID)
	}
	headlessRuns[ticketID] = map[string]any{"status": "running", "output": "", "exit_code": nil, "started_at": time.Now()}
	headlessRunsMu.Unlock()
	go runHeadless(ticketID, baseRef)
	return getHeadlessRunState(ticketID)
}

func getHeadlessRunState(ticketID string) map[string]any {
	headlessRunsMu.Lock()
	defer headlessRunsMu.Unlock()
	state, ok := headlessRuns[ticketID]
	if !ok {
		return map[string]any{"status": "idle"}
	}
	result := map[string]any{"status": state["status"], "output": state["output"], "exit_code": state["exit_code"]}
	if state["status"] == "running" {
		result["elapsed"] = time.Since(state["started_at"].(time.Time)).Seconds()
	}
	return result
}

// ── GitHub workflow (t-d271): each route runs one tkt command from the project root ─────────
// Parity with server.py's run_tkt / start_merge_run / get_merge_run_state. The board adds no logic: tkt owns every
// check. TKT_BIN overrides the path (tests); on Windows tkt.cmd runs the bash script through Git for Windows.

const tktTail = 16384

// intakeMax: the most `tkt sync-issues --dry-run --json` output the board will read whole (about 10,000 issues).
const intakeMax = 4 << 20

var prRe = regexp.MustCompile(`^[0-9]{1,9}$`)

func resolveTkt() string {
	if b := os.Getenv("TKT_BIN"); b != "" {
		return b
	}
	dir := filepath.Dir(sprintHeadless)
	if runtime.GOOS == "windows" {
		if c := filepath.Join(dir, "tkt.cmd"); exists(c) {
			return c
		}
	}
	return filepath.Join(dir, "tkt")
}

func tailString(s string) string {
	if len(s) > tktTail {
		return s[len(s)-tktTail:]
	}
	return s
}

func runTkt(root string, args []string) map[string]any { return runTktMax(root, args, 0) }

// runTktMax: maxBytes 0 keeps only the last tktTail bytes (a log for a person). A document someone parses must not be cut:
// with maxBytes > 0 a successful run's whole output is returned, or ok:false saying it is too large, never a tail of it.
func runTktMax(root string, args []string, maxBytes int) map[string]any {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, resolveTkt(), args...)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	code := 0
	if ctx.Err() == context.DeadlineExceeded {
		out, code = []byte(fmt.Sprintf("tkt %s did not finish within 300 s", args[0])), 124
	} else if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			out, code = []byte(fmt.Sprintf("could not run tkt: %v", err)), 1
		}
	}
	if maxBytes > 0 && code == 0 {
		if len(out) > maxBytes {
			return map[string]any{"ok": false, "exit_code": 1, "output": fmt.Sprintf("the issue listing is too large to show (%d bytes; the limit is %d)", len(out), maxBytes)}
		}
		return map[string]any{"ok": true, "exit_code": 0, "output": string(out)}
	}
	return map[string]any{"ok": code == 0, "exit_code": code, "output": tailString(string(out))}
}

// issueNumbers: "5,7" from a JSON array of 1 to 200 whole numbers between 1 and 999999999; false for anything else.
func issueNumbers(v any) (string, bool) {
	list, ok := v.([]any)
	if !ok || len(list) == 0 || len(list) > 200 {
		return "", false
	}
	parts := make([]string, 0, len(list))
	for _, e := range list {
		f, ok := e.(float64)
		if !ok || f != math.Trunc(f) || f < 1 || f > 999999999 {
			return "", false
		}
		parts = append(parts, strconv.Itoa(int(f)))
	}
	return strings.Join(parts, ","), true
}

// prArg: nil slice + true for no PR, ["--pr", n] for digits, false for anything else (the caller answers 400).
func prArg(v any) ([]string, bool) {
	if v == nil {
		return []string{}, true
	}
	if _, isBool := v.(bool); isBool {
		return nil, false
	}
	s := fmt.Sprint(v)
	if f, ok := v.(float64); ok {
		if f != float64(int64(f)) {
			return nil, false
		}
		s = strconv.FormatInt(int64(f), 10)
	}
	if s == "" {
		return []string{}, true
	}
	if !prRe.MatchString(s) {
		return nil, false
	}
	return []string{"--pr", s}, true
}

type mergeKey struct{ root, id string }

var (
	mergeRuns   = map[mergeKey]map[string]any{}
	mergeCmds   = map[mergeKey]*exec.Cmd{}
	mergeRunsMu sync.Mutex
)

// mergeLimit: a hung job is stopped, so it cannot block every later start. CANON_MERGE_LIMIT_SECONDS is for tests.
func mergeLimit() time.Duration {
	if n, err := strconv.Atoi(os.Getenv("CANON_MERGE_LIMIT_SECONDS")); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return time.Hour
}

// stopMergeRun: TERM to tkt, which merge-pr traps while the tests run to stop their whole group and not merge (a TERM
// during the final gh pr merge may come too late). On Windows tkt.cmd starts bash, so the whole tree is ended with
// taskkill /T /F. A stop sent before the process is registered is kept and applied then. Parity: server.py.
func stopMergeRun(root, id string) map[string]any {
	key := mergeKey{root, id}
	mergeRunsMu.Lock()
	cmd := mergeCmds[key]
	if st, ok := mergeRuns[key]; ok && cmd == nil && st["status"] == "running" {
		st["stop"] = true
	}
	mergeRunsMu.Unlock()
	if cmd != nil && cmd.Process != nil {
		signalMerge(cmd)
	}
	return getMergeRunState(root, id)
}

func signalMerge(cmd *exec.Cmd) {
	if runtime.GOOS == "windows" {
		exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid)).Run()
		return
	}
	cmd.Process.Signal(syscall.SIGTERM)
}

// runMerge reads merge-pr's output line by line while it runs, so the board can show its progress lines.
func runMerge(key mergeKey, args []string) {
	code := 1
	cmd := exec.Command(resolveTkt(), args...)
	cmd.Dir = key.root
	cmd.Env = append(os.Environ(), "CANON_PROGRESS_SECONDS=5")
	pipe, err := cmd.StdoutPipe()
	if err == nil {
		cmd.Stderr = cmd.Stdout
		err = cmd.Start()
	}
	if err != nil {
		mergeRunsMu.Lock()
		mergeRuns[key]["output"] = fmt.Sprintf("could not run tkt: %v\n", err)
		mergeRuns[key]["status"], mergeRuns[key]["exit_code"] = "done", 1
		mergeRunsMu.Unlock()
		return
	}
	mergeRunsMu.Lock()
	mergeCmds[key] = cmd
	stopNow := mergeRuns[key]["stop"] == true
	mergeRunsMu.Unlock()
	if stopNow {
		signalMerge(cmd)
	}
	timer := time.AfterFunc(mergeLimit(), func() { stopMergeRun(key.root, key.id) })
	// Fixed-size chunks, not lines: one huge line (a \r-redrawn progress bar) can neither stall the reader (a Scanner
	// stops at its token limit and leaves the pipe full) nor grow memory; only the tail is kept.
	buf := make([]byte, 4096)
	for {
		n, rerr := pipe.Read(buf)
		if n > 0 {
			mergeRunsMu.Lock()
			mergeRuns[key]["output"] = tailString(mergeRuns[key]["output"].(string) + string(buf[:n]))
			mergeRunsMu.Unlock()
		}
		if rerr != nil {
			break
		}
	}
	timer.Stop()
	if werr := cmd.Wait(); werr == nil {
		code = 0
	} else if ee, ok := werr.(*exec.ExitError); ok {
		code = ee.ExitCode()
	}
	mergeRunsMu.Lock()
	mergeRuns[key]["status"], mergeRuns[key]["exit_code"] = "done", code
	mergeRunsMu.Unlock()
}

func startMergeRun(root, id string, pr []string) map[string]any {
	key := mergeKey{root, id}
	mergeRunsMu.Lock()
	if st, ok := mergeRuns[key]; ok && st["status"] == "running" {
		mergeRunsMu.Unlock()
		return getMergeRunState(root, id)
	}
	mergeRuns[key] = map[string]any{"status": "running", "output": "", "exit_code": nil, "started_at": time.Now()}
	delete(mergeCmds, key) // t-718b: a stop before the new process registers must not reach the previous, finished one
	mergeRunsMu.Unlock()
	go runMerge(key, append([]string{"merge-pr", id, "--yes"}, pr...))
	return getMergeRunState(root, id)
}

// githubStatus is what the board polls per card out on GitHub: cached per (root, ticket) for 30 s, so any number of
// open tabs costs one gh call per ticket per 30 s. Parity with server.py's github_status.
type statusHit struct {
	at  time.Time
	res map[string]any
}

var statusCache = map[mergeKey]statusHit{}

const statusTTL = 30 * time.Second

func githubStatus(root, id string) map[string]any {
	key := mergeKey{root, id}
	mergeRunsMu.Lock()
	if h, ok := statusCache[key]; ok && time.Since(h.at) < statusTTL {
		mergeRunsMu.Unlock()
		return h.res
	}
	mergeRunsMu.Unlock()
	res := runTkt(root, []string{"github-status", id, "--json"})
	if res["ok"] == true {
		var st map[string]any
		if json.Unmarshal([]byte(res["output"].(string)), &st) == nil {
			res["status"] = st
		} else {
			res = map[string]any{"ok": false, "exit_code": res["exit_code"], "output": res["output"]}
		}
	}
	mergeRunsMu.Lock()
	statusCache[key] = statusHit{time.Now(), res}
	mergeRunsMu.Unlock()
	return res
}

// githubDoctor: t-90a3's readiness checks for Factory › GitHub (t-9641), parsed into "doctor".
func githubDoctor(root string) map[string]any {
	res := runTkt(root, []string{"github-doctor", "--json"})
	if res["ok"] == true {
		var d map[string]any
		if json.Unmarshal([]byte(res["output"].(string)), &d) == nil {
			res["doctor"] = d
		} else {
			res = map[string]any{"ok": false, "exit_code": res["exit_code"], "output": res["output"]}
		}
	}
	return res
}

var digitsRe = regexp.MustCompile(`^[0-9]{1,8}$`)

// githubIntake: Factory › GitHub's Intake box (t-9641). "intake" is `tkt sync-issues --dry-run --json` (the issues
// labelled canon that no ticket links to yet); "last_synced" is the newest github.synced event for this project, or nil.
// Event lines are untrusted: a count that is not digits is not shown.
func githubIntake(root string) map[string]any {
	res := runTktMax(root, []string{"sync-issues", "--dry-run", "--json"}, intakeMax)
	if res["ok"] == true {
		var d map[string]any
		if json.Unmarshal([]byte(res["output"].(string)), &d) != nil {
			return map[string]any{"ok": false, "exit_code": res["exit_code"], "output": res["output"]}
		}
		res = map[string]any{"ok": true, "exit_code": 0, "intake": d}
	}
	res["last_synced"] = nil
	if ev, ok := events.Latest(events.Home(), "github.synced", resolvedOrAbs(root), func(e events.Event) bool { return digitsRe.MatchString(e.Data["count"]) }); ok {
		res["last_synced"] = map[string]any{"ts": ev.TS.Format("2006-01-02T15:04:05.000Z"), "count": ev.Data["count"]}
	}
	return res
}

func getMergeRunState(root, id string) map[string]any {
	mergeRunsMu.Lock()
	defer mergeRunsMu.Unlock()
	st, ok := mergeRuns[mergeKey{root, id}]
	if !ok {
		return map[string]any{"status": "idle"}
	}
	res := map[string]any{"status": st["status"], "output": st["output"], "exit_code": st["exit_code"]}
	if st["status"] == "running" {
		res["elapsed"] = time.Since(st["started_at"].(time.Time)).Seconds()
	}
	return res
}

var staticNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*\.(css|js)$`)

// serveStatic serves the board's own CSS and JS modules (t-9b2d) from the static/ folder beside
// app.html. A flat name only (no '/', '..' or '%'; Go has already decoded the path), and the real
// file must be static/<name> itself, so a link planted there cannot lead out. no-store like the
// HTML: a sheet cached from before `canon update` would mix old and new.
func serveStatic(w http.ResponseWriter, r *http.Request, name string) {
	m := staticNameRe.FindStringSubmatch(name)
	if m == nil {
		http.NotFound(w, r)
		return
	}
	dir, err := filepath.EvalSymlinks(filepath.Join(filepath.Dir(appHTML), "static"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	real, err := filepath.EvalSymlinks(filepath.Join(dir, name))
	if err != nil || real != filepath.Join(dir, name) {
		http.NotFound(w, r)
		return
	}
	if fi, err := os.Stat(real); err != nil || !fi.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	ctype := "text/css; charset=utf-8"
	if m[1] == "js" {
		ctype = "text/javascript; charset=utf-8"
	}
	w.Header().Set("Cache-Control", "no-store")
	serveFile(w, real, ctype)
}

func serveFile(w http.ResponseWriter, path, contentType string) {
	body, err := os.ReadFile(path)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	if strings.HasPrefix(contentType, "text/html") {
		w.Header().Set("Cache-Control", "no-store") // t-07c8: always serve fresh (local dev tool)
	}
	w.Write(body)
}

func sendText(w http.ResponseWriter, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(text)))
	w.Write([]byte(text))
}

func sendJSON(w http.ResponseWriter, data any) {
	body, _ := json.Marshal(data)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.Write(body)
}

func sendJSONStatus(w http.ResponseWriter, data any, status int) {
	body, _ := json.Marshal(data)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	w.Write(body)
}

// ── Canon Cockpit project registry (t-9917) ───────────────────────────────
// The project registry: ~/.canon/cockpit/projects.json,
// a JSON array of {id,path,name,description,added}. id = first 12 hex of
// sha256(resolved abs path). Field order pinned via the struct tags below to
// keep the layout earlier installs wrote (tools/canon and the daemon read it). Paths +
// descriptions only, no secrets (DECISIONS t-06cc: no encryption).

type registryProject struct {
	ID          string `json:"id"`
	Path        string `json:"path"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Added       string `json:"added"`
}

func registryDir() string {
	home := os.Getenv("CANON_HOME")
	if home == "" {
		h, _ := os.UserHomeDir()
		home = filepath.Join(h, ".canon")
	}
	return filepath.Join(home, "cockpit")
}

func registryFile() string { return filepath.Join(registryDir(), "projects.json") }

func registryID(absPath string) string {
	sum := sha256.Sum256([]byte(absPath))
	return hex.EncodeToString(sum[:])[:12]
}

func registryLoad() []registryProject {
	data, err := os.ReadFile(registryFile())
	if err != nil {
		return []registryProject{}
	}
	var entries []registryProject
	if json.Unmarshal(data, &entries) != nil {
		return []registryProject{}
	}
	return entries
}

func registrySave(entries []registryProject) error {
	d := registryDir()
	if err := os.MkdirAll(d, 0o700); err != nil {
		return err
	}
	// The layout earlier installs wrote: 2-space indent, non-ASCII kept, trailing newline.
	// json.MarshalIndent HTML-escapes & < > (→ \u0026 …); Python does not, so a
	// path/description containing those chars would diverge (t-9917 review finding).
	// json.Encoder with SetEscapeHTML(false) + SetIndent produces the literal chars.
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(entries); err != nil { // Encode already appends a trailing "\n"
		return err
	}
	body := buf.Bytes()
	if err := os.WriteFile(registryFile(), body, 0o600); err != nil {
		return err
	}
	return nil
}

// t-7e36: Admin > Model Tiers registry. Board-wide (not per-project, not
// daemon-owned), mirrors server.py's load_model_tiers/save_model_tiers. A
// model id is validated here because it later becomes a
// ~/.codex/agents/<id>.toml filename in the follow-up ticket (t-ef27).
func loadModelTiers() map[string]any {
	empty := map[string]any{
		"defaults": map[string]any{"eval": map[string]any{}, "light": map[string]any{}},
		"models":   map[string]any{"anthropic": []any{}, "openai": []any{}},
	}
	var found []map[string]any
	for _, p := range []string{modelTiersUserFile(), modelTiersPath} {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var parsed map[string]any
		if json.Unmarshal(data, &parsed) == nil && parsed != nil {
			found = append(found, parsed)
		}
	}
	if len(found) == 0 {
		return empty
	}
	// t-d40b: the same for the Refresh sources: a user file saved before they existed gets the seed's list.
	if _, ok := found[0]["sources"]; !ok && len(found) > 1 {
		if u, ok := found[len(found)-1]["sources"]; ok {
			found[0]["sources"] = u
		}
	}
	return found[0]
}

// ── User themes (t-f889) — mirrors server.py's list_themes/open_themes_folder ──
// $CANON_HOME/themes/*.json: files anyone can drop there, so untrusted. Every rule and reason string matches
// static/theme-data.js; tests/theme-files-parity.sh holds both to theme.schema.json (never read at runtime).
var (
	themeKeys   = []string{"bg", "surface", "border", "text", "body", "muted", "accent", "ok", "warn", "bad", "info", "term"}
	themeFileRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,29}\.json$`)
	themeNameRe = regexp.MustCompile(`^[A-Za-z0-9 ._()+-]{1,40}$`)
	themeHexRe  = regexp.MustCompile(`^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$`)
)

const (
	themeMaxBytes = 16384
	themeMaxFiles = 50
	themeMaxDepth = 8
)

type userTheme struct {
	ID     string            `json:"id"`
	File   string            `json:"file"`
	Name   string            `json:"name"`
	Mode   string            `json:"mode"`
	Colors map[string]string `json:"colors"`
}

type rejectedTheme struct {
	File   string `json:"file"`
	Reason string `json:"reason"`
}

type themeList struct {
	Dir      string          `json:"dir"`
	Themes   []userTheme     `json:"themes"`
	Rejected []rejectedTheme `json:"rejected"`
	Error    string          `json:"error,omitempty"`
}

func themesDir() string {
	home := os.Getenv("CANON_HOME")
	if home == "" {
		h, _ := os.UserHomeDir()
		home = filepath.Join(h, ".canon")
	}
	return filepath.Join(home, "themes")
}

// themeCheck: a parsed theme file -> the theme, or a reason.
func themeCheck(data any) (userTheme, string) {
	obj, ok := data.(map[string]any)
	_, hasName := obj["name"]
	_, hasMode := obj["mode"]
	_, hasColors := obj["colors"]
	if !ok || len(obj) != 3 || !hasName || !hasMode || !hasColors {
		return userTheme{}, "must be an object with exactly name, mode and colors"
	}
	name, ok := obj["name"].(string)
	if !ok || !themeNameRe.MatchString(name) {
		return userTheme{}, "name must be 1-40 letters, digits, spaces or . _ ( ) + -"
	}
	mode, ok := obj["mode"].(string)
	if !ok || (mode != "light" && mode != "dark") {
		return userTheme{}, "mode must be light or dark"
	}
	colors, ok := obj["colors"].(map[string]any)
	if !ok || len(colors) != len(themeKeys) {
		return userTheme{}, "colors must have exactly the 12 keys"
	}
	for _, k := range themeKeys {
		if _, has := colors[k]; !has {
			return userTheme{}, "colors must have exactly the 12 keys"
		}
	}
	out := map[string]string{}
	for _, k := range themeKeys {
		v, ok := colors[k].(string)
		if !ok || !themeHexRe.MatchString(v) {
			return userTheme{}, "colors." + k + " must be #rgb or #rrggbb"
		}
		out[k] = v
	}
	return userTheme{Name: name, Mode: mode, Colors: out}, ""
}

// themeRead: one directory entry -> the theme, or a reason. Checks run in server.py's order.
func themeRead(path string) (userTheme, string) {
	st, err := os.Lstat(path)
	if err != nil {
		return userTheme{}, "cannot be read"
	}
	if st.Mode()&os.ModeSymlink != 0 {
		return userTheme{}, "symbolic links are not read"
	}
	if !st.Mode().IsRegular() {
		return userTheme{}, "not a regular file"
	}
	f, err := themeOpen(path)
	if err != nil {
		return userTheme{}, "cannot be read"
	}
	defer f.Close()
	// the file must still be the one Lstat saw (swapped for a link in between: refused)
	if fst, err := f.Stat(); err != nil || !os.SameFile(st, fst) {
		return userTheme{}, "not a regular file"
	}
	raw, err := io.ReadAll(io.LimitReader(f, themeMaxBytes+1))
	if err != nil {
		return userTheme{}, "cannot be read"
	}
	if len(raw) > themeMaxBytes {
		return userTheme{}, "larger than 16 KiB"
	}
	if bytes.HasPrefix(raw, []byte{0xef, 0xbb, 0xbf}) {
		return userTheme{}, "starts with a byte order mark"
	}
	if !utf8.Valid(raw) {
		return userTheme{}, "not valid UTF-8"
	}
	if themeTooDeep(raw) {
		return userTheme{}, "nested too deeply"
	}
	// UseNumber: 1e999 is valid JSON (server.py reads it as inf), not a decode error
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var data any
	if err := dec.Decode(&data); err != nil {
		return userTheme{}, "not valid JSON"
	}
	if _, err := dec.Token(); err != io.EOF {
		return userTheme{}, "not valid JSON"
	}
	return themeCheck(data)
}

// themeTooDeep: brackets outside strings deeper than themeMaxDepth
// (its parser hits RecursionError where Go's does not, so both refuse deep nesting first).
func themeTooDeep(raw []byte) bool {
	depth, inStr, esc := 0, false, false
	for _, ch := range raw {
		switch {
		case inStr && esc:
			esc = false
		case inStr && ch == '\\':
			esc = true
		case inStr && ch == '"':
			inStr = false
		case inStr:
		case ch == '"':
			inStr = true
		case ch == '[' || ch == '{':
			depth++
			if depth > themeMaxDepth {
				return true
			}
		case ch == ']' || ch == '}':
			depth--
		}
	}
	return false
}

func listThemes() themeList {
	d := themesDir()
	out := themeList{Dir: d, Themes: []userTheme{}, Rejected: []rejectedTheme{}}
	entries, err := os.ReadDir(d)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			out.Error = "the themes folder cannot be read"
		}
		return out
	}
	var files []string
	for _, e := range entries {
		n := e.Name()
		if utf8.ValidString(n) && strings.HasSuffix(n, ".json") {
			files = append(files, n)
		}
	}
	sort.Strings(files)
	for i, n := range files {
		if i >= themeMaxFiles {
			out.Rejected = append(out.Rejected, rejectedTheme{n, "too many theme files (at most 50)"})
			continue
		}
		if !themeFileRe.MatchString(n) {
			out.Rejected = append(out.Rejected, rejectedTheme{n, "file name must be lowercase letters, digits and dashes (at most 30)"})
			continue
		}
		t, reason := themeRead(filepath.Join(d, n))
		if reason != "" {
			out.Rejected = append(out.Rejected, rejectedTheme{n, reason})
			continue
		}
		t.ID, t.File = "user-"+strings.TrimSuffix(n, ".json"), n
		out.Themes = append(out.Themes, t)
	}
	return out
}

// themeOpener: CANON_OPEN_BIN replaces the launcher (tests); without it, SPRINT_CHECK_NO_BROWSER=1 launches nothing
// (t-269d).
func themeOpener() string {
	if o := os.Getenv("CANON_OPEN_BIN"); o != "" {
		return o
	}
	if os.Getenv("SPRINT_CHECK_NO_BROWSER") == "1" {
		return ""
	}
	switch runtime.GOOS {
	case "windows":
		return "explorer"
	case "darwin":
		return "open"
	}
	return "xdg-open"
}

// openThemesFolder creates the themes folder if absent (seeding example.json and README.md only then) and opens it.
// The path is fixed: nothing from the request reaches it or the launcher.
func openThemesFolder() map[string]any {
	d := themesDir()
	created := false
	// absent: create it (another request may win the race: then it simply exists). Any other error (a file in the
	// way, a link loop, no permission) means it is not a usable folder.
	st, err := os.Stat(d)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return map[string]any{"ok": false, "error": "the themes path is not a folder"}
	}
	if err != nil {
		if os.MkdirAll(filepath.Dir(d), 0o755) != nil {
			return map[string]any{"ok": false, "error": "could not create the themes folder"}
		}
		if err := os.Mkdir(d, 0o755); err == nil {
			created = true
		} else if !errors.Is(err, os.ErrExist) {
			return map[string]any{"ok": false, "error": "could not create the themes folder"}
		}
		if st, err = os.Stat(d); err != nil {
			return map[string]any{"ok": false, "error": "the themes path is not a folder"}
		}
	}
	if !st.IsDir() {
		return map[string]any{"ok": false, "error": "the themes path is not a folder"}
	}
	if created {
		seed := filepath.Join(filepath.Dir(appHTML), "theme-seed")
		for _, name := range []string{"example.json", "README.md"} {
			data, err := os.ReadFile(filepath.Join(seed, name))
			if err != nil {
				continue
			}
			// never overwrite
			if f, err := os.OpenFile(filepath.Join(d, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644); err == nil {
				f.Write(data)
				f.Close()
			}
		}
	}
	launched := false
	if opener := themeOpener(); opener != "" {
		cmd := exec.Command(opener, d)
		if err := cmd.Start(); err != nil {
			return map[string]any{"ok": false, "error": "could not open the themes folder"}
		}
		go cmd.Wait()
		launched = true
	}
	return map[string]any{"ok": true, "dir": d, "created": created, "launched": launched}
}

// t-5df2: edits live in the Cockpit data dir (gitignored); modelTiersPath is the
// tracked, read-only seed. Writing it dirtied the clone and blocked `canon update`.
func modelTiersUserFile() string { return filepath.Join(registryDir(), "model-tiers.json") }

func modelTiersValid(data map[string]any) bool {
	models, ok := data["models"].(map[string]any)
	if !ok {
		return false
	}
	defaults, ok := data["defaults"].(map[string]any)
	if !ok {
		return false
	}
	for _, entriesRaw := range models {
		entries, ok := entriesRaw.([]any)
		if !ok {
			return false
		}
		for _, mRaw := range entries {
			m, ok := mRaw.(map[string]any)
			if !ok || !modelIDRe.MatchString(fmt.Sprint(m["id"])) {
				return false
			}
			if alias, hasAlias := m["alias"]; hasAlias && alias != nil { // t-d40b: a null alias means none; any other non-text value is refused
				text, isText := alias.(string)
				if !isText || (text != "" && !modelIDRe.MatchString(text)) {
					return false
				}
			}
		}
	}
	for _, perProviderRaw := range defaults {
		perProvider, ok := perProviderRaw.(map[string]any)
		if !ok {
			return false
		}
		for _, modelID := range perProvider {
			if !modelIDRe.MatchString(fmt.Sprint(modelID)) {
				return false
			}
		}
	}
	return modelTiersConsistent(data)
}

func saveModelTiers(data map[string]any) map[string]any {
	if reset, ok := data["reset"].(bool); ok && reset && len(data) == 1 {
		if err := os.Remove(modelTiersUserFile()); err != nil && !os.IsNotExist(err) {
			return map[string]any{"ok": false, "error": err.Error()}
		}
		return map[string]any{"ok": true}
	}
	if !modelTiersValid(data) {
		return map[string]any{"ok": false, "error": "invalid model-tiers payload (bad id or shape)"}
	}
	body, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	if err := os.MkdirAll(registryDir(), 0o755); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	if err := os.WriteFile(modelTiersUserFile(), append(body, '\n'), 0o644); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	return map[string]any{"ok": true}
}

func registryAdd(path, description string) map[string]any {
	raw := strings.TrimSpace(path)
	if raw == "" {
		return map[string]any{"ok": false, "error": "Path is required."}
	}
	if strings.HasPrefix(raw, "~") {
		if h, err := os.UserHomeDir(); err == nil {
			raw = filepath.Join(h, strings.TrimPrefix(raw, "~"))
		}
	}
	abs, err := filepath.Abs(raw)
	if err != nil {
		return map[string]any{"ok": false, "error": "Path does not exist."}
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return map[string]any{"ok": false, "error": "Path does not exist."}
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return map[string]any{"ok": false, "error": "Path does not exist."}
	}
	if !info.IsDir() {
		return map[string]any{"ok": false, "error": "Path is not a directory."}
	}
	warning := ""
	if !exists(filepath.Join(resolved, ".git")) {
		// t-07c8: git relaxed to a non-blocking warning — register anyway.
		warning = "Path is not a git repository!"
	}
	id := registryID(resolved)
	entries := registryLoad()
	for _, e := range entries {
		if e.ID == id {
			return map[string]any{"ok": false, "error": "Project already registered."}
		}
	}
	p := registryProject{
		ID:          id,
		Path:        resolved,
		Name:        filepath.Base(resolved),
		Description: strings.TrimSpace(description),
		Added:       time.Now().Format("2006-01-02"),
	}
	entries = append(entries, p)
	if err := registrySave(entries); err != nil {
		return map[string]any{"ok": false, "error": "Could not write registry."}
	}
	res := map[string]any{"ok": true, "project": p}
	if warning != "" {
		res["warning"] = warning
	}
	return res
}

func registryRemove(id string) map[string]any {
	entries := registryLoad()
	kept := make([]registryProject, 0, len(entries))
	for _, e := range entries {
		if e.ID != id {
			kept = append(kept, e)
		}
	}
	removed := len(kept) != len(entries)
	if removed {
		registrySave(kept)
	}
	return map[string]any{"ok": true, "removed": removed}
}

// ── Per-request project scoping (t-a55a, Phase 2a) ─────────────────────────
// Mirror of server.py's effective_root/project_stats. Read endpoints accept
// ?project=<registry-id>; effectiveRoot resolves it to that registered
// project's path (trust boundary: registered id only, never a raw path).
// Returns (root, ok) — ok=false means an unknown id → caller sends 400. An
// absent param yields (projectRoot, true) — today's behavior unchanged.

func effectiveRoot(r *http.Request) (string, bool) {
	pid := strings.TrimSpace(r.URL.Query().Get("project"))
	if pid == "" {
		return projectRoot, true
	}
	for _, e := range registryLoad() {
		if e.ID == pid {
			return e.Path, true
		}
	}
	return "", false
}

func ticketsDirForRoot(root string) string {
	if root == "" {
		return ticketsDir
	}
	return filepath.Join(root, ".tickets")
}

func rootOr(root string) string {
	if root == "" {
		return projectRoot
	}
	return root
}

func runGitIn(root string, args ...string) string {
	cmd := exec.Command("git", args...)
	cmd.Dir = rootOr(root)
	var out bytes.Buffer
	cmd.Stdout = &out
	_ = cmd.Run()
	return strings.TrimSpace(out.String())
}

// t-1b88: read-only directory browser backing the Add-Project "Browse" picker —
// byte-parity with server.py's browse_dirs. Lists ONLY subdirectory names/paths
// (never files, never file contents). Empty path → home; '~' expanded.
func browseDirs(path string, showHidden bool) map[string]any {
	base := strings.TrimSpace(path)
	if base == "" {
		if h, err := os.UserHomeDir(); err == nil {
			base = h
		} else {
			base = string(filepath.Separator)
		}
	} else if base == "~" || strings.HasPrefix(base, "~"+string(filepath.Separator)) {
		if h, err := os.UserHomeDir(); err == nil {
			base = h + base[1:]
		}
	}
	abs, err := filepath.Abs(base)
	if err != nil {
		return map[string]any{"error": "invalid path"}
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved
	}
	fi, err := os.Stat(abs)
	if err != nil || !fi.IsDir() {
		return map[string]any{"error": "not a directory"}
	}
	ents, err := os.ReadDir(abs)
	if err != nil {
		return map[string]any{"error": "cannot read directory"}
	}
	entries := []map[string]any{}
	for _, e := range ents {
		if !showHidden && strings.HasPrefix(e.Name(), ".") {
			continue // t-340d: hide dotfolders by default
		}
		isDir := e.IsDir()
		if !isDir && e.Type()&os.ModeSymlink != 0 { // follow a symlink to a dir
			if st, err := os.Stat(filepath.Join(abs, e.Name())); err == nil && st.IsDir() {
				isDir = true
			}
		}
		if isDir {
			entries = append(entries, map[string]any{"name": e.Name(), "path": filepath.Join(abs, e.Name())})
		}
	}
	sort.Slice(entries, func(i, j int) bool {
		return strings.ToLower(entries[i]["name"].(string)) < strings.ToLower(entries[j]["name"].(string))
	})
	var parent any
	if p := filepath.Dir(abs); p != abs {
		parent = p
	}
	return map[string]any{"path": abs, "parent": parent, "entries": entries}
}

func projectStats(root string) map[string]any {
	updated := ""
	if iso := runGitIn(root, "log", "-1", "--format=%cI"); iso != "" {
		if when, err := time.Parse(time.RFC3339, strings.TrimSpace(iso)); err == nil {
			secs := int(time.Since(when).Seconds())
			switch {
			case secs < 60:
				updated = "just now"
			case secs < 3600:
				updated = fmt.Sprintf("%dm ago", secs/60)
			case secs < 86400:
				updated = fmt.Sprintf("%dh ago", secs/3600)
			default:
				updated = fmt.Sprintf("%dd ago", secs/86400)
			}
		}
	}
	ticketCount := 0
	if matches, err := filepath.Glob(filepath.Join(ticketsDirForRoot(root), "*", "ticket.md")); err == nil {
		ticketCount = len(matches)
	}
	return map[string]any{"updated": updated, "ticket_count": ticketCount, "skills": registeredSkills(root)}
}

// t-7485: parse the project's AGENTS.md "Active canon skills" (AI-SKILLS) table —
// byte-parity with server.py's registered_skills. Pure read, no subprocess.
// Returns a non-nil empty slice when absent so JSON marshals to [] (not null),
// matching Python's []. Names in AGENTS.md table order.
var aiSkillsBlockRe = regexp.MustCompile(`(?s)<!--\s*AI-SKILLS:BEGIN\s*-->(.*?)<!--\s*AI-SKILLS:END\s*-->`)

func registeredSkills(root string) []string {
	names := []string{}
	raw, err := os.ReadFile(filepath.Join(root, "AGENTS.md"))
	if err != nil {
		return names
	}
	m := aiSkillsBlockRe.FindSubmatch(raw)
	if m == nil {
		return names
	}
	for _, line := range strings.Split(string(m[1]), "\n") {
		if !strings.HasPrefix(line, "| ") { // skips the |---| separator and non-rows
			continue
		}
		cells := strings.Split(line, "|") // ["", " name ", " category ", " source ", ""]
		if len(cells) < 2 {
			continue
		}
		name := strings.TrimSpace(cells[1])
		if name == "" || strings.EqualFold(name, "skill") { // skip header
			continue
		}
		names = append(names, name)
	}
	return names
}

func skillsShPath() string {
	return common.EnvOr("SKILLS_SH_BIN", filepath.Join(toolsDir, "skills.sh"))
}

// registerSkill registers the fixed literal `sprint` skill into `root` via a
// non-interactive, timeout-bounded `bash skills.sh add sprint <root>` (argv list,
// no shell string). Byte-parity with server.py's register_skill. Only 'sprint' is
// accepted — the trust boundary is a constant skill name + a registry-resolved
// root, never a client path. Degrades to {ok:false,unsupported:true,cmd} where
// bash/skills.sh is unavailable.
func registerSkill(root, skill string) map[string]any {
	if skill != "sprint" && skill != "efficiency" { // fixed allowlist (t-96c3); never an arbitrary client value
		return map[string]any{"ok": false, "error": "only sprint / efficiency can be registered from the Cockpit"}
	}
	hint := fmt.Sprintf("%s add %s %s", skillsShPath(), skill, root)
	bash, berr := exec.LookPath("bash")
	if berr != nil || !exists(skillsShPath()) {
		return map[string]any{"ok": false, "unsupported": true, "cmd": hint}
	}
	cmd := exec.Command(bash, skillsShPath(), "add", skill, root)
	cmd.Dir = root
	cmd.Stdin = nil
	// t-b47a: Stdin=nil alone does NOT make skills.sh's setup prompts
	// non-interactive — they read from /dev/tty directly, independent of
	// stdin, so a long-lived board process still finds its launch terminal's
	// controlling tty and prompts there, unanswered. SKILLS_SH_ASSUME_YES
	// tells the three project-scoped prompts (AGENTS.md bridge, model-tiers
	// note, subagent-log.sh permission) to apply their recommended default
	// immediately instead of waiting on that prompt.
	cmd.Env = append(os.Environ(), "SKILLS_SH_ASSUME_YES=1")
	timedOut := false
	timer := time.AfterFunc(60*time.Second, func() {
		timedOut = true
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	})
	out, err := cmd.CombinedOutput()
	timer.Stop()
	if err != nil {
		// Parity with server.py: a completed-but-nonzero run → {error}; a launch
		// failure or our timeout kill → {unsupported} (same as no-bash), so the
		// UI shows the copy-paste command rather than an error toast.
		if _, isExit := err.(*exec.ExitError); isExit && !timedOut {
			msg := strings.TrimSpace(string(out))
			if msg == "" {
				msg = "skills.sh failed"
			}
			if len(msg) > 400 {
				msg = msg[:400]
			}
			return map[string]any{"ok": false, "error": msg, "cmd": hint}
		}
		return map[string]any{"ok": false, "unsupported": true, "cmd": hint}
	}
	return map[string]any{"ok": true, "skills": registeredSkills(root)}
}

// t-d538: opt-in "Track changes" — mirror of server.py track_changes (byte-parity on the
// .gitignore and the JSON shapes). The daemon only trusts git work trees, so a non-git
// project can't run agents until it tracks changes.
const trackChangesGitignore = "# Added by canon when this folder started tracking changes.\n" +
	".DS_Store\nThumbs.db\ndesktop.ini\n" +
	"node_modules/\n.venv/\n__pycache__/\ndist/\nbuild/\n" +
	"*.mp4\n*.mov\n*.zip\n"

const trackChangesMessage = "chore: start tracking changes with canon"

// Path-segment prefix → service name. Warn-only: a miss just skips the warning.
var syncedMarkers = [][2]string{{"mobile documents", "iCloud Drive"}, {"cloudstorage", "cloud storage"},
	{"dropbox", "Dropbox"}, {"onedrive", "OneDrive"}, {"google drive", "Google Drive"}, {"my drive", "Google Drive"}}

func syncedService(path string) any {
	for _, seg := range pathSepRe.Split(strings.ToLower(path), -1) {
		for _, m := range syncedMarkers {
			if strings.HasPrefix(seg, m[0]) {
				return m[1]
			}
		}
	}
	return nil
}

func insideWorkTree(root string) bool {
	out, _, _ := gitOutIn(root, 10*time.Second, "rev-parse", "--is-inside-work-tree")
	return strings.TrimSpace(out) == "true"
}

// trackChangesRoot: ?project=<id> → that registered folder; ?project=default → this board's own
// root. Absent/empty → "project is required"; unknown id → ok=false with an empty message (400).
func trackChangesRoot(r *http.Request) (string, string, bool) {
	pid := strings.TrimSpace(r.URL.Query().Get("project"))
	if pid == "" {
		return "", "project is required", false
	}
	if pid == "default" {
		return projectRoot, "", true
	}
	root, ok := effectiveRoot(r)
	return root, "", ok
}

func trackChangesState(root string) map[string]any {
	_, gitErr := exec.LookPath("git")
	return map[string]any{"ok": true, "tracking": insideWorkTree(root), "synced": syncedService(root), "git_available": gitErr == nil}
}

// trackChanges refuses on any existing .git (a broken repo must never be reinitialized and
// then deleted by the rollback) and inside a parent repo; on failure it removes only what
// this call created.
func trackChanges(root string, confirm any) map[string]any {
	fail := func(msg string) map[string]any { return map[string]any{"ok": false, "error": msg} }
	if confirm != true {
		return fail("Track changes needs confirm: true.")
	}
	if _, err := exec.LookPath("git"); err != nil {
		return fail("Version history needs Git, which isn't installed on this computer. You can keep working without it.")
	}
	gitDir, ignore := filepath.Join(root, ".git"), filepath.Join(root, ".gitignore")
	if _, err := os.Lstat(gitDir); err == nil {
		return fail("This folder already has a .git. Fix or remove it yourself; canon will not touch it.")
	}
	if insideWorkTree(root) {
		return fail("This folder is already inside a git repository.")
	}
	_, statErr := os.Lstat(ignore)
	hadIgnore := statErr == nil
	created, wroteIgnore := false, false
	git := func(args ...string) (string, error) {
		out, errOut, err := gitOutIn(root, 20*time.Second, args...)
		if err != nil {
			msg := strings.TrimSpace(errOut)
			if msg == "" {
				msg = strings.TrimSpace(out)
			}
			if msg == "" {
				msg = "git " + args[0] + " failed"
			}
			if len(msg) > 300 {
				msg = msg[:300]
			}
			return "", errors.New(msg)
		}
		return strings.TrimSpace(out), nil
	}
	rollback := func(err error) map[string]any {
		if created {
			_ = os.RemoveAll(gitDir)
		}
		if wroteIgnore {
			_ = os.Remove(ignore)
		}
		msg := "Could not start tracking changes: " + err.Error()
		if len(msg) > 400 {
			msg = msg[:400]
		}
		return fail(msg)
	}
	created = true // .git was absent a moment ago, so anything there from now on is ours
	if _, err := git("init", "-q"); err != nil {
		return rollback(err)
	}
	if !hadIgnore {
		if err := os.WriteFile(ignore, []byte(trackChangesGitignore), 0o644); err != nil {
			return rollback(err)
		}
		wroteIgnore = true
	}
	if _, err := git("add", "--", ".gitignore"); err != nil {
		return rollback(err)
	}
	var identity []string
	if _, _, err := gitOutIn(root, 10*time.Second, "config", "user.name"); err != nil {
		identity = append(identity, "-c", "user.name=canon")
	}
	if _, _, err := gitOutIn(root, 10*time.Second, "config", "user.email"); err != nil {
		identity = append(identity, "-c", "user.email=canon@localhost")
	}
	if _, err := git(append(identity, "commit", "-q", "-m", trackChangesMessage)...); err != nil {
		return rollback(err)
	}
	sha, err := git("rev-parse", "--short", "HEAD")
	if err != nil {
		return rollback(err)
	}
	return map[string]any{"ok": true, "commit": sha}
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func setDefault(t ticket, key string, value any) {
	if _, ok := t[key]; !ok || fmt.Sprint(t[key]) == "<nil>" {
		t[key] = value
	}
}

// t-1f22: the two gate reports are named for who writes them; t-1dec: github.md is the GitHub trail, not "Github".
var docNameOverrides = map[string]string{"eval-report": "Eval Agent", "review-notes": "Review Agent", "github": "GitHub"}

// t-1f22: the working docs first, then the two gate reports one after another (review, then eval), then the rest by name.
var docOrder = []string{"acceptance", "plan", "research", "review-notes", "eval-report"}

func docRank(path string) int {
	stem := strings.TrimSuffix(filepath.Base(path), ".md")
	for i, s := range docOrder {
		if s == stem {
			return i
		}
	}
	return len(docOrder)
}

func docName(path string) string {
	stem := strings.TrimSuffix(filepath.Base(path), ".md")
	if name, ok := docNameOverrides[stem]; ok {
		return name
	}
	return titleCase(strings.ReplaceAll(stem, "-", " "))
}

func titleCase(s string) string {
	parts := strings.Fields(s)
	for i, p := range parts {
		parts[i] = strings.ToUpper(p[:1]) + p[1:]
	}
	return strings.Join(parts, " ")
}

func intValue(v any, fallback int) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	case string:
		if n, err := strconv.Atoi(x); err == nil {
			return n
		}
	}
	return fallback
}

func boolValue(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case float64:
		return x != 0
	case string:
		return x == "true" || x == "1"
	}
	return false
}

func stringValue(payload map[string]any, key, fallback string) string {
	v, ok := payload[key]
	if !ok || v == nil {
		return fallback
	}
	s := fmt.Sprint(v)
	if s == "" || s == "<nil>" {
		return fallback
	}
	return s
}

func queryHasAll(rawQuery string) bool {
	return strings.Contains(rawQuery, "all=1")
}

func randomID(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		fallback := fmt.Sprintf("%x", time.Now().UnixNano())
		if len(fallback) >= n {
			return fallback[:n]
		}
		return fallback
	}
	for i := range b {
		b[i] = chars[int(b[i])%len(chars)]
	}
	return string(b)
}

func unescape(s string) string {
	v, err := url.PathUnescape(s)
	if err != nil {
		return html.UnescapeString(s)
	}
	return v
}

func nonEmpty(items []string) []string {
	out := []string{}
	for _, item := range items {
		if strings.TrimSpace(item) != "" {
			out = append(out, item)
		}
	}
	return out
}

func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func firstN(s string, n int) string {
	if len(s) < n {
		return s
	}
	return s[:n]
}
