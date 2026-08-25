package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	frontmatterRe    = regexp.MustCompile(`(?s)^---\s*\n(.*?)\n---\s*\n`)
	fieldRe          = regexp.MustCompile(`(?m)^(\w+):\s*(.+)$`)
	headingRe        = regexp.MustCompile(`(?m)^#{1,6}\s+(.+)$`)
	modelMentionRe   = regexp.MustCompile(`(?i)\(model:\s*([^)]+)\)`)
	baseRefRe        = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
	imageExts        = []string{".png", ".gif", ".jpg", ".jpeg", ".webp"}
	safeVisualName   = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	projectRoot      string
	ticketsDir       string
	handoffFile      string
	appHTML          string
	sprintHeadless   string
	cockpitDaemonBin string
	cockpitSprintBin string
	headlessRuns     = map[string]map[string]any{}
	headlessRunsMu   sync.Mutex
)

type docInfo struct {
	Name string `json:"name"`
	File string `json:"file"`
}

type ticket map[string]any

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "help", "--help", "-h":
			usage()
			return
		}
	}

	port := 8423
	if len(os.Args) > 1 {
		if p, err := strconv.Atoi(os.Args[1]); err == nil {
			port = p
		}
	}
	for portInUse(port) {
		port++
	}

	cwd := mustGetwd()
	projectRoot = findProjectRoot(envOr("SPRINT_CHECK_ROOT", cwd))
	exe, _ := os.Executable()
	toolsDir := filepath.Dir(exe)
	if strings.HasSuffix(filepath.ToSlash(toolsDir), "/sprint-check-bin") {
		toolsDir = filepath.Dir(toolsDir)
	}
	appHTML = resolveAppHTML(toolsDir, projectRoot, cwd)
	sprintHeadless = resolveSprintHeadless(toolsDir, projectRoot, cwd)
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
	server := &http.Server{Addr: addr, Handler: mux}
	url := fmt.Sprintf("http://127.0.0.1:%d", port)
	fmt.Fprintf(os.Stderr, "sprint-check  %s  (project: %s)\n", url, filepath.Base(projectRoot))
	fmt.Fprintf(os.Stderr, "tickets: %s\n", ticketsDir)

	if os.Getenv("SPRINT_CHECK_NO_BROWSER") != "1" {
		go func() {
			time.Sleep(400 * time.Millisecond)
			openBrowser(url)
		}()
	}

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Println(`sprint-check-win — local kanban dashboard for canon projects

Usage:
  sprint-check-win        Open the dashboard for the current project
  sprint-check-win <port> Open the dashboard on a specific port
  sprint-check-win --help Show this help

The dashboard reads .tickets/, HANDOFF.md, and git history from the current
project. It starts a local Go HTTP server and opens the board in your default
browser.`)
}

