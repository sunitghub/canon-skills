package board

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-5fd2: the board's doc, description and status writes (Docs editor, description editor, status moves) on a ticket not
// bound to a worktree. A missing or non-string value must never be written as "<nil>"/"map[...]", and a status must never
// add a frontmatter line; the shared POST parser stops reading at postBodyMax.
func TestPostFieldChecks(t *testing.T) {
	root := setupTestProject(t)
	_, out := tagsPost(t, "/api/tickets", `{"title":"victim"}`)
	id, _ := out["id"].(string)
	if id == "" {
		t.Fatalf("create = %v", out)
	}
	ticketPath := filepath.Join(root, ".tickets", id, "ticket.md")
	planPath := filepath.Join(root, ".tickets", id, "plan.md")
	docURL := "/api/doc/" + id + "%2Fplan.md"
	read := func(p string) string { b, _ := os.ReadFile(p); return string(b) }
	refused := func(name, target, body string, wantCode int, code, msg string) {
		t.Helper()
		ticketBefore, planBefore := read(ticketPath), read(planPath)
		got, o := tagsPost(t, target, body)
		if got != wantCode || o["ok"] != false || o["code"] != code || o["error"] != msg {
			t.Errorf("%s: %s %.60s = %d %v, want %d %s %q", name, target, body, got, o, wantCode, code, msg)
		}
		if read(ticketPath) != ticketBefore || read(planPath) != planBefore {
			t.Errorf("%s: a refused write changed a file", name)
		}
	}
	big := strings.Repeat("x", liveDocMaxBytes+1)
	for _, v := range []string{`{}`, `{"content":null}`, `{"content":1}`, `{"content":{"a":1}}`, `{"content":["x"]}`} {
		refused("doc "+v, docURL, v, http.StatusBadRequest, "bad_content", "content must be text")
	}
	refused("doc too large", docURL, `{"content":"`+big+`"}`, http.StatusBadRequest, "too_large", "that doc is too large to save from the board")
	if _, err := os.Stat(planPath); !os.IsNotExist(err) {
		t.Fatalf("plan.md exists after refusals: %v", err)
	}
	for _, v := range []string{`{}`, `{"body":null}`, `{"body":2}`, `{"body":{"a":1}}`} {
		refused("body "+v, "/api/ticket/"+id+"/body", v, http.StatusBadRequest, "bad_content", "body must be text")
	}
	refused("body too large", "/api/ticket/"+id+"/body", `{"body":"`+big+`"}`, http.StatusBadRequest, "too_large", "that description is too large to save from the board")
	for _, v := range []string{`{}`, `{"status":null}`, `{"status":3}`, `{"status":"done"}`, `{"status":"open\neval_override: true"}`, `{"status":"open "}`, `{"status":"OPEN"}`} {
		refused("status "+v, "/api/ticket/"+id+"/status", v, http.StatusBadRequest, "bad_status", "that is not a ticket status")
	}
	if strings.Contains(read(ticketPath), "eval_override: true") {
		t.Fatal("status injection reached ticket.md")
	}

	// valid writes save as before; the 1 MiB boundaries: a doc of exactly the cap and a body of the cap plus whitespace
	if c, o := tagsPost(t, docURL, `{"content":"x"}`); c != http.StatusOK || o["ok"] != true || read(planPath) != "x\n" {
		t.Errorf("doc save = %d %v, plan.md %q", c, o, read(planPath))
	}
	if c, o := tagsPost(t, docURL, `{"content":"`+big[:liveDocMaxBytes]+`"}`); c != http.StatusOK || o["ok"] != true {
		t.Errorf("doc of exactly %d bytes = %d %v", liveDocMaxBytes, c, o)
	}
	if c, o := tagsPost(t, "/api/ticket/"+id+"/body", `{"body":"  `+big[:liveDocMaxBytes]+`\n\n"}`); c != http.StatusOK || o["ok"] != true {
		t.Errorf("body of the cap plus whitespace = %d %v", c, o)
	}
	if c, o := tagsPost(t, "/api/ticket/"+id+"/body", `{"body":"new text"}`); c != http.StatusOK || o["ok"] != true || !strings.HasSuffix(read(ticketPath), "---\n\nnew text\n") {
		t.Errorf("body save = %d %v:\n%s", c, o, read(ticketPath))
	}
	if c, o := tagsPost(t, "/api/ticket/"+id+"/status", `{"status":"in_progress"}`); c != http.StatusOK || o["ok"] != true || !strings.Contains(read(ticketPath), "\nstatus: in_progress\n") {
		t.Errorf("status save = %d %v:\n%s", c, o, read(ticketPath))
	}

	// one owner: each refusal message is written once in the board's source, so a second copy in either path fails here
	srcs, _ := filepath.Glob("*.go")
	var all bytes.Buffer
	for _, f := range srcs {
		if !strings.HasSuffix(f, "_test.go") {
			b, _ := os.ReadFile(f)
			all.Write(b)
		}
	}
	for _, msg := range []string{`" must be text"`, `"that is not a ticket status"`, `" is too large to save from the board"`, `"bad_content"`, `"bad_status"`} {
		if n := strings.Count(all.String(), msg); n != 1 {
			t.Errorf("%s appears %d times in internal/board's source, want 1 (docField/statusField own it)", msg, n)
		}
	}
}

func TestPostBodyCap(t *testing.T) {
	root := setupTestProject(t)
	_, out := tagsPost(t, "/api/tickets", `{"title":"cap"}`)
	id, _ := out["id"].(string)
	planPath := filepath.Join(root, ".tickets", id, "plan.md")

	over := `{"content":"` + strings.Repeat("x", int(postBodyMax)) + `"}`
	if c, o := tagsPost(t, "/api/doc/"+id+"%2Fplan.md", over); c != http.StatusRequestEntityTooLarge || o["ok"] != false {
		t.Errorf("body over postBodyMax = %d %v, want 413", c, o)
	}
	if _, err := os.Stat(planPath); !os.IsNotExist(err) {
		t.Errorf("plan.md written by an over-cap body: %v", err)
	}

	// the largest legitimate request still fits: a visual of exactly maxVisualBytes, base64 in JSON
	raw := bytes.Repeat([]byte{0x89}, maxVisualBytes)
	req, _ := json.Marshal(map[string]string{"filename": "max.png", "data": base64.StdEncoding.EncodeToString(raw)})
	c, o := tagsPost(t, "/api/ticket/"+id+"/visual", string(req))
	if c != http.StatusOK || o["ok"] != true {
		t.Fatalf("visual of maxVisualBytes = %d %v", c, o)
	}
	if fi, err := os.Stat(filepath.Join(root, ".tickets", id, "visuals", "max.png")); err != nil || fi.Size() != maxVisualBytes {
		t.Errorf("visual not saved whole: %v", err)
	}
}
