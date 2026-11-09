package board

// t-3a58: Factory > Pipeline. GET /api/pipeline?project=<id> reads a project's resolved sprint pipeline and POST changes it.
//
// tools/pipeline.sh (t-00e0) is the one reader of skills/sprint/pipeline.yaml and a project's canon-config/pipeline.yaml: nothing
// here parses either file. A write never copies client text into the file: it applies an op (toggle, order, reset) to the state
// the resolver returned, renders `extends: canon-default` plus `off:` and `wrapup-order:` from node ids the resolver listed,
// proves the result by resolving it in a scratch project, then renames a temp file into place. The target is always
// <project root>/canon-config/pipeline.yaml; a symlinked or non-regular folder or file is refused, never followed.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	pipelineBodyMax = 16 << 10 // a request body: one op and at most three ids
	pipelineFileMax = 64 << 10 // the same bound tools/pipeline.sh holds a project file to
	pipelineWait    = 20 * time.Second
)

var (
	pipelineIDRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,39}$`)
	pipelineMu   sync.Mutex // one write at a time: two tabs cannot interleave their temp file and rename
)

type pipelineModel struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Source string `json:"source"`
}

type pipelineNode struct {
	ID     string         `json:"id"`
	Kind   string         `json:"kind"`
	Order  int            `json:"order"`
	On     bool           `json:"on"`
	Locked bool           `json:"locked"`
	Group  string         `json:"group,omitempty"`
	When   string         `json:"when,omitempty"`
	Prompt string         `json:"prompt,omitempty"`
	Reason string         `json:"reason,omitempty"`
	Model  *pipelineModel `json:"model,omitempty"`
}

// pipelineTool is the reader: PIPELINE_BIN (a test's stub) else tools/pipeline.sh, tools/pipeline.cmd on Windows (it starts Git Bash).
func pipelineTool() string {
	if b := os.Getenv("PIPELINE_BIN"); b != "" {
		return b
	}
	if runtime.GOOS == "windows" {
		if c := filepath.Join(toolsDir, "pipeline.cmd"); exists(c) {
			return c
		}
	}
	return filepath.Join(toolsDir, "pipeline.sh")
}

// runPipeline runs the reader and returns stdout, or the reader's first stderr line as the error (it refuses with one line).
func runPipeline(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), pipelineWait)
	defer cancel()
	cmd := exec.CommandContext(ctx, pipelineTool(), args...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return "", errors.New("pipeline: the reader did not finish within 20 s")
		}
		msg := strings.TrimSpace(strings.SplitN(errb.String(), "\n", 2)[0])
		if msg == "" {
			msg = "pipeline: the reader failed: " + err.Error()
		}
		return "", errors.New(pipelineClean(msg))
	}
	return out.String(), nil
}

// pipelineClean keeps printable ASCII only: a message is shown in the page and may name a hostile file's text.
func pipelineClean(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= ' ' && r <= '~' {
			b.WriteRune(r)
		} else {
			b.WriteByte('?')
		}
	}
	if b.Len() > 400 {
		return b.String()[:400]
	}
	return b.String()
}

// pipelineResolve is `pipeline.sh resolve --full [--project root]`: the nodes in run order. An empty root is canon's default alone.
func pipelineResolve(root string) ([]pipelineNode, error) {
	args := []string{"resolve", "--full"}
	if root != "" {
		args = append(args, "--project", root)
	}
	out, err := runPipeline(args...)
	if err != nil {
		return nil, err
	}
	var nodes []pipelineNode
	for _, line := range strings.Split(strings.TrimRight(out, "\r\n"), "\n") {
		line = strings.TrimSuffix(line, "\r")
		f := strings.Split(line, "\t")
		if len(f) != 9 || !pipelineIDRe.MatchString(f[1]) || len(nodes) >= 200 {
			return nil, errors.New("pipeline: the reader printed a line this page cannot read")
		}
		order, convErr := strconv.Atoi(f[0])
		if convErr != nil {
			return nil, errors.New("pipeline: the reader printed a line this page cannot read")
		}
		none := func(s string) string {
			if s == "-" {
				return ""
			}
			return pipelineClean(s)
		}
		nodes = append(nodes, pipelineNode{ID: f[1], Kind: pipelineClean(f[2]), Order: order, On: f[3] == "on", Locked: f[4] == "locked",
			Group: none(f[5]), When: none(f[6]), Prompt: none(f[7]), Reason: none(f[8])})
	}
	if len(nodes) == 0 {
		return nil, errors.New("pipeline: the reader printed no nodes")
	}
	return nodes, nil
}

func pipelineOff(nodes []pipelineNode) []string {
	off := []string{}
	for _, n := range nodes {
		if !n.On {
			off = append(off, n.ID)
		}
	}
	return off
}

func pipelineWrapup(nodes []pipelineNode) []string {
	w := []string{}
	for _, n := range nodes {
		if n.Group == "wrapup" {
			w = append(w, n.ID)
		}
	}
	return w
}

func pipelineSame(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// pipelineFileState looks at <root>/canon-config/pipeline.yaml without following a link. exists is true for a plain file;
// problem is set when the folder or the file is a symlink or not a regular file (nothing is read or written then).
func pipelineFileState(root string) (exists bool, text string, problem string) {
	dir := filepath.Join(root, "canon-config")
	di, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return false, "", ""
	}
	if err != nil || di.Mode()&os.ModeSymlink != 0 || !di.IsDir() {
		return false, "", "canon-config is not a plain folder (a symlink or a file), so it is left alone"
	}
	file := filepath.Join(dir, "pipeline.yaml")
	fi, err := os.Lstat(file)
	if errors.Is(err, os.ErrNotExist) {
		return false, "", ""
	}
	if err != nil || !fi.Mode().IsRegular() {
		return false, "", "canon-config/pipeline.yaml is not a plain file (a symlink or a folder), so it is left alone"
	}
	if fi.Size() > pipelineFileMax {
		return true, "", "" // not read here: the reader refuses it by name, and Reset rewrites it
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return true, "", "canon-config/pipeline.yaml cannot be read"
	}
	return true, strings.ReplaceAll(string(data), "\r", ""), ""
}

// pipelineModelFor is the display-only model of an agent row: the Admin Review & Eval default (Admin stays its one owner).
func pipelineModelFor(id string) *pipelineModel {
	if id != "reviewer" && id != "eval" {
		return nil
	}
	doc := loadModelTiers()
	want := evalDefault(doc)
	if want == "" {
		return nil
	}
	m := &pipelineModel{ID: want, Name: want, Source: "Admin > Model tiers > Review & Eval default"}
	models, _ := doc["models"].(map[string]any)
	list, _ := models["anthropic"].([]any)
	for _, e := range list {
		em, _ := e.(map[string]any)
		if em != nil && em["id"] == want {
			if n, _ := em["name"].(string); n != "" {
				m.Name = pipelineClean(n)
			}
		}
	}
	return m
}

// pipelineView is the reply of GET and of a successful POST.
func pipelineView(root string) map[string]any {
	exists, text, problem := pipelineFileState(root)
	out := map[string]any{"ok": true, "file": "canon-config/pipeline.yaml", "exists": exists, "text": text, "can_reset": exists && problem == ""}
	if problem != "" {
		out["ok"], out["error"] = false, problem
		return out
	}
	nodes, err := pipelineResolve(root)
	if err != nil {
		out["ok"], out["error"] = false, err.Error()
		return out
	}
	def, derr := pipelineResolve("")
	if derr != nil {
		out["ok"], out["error"] = false, derr.Error()
		return out
	}
	for i := range nodes {
		nodes[i].Model = pipelineModelFor(nodes[i].ID)
	}
	out["nodes"] = nodes
	out["changed"] = len(pipelineOff(nodes)) > 0 || !pipelineSame(pipelineWrapup(nodes), pipelineWrapup(def))
	return out
}

// pipelineRoot is the project root for ?project=: a registered path that is empty or relative is not a root (a join onto it would
// land in the board's working directory), so it is refused like an unknown project.
func pipelineRoot(r *http.Request) (string, bool) {
	root, ok := effectiveRoot(r)
	if !ok || root == "" || !filepath.IsAbs(root) {
		return "", false
	}
	return root, true
}

func pipelineCrossSite(r *http.Request) bool {
	return r.Header.Get("Sec-Fetch-Site") == "cross-site"
}

func handlePipelineGet(w http.ResponseWriter, r *http.Request) {
	// the route runs a tool, so a page on another site must not fire it blind (t-d271)
	if !originOK(r.Header.Get("Origin")) || pipelineCrossSite(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	root, ok := pipelineRoot(r)
	if !ok {
		http.Error(w, "unknown project", http.StatusBadRequest)
		return
	}
	sendJSON(w, pipelineView(root))
}

type pipelineRequest struct {
	Op     string   `json:"op"`
	ID     string   `json:"id"`
	On     *bool    `json:"on"`
	Wrapup []string `json:"wrapup"`
}

func pipelineFail(w http.ResponseWriter, status int, msg string) {
	sendJSONStatus(w, map[string]any{"ok": false, "error": pipelineClean(msg)}, status)
}

func handlePipelinePost(w http.ResponseWriter, r *http.Request) {
	// a write into the user's repo: a missing Origin is refused too, like the routes that start an agent (agentOriginOK)
	if !agentOriginOK(r) || pipelineCrossSite(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if strings.ToLower(strings.TrimSpace(strings.SplitN(r.Header.Get("Content-Type"), ";", 2)[0])) != "application/json" {
		pipelineFail(w, http.StatusUnsupportedMediaType, "expected application/json")
		return
	}
	root, ok := pipelineRoot(r)
	if !ok {
		http.Error(w, "unknown project", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, pipelineBodyMax))
	if err != nil {
		pipelineFail(w, http.StatusRequestEntityTooLarge, "request body over 16 KB")
		return
	}
	var req pipelineRequest
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if !pipelineKeysExact(body) || dec.Decode(&req) != nil {
		pipelineFail(w, http.StatusBadRequest, "bad request body")
		return
	}
	pipelineMu.Lock()
	defer pipelineMu.Unlock()
	res, status := pipelineApply(r, root, req)
	sendJSONStatus(w, res, status)
}

// pipelineKeysExact is true for one JSON object whose keys are exactly op, id, on or wrapup, each once, with nothing after it.
// encoding/json alone matches key names case-insensitively, keeps the last of a repeated key and ignores a stray closing brace.
func pipelineKeysExact(body []byte) bool {
	dec := json.NewDecoder(bytes.NewReader(body))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return false
	}
	seen := map[string]bool{}
	for dec.More() {
		kt, err := dec.Token()
		k, isKey := kt.(string)
		if err != nil || !isKey || (k != "op" && k != "id" && k != "on" && k != "wrapup") || seen[k] {
			return false
		}
		seen[k] = true
		var skip json.RawMessage
		if dec.Decode(&skip) != nil {
			return false
		}
	}
	if t, err := dec.Token(); err != nil || t != json.Delim('}') {
		return false
	}
	_, err := dec.Token()
	return err == io.EOF
}

// pipelineRender is the file for a state: only what differs from canon's default, from ids the resolver listed.
func pipelineRender(off, wrapup, defWrapup []string) string {
	var b strings.Builder
	b.WriteString("extends: canon-default\n")
	if len(off) > 0 {
		b.WriteString("off: [" + strings.Join(off, ", ") + "]\n")
	}
	if !pipelineSame(wrapup, defWrapup) {
		b.WriteString("wrapup-order: [" + strings.Join(wrapup, ", ") + "]\n")
	}
	return b.String()
}

func pipelineApply(r *http.Request, root string, req pipelineRequest) (map[string]any, int) {
	bad := func(status int, msg string) (map[string]any, int) {
		return map[string]any{"ok": false, "error": pipelineClean(msg)}, status
	}
	if req.Op != "toggle" && req.Op != "order" && req.Op != "reset" {
		return bad(http.StatusBadRequest, "op must be toggle, order or reset")
	}
	exists, text, problem := pipelineFileState(root)
	if problem != "" {
		return bad(http.StatusConflict, problem)
	}
	def, err := pipelineResolve("")
	if err != nil {
		return bad(http.StatusInternalServerError, err.Error())
	}
	defWrapup := pipelineWrapup(def)
	nodes, rerr := pipelineResolve(root)
	if rerr != nil && req.Op != "reset" {
		return bad(http.StatusBadRequest, rerr.Error()) // a file the reader refuses is only repaired by Reset
	}
	var off, wrapup []string
	switch req.Op {
	case "reset":
		off, wrapup = []string{}, defWrapup
		if !exists {
			return pipelineViewReply(root, false), http.StatusOK // nothing to rewrite, nothing is created
		}
	case "toggle":
		if !pipelineIDRe.MatchString(req.ID) {
			return bad(http.StatusBadRequest, "bad node id")
		}
		if req.On == nil {
			return bad(http.StatusBadRequest, "toggle needs on: true or false")
		}
		var target *pipelineNode
		for i := range nodes {
			if nodes[i].ID == req.ID {
				target = &nodes[i]
			}
		}
		if target == nil {
			return bad(http.StatusBadRequest, "unknown node '"+req.ID+"'")
		}
		if target.Locked {
			return bad(http.StatusBadRequest, "node '"+req.ID+"' is locked: "+target.Reason)
		}
		off = []string{}
		for _, n := range nodes {
			isOff := !n.On
			if n.ID == req.ID {
				isOff = !*req.On
			}
			if isOff {
				off = append(off, n.ID)
			}
		}
		wrapup = pipelineWrapup(nodes)
	case "order":
		cur := pipelineWrapup(nodes)
		if len(req.Wrapup) != len(cur) {
			return bad(http.StatusBadRequest, "wrapup must list exactly: "+strings.Join(cur, ", "))
		}
		seen := map[string]bool{}
		for _, id := range cur {
			seen[id] = true
		}
		for _, id := range req.Wrapup {
			if !seen[id] {
				return bad(http.StatusBadRequest, "wrapup must list exactly: "+strings.Join(cur, ", "))
			}
			delete(seen, id)
		}
		off, wrapup = pipelineOff(nodes), req.Wrapup
	}
	content := pipelineRender(off, wrapup, defWrapup)
	if !exists && len(off) == 0 && pipelineSame(wrapup, defWrapup) {
		return pipelineViewReply(root, false), http.StatusOK // a change back to canon's default with no file: no file
	}
	if exists && content == text {
		return pipelineViewReply(root, false), http.StatusOK
	}
	if msg := pipelineProve(content); msg != "" {
		return bad(http.StatusInternalServerError, "the generated file was refused, nothing written: "+msg)
	}
	created, werr := pipelineWrite(root, content)
	if werr != nil {
		return bad(http.StatusConflict, werr.Error())
	}
	oldOff := []string{}
	if nodes != nil {
		oldOff = pipelineOff(nodes)
	}
	emitSetting(r, "pipeline."+req.Op, pipelineSummary(oldOff), pipelineSummary(off))
	return pipelineViewReply(root, created), http.StatusOK
}

func pipelineSummary(off []string) string {
	s := "off=-"
	if len(off) > 0 {
		s = "off=" + strings.Join(off, ",")
	}
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}

func pipelineViewReply(root string, created bool) map[string]any {
	v := pipelineView(root)
	v["created"] = created
	return v
}

// pipelineProve resolves the generated file in a scratch project; an empty string means the reader accepts it.
func pipelineProve(content string) string {
	tmp, err := os.MkdirTemp("", "canon-pipeline-")
	if err != nil {
		return "no scratch folder"
	}
	defer os.RemoveAll(tmp)
	if os.Mkdir(filepath.Join(tmp, "canon-config"), 0o755) != nil ||
		os.WriteFile(filepath.Join(tmp, "canon-config", "pipeline.yaml"), []byte(content), 0o644) != nil {
		return "no scratch file"
	}
	if _, err := runPipeline("resolve", "--project", tmp); err != nil {
		return err.Error()
	}
	return ""
}

// pipelineWrite puts content at <root>/canon-config/pipeline.yaml through a temp file in the same folder and a rename. The folder is
// created on the first write (created reports it). The target is re-checked right before the rename: a link or a non-regular file
// is refused.
func pipelineWrite(root, content string) (created bool, err error) {
	dir := filepath.Join(root, "canon-config")
	file := filepath.Join(dir, "pipeline.yaml")
	exists, _, problem := pipelineFileState(root)
	if problem != "" {
		return false, errors.New(problem)
	}
	if _, serr := os.Lstat(dir); errors.Is(serr, os.ErrNotExist) {
		if err := os.Mkdir(dir, 0o755); err != nil {
			return false, errors.New("canon-config could not be created: " + pipelineClean(err.Error()))
		}
	}
	created = !exists
	tmp, err := os.CreateTemp(dir, ".pipeline-*.tmp")
	if err != nil {
		return false, errors.New("canon-config/pipeline.yaml could not be written: " + pipelineClean(err.Error()))
	}
	name := tmp.Name()
	defer os.Remove(name) // a failed run leaves no temp file; after a rename the name is gone and this is a no-op
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return false, errors.New("canon-config/pipeline.yaml could not be written")
	}
	if err := tmp.Chmod(0o644); err != nil && runtime.GOOS != "windows" {
		tmp.Close()
		return false, errors.New("canon-config/pipeline.yaml could not be written")
	}
	if err := tmp.Close(); err != nil {
		return false, errors.New("canon-config/pipeline.yaml could not be written")
	}
	if _, _, p := pipelineFileState(root); p != "" {
		return false, errors.New(p)
	}
	if err := os.Rename(name, file); err != nil {
		return false, errors.New("canon-config/pipeline.yaml could not be replaced: " + pipelineClean(err.Error()))
	}
	return created, nil
}