func handle(w http.ResponseWriter, r *http.Request) {
	if !hostOK(r.Host) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if r.Method == http.MethodGet {
		handleGet(w, r)
		return
	}
	if r.Method == http.MethodPost {
		handlePost(w, r)
		return
	}
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

func handleGet(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimRight(r.URL.Path, "/")
	switch path {
	case "", "/":
		serveFile(w, appHTML, "text/html; charset=utf-8")
	case "/api/tickets":
		tickets := loadTickets()
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
		sendJSON(w, loadHandoff())
	case "/api/git":
		sendJSON(w, loadGit())
	case "/api/why":
		sendJSON(w, loadWhy(r.URL.Query().Get("file")))
	case "/api/cockpit":
		sendJSON(w, cockpitDiscover())
	default:
		if regexp.MustCompile(`^/meta/screenshots/[A-Za-z0-9_-]+\.(png|gif|jpg|jpeg|webp)$`).MatchString(path) {
			serveFile(w, filepath.Join(projectRoot, filepath.FromSlash(strings.TrimPrefix(path, "/"))), mime.TypeByExtension(filepath.Ext(path)))
			return
		}
		if m := regexp.MustCompile(`^/api/commit/([0-9a-f]{4,40})$`).FindStringSubmatch(path); m != nil {
			sendJSON(w, loadCommit(m[1]))
			return
		}
		if m := regexp.MustCompile(`^/api/doc/(.+)$`).FindStringSubmatch(path); m != nil {
			content, ok := readDoc(unescape(m[1]))
			if !ok {
				http.NotFound(w, r)
				return
			}
			sendJSON(w, map[string]string{"content": content})
			return
		}
		if m := regexp.MustCompile(`^/api/ticket-image/(t-[a-z0-9]{4})/(.+)$`).FindStringSubmatch(path); m != nil {
			ticketID, relpath := m[1], unescape(m[2])
			p, ok := safeTicketDoc(ticketID+"/"+relpath, imageExts...)
			if !ok || !exists(p) {
				http.NotFound(w, r)
				return
			}
			serveFile(w, p, mime.TypeByExtension(filepath.Ext(p)))
			return
		}
		if m := regexp.MustCompile(`^/api/ticket-feature/(t-[a-z0-9]{4})/(.+)$`).FindStringSubmatch(path); m != nil {
			ticketID, relpath := m[1], unescape(m[2])
			p, ok := safeTicketDoc(ticketID+"/"+relpath, ".feature")
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
		if m := regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/headless-run$`).FindStringSubmatch(path); m != nil {
			sendJSON(w, getHeadlessRunState(m[1]))
			return
		}
		http.NotFound(w, r)
	}
}

func handlePost(w http.ResponseWriter, r *http.Request) {
	origin := r.Header.Get("Origin")
	if origin != "" && !strings.HasPrefix(origin, "http://127.0.0.1") && !strings.HasPrefix(origin, "http://localhost") {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var payload map[string]any
	body, err := io.ReadAll(r.Body)
	if err != nil || json.Unmarshal(body, &payload) != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	path := r.URL.Path
	if m := regexp.MustCompile(`^/api/ticket/([^/]+)/status$`).FindStringSubmatch(path); m != nil {
		sendJSON(w, map[string]bool{"ok": writeStatus(m[1], fmt.Sprint(payload["status"]))})
		return
	}
	if m := regexp.MustCompile(`^/api/ticket/([^/]+)/body$`).FindStringSubmatch(path); m != nil {
		sendJSON(w, map[string]bool{"ok": writeBody(m[1], fmt.Sprint(payload["body"]))})
		return
	}
	if m := regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/visual$`).FindStringSubmatch(path); m != nil {
		sendJSON(w, writeVisual(m[1], stringValue(payload, "filename", ""), stringValue(payload, "data", "")))
		return
	}
	if m := regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/demo$`).FindStringSubmatch(path); m != nil {
		sendJSON(w, map[string]bool{"ok": writeDemo(m[1], boolValue(payload["demo"]))})
		return
	}
	if m := regexp.MustCompile(`^/api/doc/(.+)$`).FindStringSubmatch(path); m != nil {
		sendJSON(w, map[string]bool{"ok": writeDoc(unescape(m[1]), fmt.Sprint(payload["content"]))})
		return
	}
	if m := regexp.MustCompile(`^/api/ticket/(t-[a-z0-9]{4})/headless-run$`).FindStringSubmatch(path); m != nil {
		baseRef := fmt.Sprint(payload["base_ref"])
		if !baseRefRe.MatchString(baseRef) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		sendJSON(w, startHeadlessRun(m[1], baseRef))
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
	if path == "/api/tickets" {
		sendJSON(w, createTicket(
			stringValue(payload, "title", "Untitled"),
			stringValue(payload, "type", "task"),
			stringValue(payload, "status", "open"),
			intValue(payload["priority"], 2),
			stringValue(payload, "body", ""),
			boolValue(payload["ci"]),
			boolValue(payload["eval_override"]),
			stringValue(payload, "gate", "full"),
			boolValue(payload["demo"]),
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
			cb := regexp.MustCompile(`(?m)^\s*[-*]\s+\[[ xX]\]\s+\S`)
			unchecked := regexp.MustCompile(`(?m)^\s*[-*]\s+\[ \]\s+\S`)
			t["acceptance_has_items"] = cb.MatchString(section(accText, "Criteria")) && cb.MatchString(section(accText, "Test Plan"))
			t["acceptance_unchecked"] = unchecked.MatchString(accText)
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

func ticketPaths() []string {
	if st, err := os.Stat(ticketsDir); err != nil || !st.IsDir() {
		return nil
	}
	var paths []string
	seen := map[string]bool{}
	filepath.WalkDir(ticketsDir, func(path string, d os.DirEntry, err error) error {
		if err != nil || path == ticketsDir {
			return nil
		}
		rel, _ := filepath.Rel(ticketsDir, path)
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
	files, _ := filepath.Glob(filepath.Join(ticketsDir, "*.md"))
	for _, f := range files {
		stem := strings.TrimSuffix(filepath.Base(f), filepath.Ext(f))
		if seen[stem] || regexp.MustCompile(`^.+-(blueprint|acceptance|plan|decisions|qa|notes)$`).MatchString(stem) {
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

func loadTickets() []ticket {
	// Must stay a non-nil slice — Go's encoding/json marshals a nil slice as
	// `null`, not `[]`, unlike server.py's load_tickets (always `tickets = []`);
	// the frontend's renderHeader crashes on `null.filter(...)` when zero
	// tickets exist, which aborts the whole board render (t-626d).
	tickets := []ticket{}
	for _, p := range ticketPaths() {
		if t, err := parseTicket(p); err == nil {
			tickets = append(tickets, t)
		}
	}
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

func loadHandoff() map[string]any {
	raw, err := os.ReadFile(handoffFile)
	if err != nil {
		return map[string]any{"focus": nil, "raw": ""}
	}
	text := string(raw)
	focus := ""
	if m := regexp.MustCompile(`(?s)##\s+Current Focus\s*\n+(.+?)(?:\n##|\z)`).FindStringSubmatch(text); m != nil {
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

func loadGit() map[string]any {
	status := runGit("status", "--porcelain")
	modified := 0
	for _, line := range strings.Split(status, "\n") {
		if strings.TrimSpace(line) != "" {
			modified++
		}
	}
	log := []map[string]string{}
	for _, line := range strings.Split(runGit("log", "--oneline", "-40"), "\n") {
		parts := strings.SplitN(line, " ", 2)
		if len(parts) == 2 && !strings.HasPrefix(parts[1], "chore: auto-update handoff") && !strings.HasPrefix(parts[1], "chore: auto-handoff") {
			log = append(log, map[string]string{"hash": parts[0], "message": parts[1]})
			if len(log) == 8 {
				break
			}
		}
	}
	branch := runGit("rev-parse", "--abbrev-ref", "HEAD")
	if branch == "" {
		branch = "main"
	}
	var totalCommits any
	if n, err := strconv.Atoi(strings.TrimSpace(runGit("rev-list", "--count", "HEAD"))); err == nil {
		totalCommits = n
	}
	return map[string]any{"branch": branch, "project": filepath.Base(projectRoot), "root": projectRoot, "modified": modified, "log": log, "total_commits": totalCommits}
}

func loadCommit(hash string) map[string]any {
	msg := runGit("log", "-1", "--format=%B", hash)
	lines := strings.Split(msg, "\n")
	subject := ""
	if len(lines) > 0 {
		subject = lines[0]
	}
	body := ""
	if len(lines) > 2 {
		body = strings.TrimSpace(strings.Join(lines[2:], "\n"))
	}
	files := nonEmpty(strings.Split(runGit("diff-tree", "--no-commit-id", "-r", "--name-only", hash), "\n"))
	related := map[string]bool{}
	for _, m := range regexp.MustCompile(`\b([A-Za-z]+-[a-z0-9]{3,})\b`).FindAllStringSubmatch(msg, -1) {
		related[m[1]] = true
	}
	for _, f := range files {
		parts := strings.Split(filepath.ToSlash(f), "/")
		if len(parts) >= 2 && parts[0] == ".tickets" {
			related[strings.TrimSuffix(filepath.Base(f), ".md")] = true
		}
	}
	return map[string]any{"hash": hash, "subject": subject, "body": body, "author": runGit("log", "-1", "--format=%an", hash), "date": firstN(runGit("log", "-1", "--format=%ci", hash), 10), "files": files, "related_ticket_ids": sortedKeys(related)}
}

func basenameCandidates(basename string) []string {
	out := runGit("log", "--all", "--name-only", "--format=")
	seen := map[string]bool{}
	for _, line := range nonEmpty(strings.Split(out, "\n")) {
		if filepath.Base(line) == basename {
			seen[line] = true
		}
	}
	return sortedKeys(seen)
}

func loadWhy(file string) map[string]any {
	target := strings.TrimSpace(file)
	if target == "" {
		return map[string]any{"file": "", "results": []any{}, "message": "Enter a file path."}
	}
	if filepath.IsAbs(target) || strings.Contains(filepath.ToSlash(target), "../") {
		return map[string]any{"file": target, "results": []any{}, "message": "Use a project-relative file path."}
	}
	queryTarget := target
	subjects := runGit("log", "--follow", "--format=%s", "--", queryTarget)
	var resolvedPath string
	var alternatives []string
	if subjects == "" {
		basename := filepath.Base(target)
		candidates := []string{}
		if basename != "" && basename != "." {
			candidates = basenameCandidates(basename)
		}
		if len(candidates) == 1 {
			queryTarget = candidates[0]
			resolvedPath = queryTarget
			subjects = runGit("log", "--follow", "--format=%s", "--", queryTarget)
		} else if len(candidates) > 1 {
			type ranked struct {
				count int
				path  string
			}
			var items []ranked
			for _, c := range candidates {
				out := runGit("log", "--oneline", "--", c)
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
			subjects = runGit("log", "--follow", "--format=%s", "--", queryTarget)
		}
	}
	if subjects == "" {
		return map[string]any{"file": target, "results": []any{}, "message": "No git history found for " + target + "."}
	}
	known := map[string]bool{}
	byID := map[string]ticket{}
	byPath := map[string]string{}
	for _, p := range ticketPaths() {
		if t, err := parseTicket(p); err == nil {
			id := fmt.Sprint(t["id"])
			known[id] = true
			byID[id] = t
			byPath[id] = p
		}
	}
	ids := []string{}
	seen := map[string]bool{}
	for _, m := range regexp.MustCompile(`\b[A-Za-z]+-[a-z0-9]{3,}\b`).FindAllString(subjects, -1) {
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

func writeStatus(id, status string) bool {
	ok := replaceTicket(id, func(text string) string {
		return regexp.MustCompile(`(?m)^(status:\s*)(\S+)$`).ReplaceAllString(text, "${1}"+status)
	})
	if ok {
		updateActive(canonicalTicketID(id), status)
	}
	return ok
}

// writeDemo toggles the boolean `demo` frontmatter field on an existing ticket. ON ensures a
// `demo: true` line (appended as the last frontmatter field); OFF removes any `demo:` line
// (absent = false, matching `tkt demo`). Returns true if the ticket exists (idempotent).
// Kept byte-for-byte identical to server.py's write_demo — parity-tested (t-64a0).
func writeDemo(id string, want bool) bool {
	path := findTicketPath(id)
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

func canonicalTicketID(id string) string {
	if p := findTicketPath(id); p != "" {
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
func updateActive(canonicalID, status string) {
	activePath := filepath.Join(ticketsDir, "ACTIVE")
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

func writeBody(id, body string) bool {
	return replaceTicket(id, func(text string) string {
		if m := frontmatterRe.FindStringIndex(text); m != nil {
			return text[:m[1]] + strings.TrimSpace(body) + "\n"
		}
		return strings.TrimSpace(body) + "\n"
	})
}

func writeDoc(docFile, content string) bool {
	p, ok := safeTicketDoc(docFile)
	if !ok {
		var legacyOK bool
		p, legacyOK = legacyDocTarget(docFile)
		if !legacyOK {
			return false
		}
	}
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		return false
	}
	return os.WriteFile(p, []byte(strings.TrimSpace(content)+"\n"), 0644) == nil
}

// Must stay behaviorally identical to server.py's write_visual (t-626d) —
// enforced by tests/sprint-check-api-parity.sh, not shared code.
const maxVisualBytes = 8 * 1024 * 1024

// dedupeVisualName returns a collision-free filename under .tickets/<id>/visuals/,
// auto-suffixing before the extension (never overwrites). "" if filename is unsafe.
func dedupeVisualName(ticketID, filename string) string {
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
		target, ok := safeTicketDoc(ticketID+"/visuals/"+candidate, imageExts...)
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
func writeVisual(ticketID, filename, dataB64 string) map[string]any {
	raw, err := base64.StdEncoding.DecodeString(dataB64)
	if err != nil || len(raw) == 0 || len(raw) > maxVisualBytes {
		return map[string]any{"ok": false}
	}
	name := dedupeVisualName(ticketID, filename)
	if name == "" {
		return map[string]any{"ok": false}
	}
	target, ok := safeTicketDoc(ticketID+"/visuals/"+name, imageExts...)
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

func createTicket(title, typ, status string, priority int, body string, ci bool, evalOverride bool, gate string, demo bool) ticket {
	os.MkdirAll(ticketsDir, 0755)
	existing := map[string]bool{}
	for _, p := range ticketPaths() {
		stem := strings.TrimSuffix(filepath.Base(p), filepath.Ext(p))
		existing[stem] = true
		if filepath.Base(p) == "ticket.md" {
			existing[filepath.Base(filepath.Dir(p))] = true
		}
	}
	if entries, err := os.ReadDir(ticketsDir); err == nil {
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
	dir := filepath.Join(ticketsDir, id)
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
	evalLine := "eval_override: false"
	if evalOverride {
		evalLine = "eval_override: true"
	}
	text := fmt.Sprintf("---\nid: %s\ntitle: %s\nstatus: %s\ntype: %s\npriority: %d\ncreated: %s\n%s%s%s%s\n---\n\n%s\n", id, strings.ReplaceAll(title, "\n", " "), status, typ, priority, time.Now().Format("2006-01-02"), ciLine, gateLine, demoLine, evalLine, strings.TrimSpace(body))
	path := filepath.Join(dir, "ticket.md")
	os.WriteFile(path, []byte(text), 0644)
	t, _ := parseTicket(path)
	return t
}

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
	tmpl := filepath.Join(filepath.Dir(sprintHeadless), "canon-gate-template.yml")
	data, err := os.ReadFile(tmpl)
	if err != nil {
		return map[string]any{"ok": false, "reason": err.Error(), "path": rel}
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return map[string]any{"ok": false, "reason": err.Error(), "path": rel}
	}
	if err := os.WriteFile(dest, data, 0644); err != nil {
		return map[string]any{"ok": false, "reason": err.Error(), "path": rel}
	}
	return map[string]any{"ok": true, "path": rel}
}

func replaceTicket(id string, fn func(string) string) bool {
	path := findTicketPath(id)
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

func findTicketPath(id string) string {
	candidates := []string{filepath.Join(ticketsDir, id, "ticket.md"), filepath.Join(ticketsDir, id+".md")}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	for _, p := range ticketPaths() {
		if t, err := parseTicket(p); err == nil && fmt.Sprint(t["id"]) == id {
			return p
		}
	}
	return ""
}

func readDoc(docFile string) (string, bool) {
	p, ok := safeTicketDoc(docFile)
	if !ok || !exists(p) {
		if legacy, legacyOK := legacyDocTarget(docFile); legacyOK {
			p = legacy
		} else {
			return "", false
		}
	}
	raw, err := os.ReadFile(p)
	return string(raw), err == nil
}

// Must stay behaviorally identical to server.py's _safe_ticket_doc
// (tools/sprint-check-app/server.py) — enforced by tests/sprint-check-api-parity.sh,
// not shared code. Change one, change the other, then re-run that test.
func safeTicketDoc(docFile string, exts ...string) (string, bool) {
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
	p := filepath.Join(ticketsDir, clean)
	rel, err := filepath.Rel(ticketsDir, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", false
	}
	if !containedAfterSymlinks(p) {
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
func containedAfterSymlinks(p string) bool {
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
	root, err := filepath.EvalSymlinks(ticketsDir)
	if err != nil {
		root = ticketsDir
	}
	rel, err := filepath.Rel(root, resolved)
	return err == nil && !strings.HasPrefix(rel, "..")
}

func legacyDocTarget(docFile string) (string, bool) {
	safe := filepath.Base(filepath.FromSlash(docFile))
	if filepath.Ext(safe) != ".md" {
		return "", false
	}
	if m := regexp.MustCompile(`^([A-Za-z]+-[A-Za-z0-9]+)-(.+)\.md$`).FindStringSubmatch(safe); m != nil {
		folderTicket := filepath.Join(ticketsDir, m[1], "ticket.md")
		if exists(folderTicket) {
			return filepath.Join(ticketsDir, m[1], m[2]+".md"), true
		}
	}
	return filepath.Join(ticketsDir, safe), true
}

func section(text, heading string) string {
	lines := strings.Split(text, "\n")
	active := false
	var out []string
	for _, line := range lines {
		if regexp.MustCompile(`^##\s+` + regexp.QuoteMeta(heading) + `\s*$`).MatchString(line) {
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
	text = regexp.MustCompile(`(?s)<!--.*?-->`).ReplaceAllString(text, "")
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) != "" {
			return true
		}
	}
	return false
}

func sectionHasCheckedItem(text, heading string) bool {
	return regexp.MustCompile(`(?m)^\s*[-*]\s+\[[xX]\]\s+\S`).MatchString(section(text, heading))
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
	m := regexp.MustCompile(`(?ms)^##\s+Decisions\s*$([\s\S]*)`).FindStringSubmatch(string(raw))
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
	for _, word := range regexp.MustCompile(`[a-z]{4,}`).FindAllString(strings.ToLower(text), -1) {
		if !stop[word] {
			words[word] = true
		}
	}
	return words
}

func findProjectRoot(start string) string {
	dir, _ := filepath.Abs(start)
	for {
		if exists(filepath.Join(dir, ".git")) || exists(filepath.Join(dir, ".tickets")) {
			return dir
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

func runGit(args ...string) string {
	cmd := exec.Command("git", args...)
	cmd.Dir = projectRoot
	var out bytes.Buffer
	cmd.Stdout = &out
	_ = cmd.Run()
	return strings.TrimSpace(out.String())
}

func portInUse(port int) bool {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return true
	}
	ln.Close()
	return false
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

func resolveSprintHeadless(toolsDir, root string, extraRoots ...string) string {
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

// ── Cockpit daemon integration (t-ddc8) ─────────────────────────────────────
// The board never owns a PTY (t-1262 lesson): it discovers/launches the shipped
// cockpit-daemon (which owns the PTY) and the frontend iframes its /cockpit
// page. The board reads only the daemon's addr from the 0600 daemon.json; the
// token stays daemon-side. The spawn argv is fixed — no board/user input is
// interpolated. Must stay behaviorally identical to server.py's cockpit_*
// helpers — parity-tested by tests/sprint-check-api-parity.sh.

// resolveCockpitDaemon finds the cockpit-daemon binary. COCKPIT_DAEMON_BIN
// overrides (used by tests to point at a stub); default is the built binary
// next to the tools dir.
func resolveCockpitDaemon(toolsDir, root string, extraRoots ...string) string {
	if b := os.Getenv("COCKPIT_DAEMON_BIN"); b != "" {
		return b
	}
	name := "cockpit-daemon"
	if runtime.GOOS == "windows" {
		name = "cockpit-daemon.exe"
	}
	candidates := []string{
		filepath.Join(toolsDir, "cockpit-daemon", name),
		filepath.Join(root, "tools", "cockpit-daemon", name),
	}
	for _, extraRoot := range extraRoots {
		candidates = append(candidates, filepath.Join(extraRoot, "tools", "cockpit-daemon", name))
	}
	for _, candidate := range candidates {
		if exists(candidate) {
			return candidate
		}
	}
	return candidates[0]
}

// cockpitStateDir is where the board expects the daemon to publish daemon.json.
// COCKPIT_STATE_DIR overrides (tests); default is a fixed loopback-local temp dir.
func cockpitStateDir() string {
	if d := os.Getenv("COCKPIT_STATE_DIR"); d != "" {
		return d
	}
	return filepath.Join(os.TempDir(), "canon-cockpit-board")
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
	raw, err := os.ReadFile(filepath.Join(cockpitStateDir(), "daemon.json"))
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
	return map[string]any{"running": ok, "addr": addrAny}
}

// ensureCockpit returns a running daemon's addr, launching one on demand if
// none is healthy. The spawn argv is fixed (["-addr","127.0.0.1:0"]); the
// project root + sprint bin are passed via env, never argv.
func ensureCockpit() map[string]any {
	if addr, ok := discoverCockpitAddr(); ok {
		return map[string]any{"running": true, "addr": addr, "launched": false}
	}
	if !exists(cockpitDaemonBin) {
		return map[string]any{"running": false, "addr": nil, "error": "cockpit daemon binary not found"}
	}
	stateDir := cockpitStateDir()
	os.MkdirAll(stateDir, 0700)
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
	if err := cmd.Start(); err != nil {
		return map[string]any{"running": false, "addr": nil, "error": err.Error()}
	}
	// Detach: don't Wait — the daemon must outlive the board (agent survives the
	// browser tab, nebula's model). Reap the child in the background so a fast
	// exit (e.g. bind failure) doesn't leave a zombie.
	go func() { _ = cmd.Wait() }()
	for i := 0; i < 50; i++ {
		if addr, ok := discoverCockpitAddr(); ok {
			return map[string]any{"running": true, "addr": addr, "launched": true}
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
	tool := sprintHeadless
	if ticketGate(ticketID) == "eval" {
		tool = filepath.Join(filepath.Dir(sprintHeadless), "sprint-headless-eval")
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
	w.Write(body)
}

func sendJSON(w http.ResponseWriter, data any) {
	body, _ := json.Marshal(data)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.Write(body)
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func mustGetwd() string {
	wd, _ := os.Getwd()
	return wd
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

func docName(path string) string {
	return titleCase(strings.ReplaceAll(strings.TrimSuffix(filepath.Base(path), ".md"), "-", " "))
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
