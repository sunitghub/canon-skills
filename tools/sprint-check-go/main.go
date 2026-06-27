package main

import (
	"bytes"
	"crypto/rand"
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
	"time"
)

var (
	frontmatterRe = regexp.MustCompile(`(?s)^---\s*\n(.*?)\n---\s*\n`)
	fieldRe       = regexp.MustCompile(`(?m)^(\w+):\s*(.+)$`)
	headingRe     = regexp.MustCompile(`(?m)^#{1,6}\s+(.+)$`)
	projectRoot   string
	ticketsDir    string
	handoffFile   string
	appHTML       string
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
	if m := regexp.MustCompile(`^/api/doc/(.+)$`).FindStringSubmatch(path); m != nil {
		sendJSON(w, map[string]bool{"ok": writeDoc(unescape(m[1]), fmt.Sprint(payload["content"]))})
		return
	}
	if path == "/api/tickets" {
		sendJSON(w, createTicket(
			stringValue(payload, "title", "Untitled"),
			stringValue(payload, "type", "task"),
			stringValue(payload, "status", "open"),
			intValue(payload["priority"], 2),
			stringValue(payload, "body", ""),
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
			t[match[1]] = strings.TrimSpace(match[2])
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
		if acc, err := os.ReadFile(filepath.Join(filepath.Dir(path), "acceptance.md")); err == nil {
			accText := string(acc)
			cb := regexp.MustCompile(`(?m)^\s*[-*]\s+\[[ xX]\]\s+\S`)
			unchecked := regexp.MustCompile(`(?m)^\s*[-*]\s+\[ \]\s+\S`)
			t["acceptance_has_items"] = cb.MatchString(section(accText, "Criteria")) && cb.MatchString(section(accText, "Test Plan"))
			t["acceptance_unchecked"] = unchecked.MatchString(accText)
		}
		t["plan_has_approach"] = nil
		if plan, err := os.ReadFile(filepath.Join(filepath.Dir(path), "plan.md")); err == nil {
			t["plan_has_approach"] = usefulText(section(string(plan), "Approach"))
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

func loadTickets() []ticket {
	var tickets []ticket
	for _, p := range ticketPaths() {
		if t, err := parseTicket(p); err == nil {
			tickets = append(tickets, t)
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
	return map[string]any{"branch": branch, "project": filepath.Base(projectRoot), "root": projectRoot, "modified": modified, "log": log}
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

func loadWhy(file string) map[string]any {
	target := strings.TrimSpace(file)
	if target == "" {
		return map[string]any{"file": "", "results": []any{}, "message": "Enter a file path."}
	}
	if filepath.IsAbs(target) || strings.Contains(filepath.ToSlash(target), "../") {
		return map[string]any{"file": target, "results": []any{}, "message": "Use a project-relative file path."}
	}
	subjects := runGit("log", "--follow", "--format=%s", "--", target)
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
	results := []map[string]any{}
	for _, id := range ids {
		t := byID[id]
		results = append(results, map[string]any{"id": id, "status": t["status"], "title": t["title"], "decision": planDecision(byPath[id])})
	}
	msg := ""
	if len(results) == 0 {
		msg = "No tickets found for " + target + "."
	}
	return map[string]any{"file": target, "results": results, "message": msg}
}

func writeStatus(id, status string) bool {
	return replaceTicket(id, func(text string) string {
		return regexp.MustCompile(`(?m)^(status:\s*)(\S+)$`).ReplaceAllString(text, "${1}"+status)
	})
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

func createTicket(title, typ, status string, priority int, body string) ticket {
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
	text := fmt.Sprintf("---\nid: %s\ntitle: %s\nstatus: %s\ntype: %s\npriority: %d\ncreated: %s\n---\n\n%s\n", id, strings.ReplaceAll(title, "\n", " "), status, typ, priority, time.Now().Format("2006-01-02"), strings.TrimSpace(body))
	path := filepath.Join(dir, "ticket.md")
	os.WriteFile(path, []byte(text), 0644)
	t, _ := parseTicket(path)
	return t
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

func safeTicketDoc(docFile string) (string, bool) {
	clean := filepath.Clean(filepath.FromSlash(docFile))
	if filepath.IsAbs(clean) || strings.HasPrefix(clean, ".."+string(os.PathSeparator)) || filepath.Ext(clean) != ".md" {
		return "", false
	}
	p := filepath.Join(ticketsDir, clean)
	rel, err := filepath.Rel(ticketsDir, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", false
	}
	return p, true
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
