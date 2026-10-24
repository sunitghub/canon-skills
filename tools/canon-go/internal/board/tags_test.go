package board

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-37e8: ticket tags. Prod paths: tkt and the board must agree on what a tag is (one corpus, tests/tags-corpus.tsv, is run
// through both), and the board's three tag routes must never write a line a user did not mean (frontmatter injection).
func tagsPost(t *testing.T, target, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest("POST", "http://127.0.0.1"+target, strings.NewReader(body))
	rec := httptest.NewRecorder()
	handle(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestNormalizeTagsCorpus(t *testing.T) {
	f, err := os.Open(filepath.Join("..", "..", "..", "..", "tests", "tags-corpus.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		in, want, _ := strings.Cut(line, "\t")
		got, err := normalizeTags(in)
		if want == "ERR" {
			if err == nil {
				t.Errorf("normalizeTags(%q) = %v, want an error", in, got)
			}
		} else if err != nil || strings.Join(got, ",") != want {
			t.Errorf("normalizeTags(%q) = %v, %v; want %q", in, got, err, want)
		}
		n++
	}
	if n < 15 {
		t.Fatalf("the corpus has only %d rows", n)
	}
}

// A newline is refused, never trimmed: tkt refuses it too (tests/ticket-tags.sh), and the corpus file is line-based so it cannot hold one.
func TestNormalizeTagsRefusesNewlines(t *testing.T) {
	for _, in := range []string{"go\n", "go\r", "a\nb", "\ngo", "a,b\r\nc"} {
		if got, err := normalizeTags(in); err == nil {
			t.Errorf("normalizeTags(%q) = %v, want an error", in, got)
		}
	}
}

func TestTagRoutes(t *testing.T) {
	root := setupTestProject(t)

	// create with tags writes one tags line; a hostile or invalid list writes no ticket at all
	code, out := tagsPost(t, "/api/tickets", `{"title":"tagged","tags":["Security","nodejs"]}`)
	id, _ := out["id"].(string)
	if code != http.StatusOK || id == "" || out["tags"] != "security,nodejs" {
		t.Fatalf("create with tags = %d %v", code, out)
	}
	raw, _ := os.ReadFile(filepath.Join(root, ".tickets", id, "ticket.md"))
	if strings.Count(string(raw), "\ntags: security,nodejs\n") != 1 {
		t.Errorf("ticket.md lacks exactly one tags line:\n%s", raw)
	}
	before, _ := os.ReadDir(filepath.Join(root, ".tickets"))
	for _, bad := range []string{`["a\nstatus: closed"]`, `["x: y"]`, `["---"]`, `"a,b,c,d,e,f,g,h,i"`, `[1]`, `{"a":1}`} {
		code, out := tagsPost(t, "/api/tickets", `{"title":"evil","tags":`+bad+`}`)
		if code != http.StatusBadRequest || out["ok"] != false || out["error"] == nil {
			t.Errorf("create with tags %s = %d %v, want 400 with a reason", bad, code, out)
		}
	}
	if after, _ := os.ReadDir(filepath.Join(root, ".tickets")); len(after) != len(before) {
		t.Errorf("a refused create left a ticket behind: %d -> %d entries", len(before), len(after))
	}
	// a ticket without tags has no tags line
	_, plain := tagsPost(t, "/api/tickets", `{"title":"plain"}`)
	pid, _ := plain["id"].(string)
	praw, _ := os.ReadFile(filepath.Join(root, ".tickets", pid, "ticket.md"))
	if strings.Contains(string(praw), "tags:") {
		t.Errorf("a ticket created without tags has a tags line:\n%s", praw)
	}

	// replace, then clear, tags of an existing ticket; the rest of the frontmatter is untouched
	code, out = tagsPost(t, "/api/ticket/"+pid+"/tags", `{"tags":["go","GitHub"]}`)
	if code != http.StatusOK || out["ok"] != true {
		t.Fatalf("set tags = %d %v", code, out)
	}
	praw, _ = os.ReadFile(filepath.Join(root, ".tickets", pid, "ticket.md"))
	if !strings.Contains(string(praw), "\ntags: go,github\n") || !strings.Contains(string(praw), "\nstatus: open\n") {
		t.Errorf("after set:\n%s", praw)
	}
	tagsPost(t, "/api/ticket/"+pid+"/tags", `{"tags":[]}`)
	praw, _ = os.ReadFile(filepath.Join(root, ".tickets", pid, "ticket.md"))
	if strings.Contains(string(praw), "tags:") {
		t.Errorf("after clearing, a tags line remains:\n%s", praw)
	}
	if code, _ := tagsPost(t, "/api/ticket/"+pid+"/tags", `{"tags":["bad tag"]}`); code != http.StatusBadRequest {
		t.Errorf("set invalid tag = %d, want 400", code)
	}
	if code, _ := tagsPost(t, "/api/ticket/t-zzzz/tags", `{"tags":["go"]}`); code != http.StatusNotFound {
		t.Errorf("set tags on a missing ticket = %d, want 404", code)
	}
}

func TestProjectTagList(t *testing.T) {
	root := setupTestProject(t)
	get := func() map[string]any {
		rec := httptest.NewRecorder()
		handle(rec, httptest.NewRequest("GET", "http://127.0.0.1/api/tags", nil))
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return out
	}
	out := get()
	if s, _ := out["starter"].([]any); len(s) != len(starterTags) || len(out["project"].([]any)) != 0 || out["error"] != nil {
		t.Fatalf("fresh project: %v", out)
	}
	if code, _ := tagsPost(t, "/api/tags", `{"tag":"Billing"}`); code != http.StatusOK {
		t.Fatalf("add tag = %d", code)
	}
	tagsPost(t, "/api/tags", `{"tag":"billing"}`) // again: no duplicate
	tagsPost(t, "/api/tags", `{"tag":"github"}`)  // a starter: not added to the project's list
	if p := get()["project"].([]any); len(p) != 1 || p[0] != "billing" {
		t.Errorf("project list = %v, want [billing]", p)
	}
	if code, _ := tagsPost(t, "/api/tags", `{"tag":"a,b"}`); code != http.StatusBadRequest {
		t.Errorf("adding two at once = %d, want 400", code)
	}
	if code, _ := tagsPost(t, "/api/tags", `{"tag":"x\ny"}`); code != http.StatusBadRequest {
		t.Errorf("adding an invalid tag = %d, want 400", code)
	}
	// a corrupt file is reported and never overwritten
	file := filepath.Join(root, ".tickets", "tags.json")
	writeFile(t, file, `{"not":"an array"`)
	if e, _ := get()["error"].(string); !strings.Contains(e, "tags.json") {
		t.Errorf("corrupt file not reported: %v", get())
	}
	if code, _ := tagsPost(t, "/api/tags", `{"tag":"newtag"}`); code != http.StatusBadRequest {
		t.Errorf("add over a corrupt file = %d, want 400", code)
	}
	if b, _ := os.ReadFile(file); string(b) != `{"not":"an array"` {
		t.Errorf("a corrupt tags.json was overwritten: %q", b)
	}
	writeFile(t, file, `["fine","bad tag"]`)
	if e, _ := get()["error"].(string); !strings.Contains(e, "bad tag") {
		t.Errorf("an invalid entry is not reported: %v", get())
	}
}

func TestParseTicketTags(t *testing.T) {
	root := setupTestProject(t)
	writeFile(t, filepath.Join(root, ".tickets", "t-aaaa", "ticket.md"), "---\nid: t-aaaa\nstatus: open\ntags: security,nodejs\n---\n# x\n")
	writeFile(t, filepath.Join(root, ".tickets", "t-bbbb", "ticket.md"), "---\nid: t-bbbb\nstatus: open\n---\n# y\n")
	a, _ := parseTicket(filepath.Join(root, ".tickets", "t-aaaa", "ticket.md"))
	b, _ := parseTicket(filepath.Join(root, ".tickets", "t-bbbb", "ticket.md"))
	if a["tags"] != "security,nodejs" {
		t.Errorf("tags = %v", a["tags"])
	}
	if _, has := b["tags"]; has {
		t.Errorf("a ticket without tags carries one: %v", b["tags"])
	}
}
