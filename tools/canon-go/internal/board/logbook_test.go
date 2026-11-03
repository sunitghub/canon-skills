package board

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-c6bb: GET /api/logbook is what the board's Logbook button reads. It serves the text of the project root's HANDOFF.md and
// LEARNINGS.md and says why when it cannot: a missing, unreadable, symlinked or oversize file never looks like an empty one.
func logbookGet(t *testing.T, method, target string) (int, map[string]map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, "http://127.0.0.1"+target, nil)
	rec := httptest.NewRecorder()
	handle(rec, req)
	var out map[string]map[string]any
	if rec.Code == http.StatusOK {
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s %s: bad JSON: %v", method, target, err)
		}
	}
	return rec.Code, out
}

func TestLogbookRoute(t *testing.T) {
	root := setupTestProject(t)

	// both files: text and mtime come back verbatim
	writeFile(t, filepath.Join(root, "HANDOFF.md"), "# Handoff\n## Current Focus\nx <img src=x onerror=alert(1)>\n")
	writeFile(t, filepath.Join(root, "LEARNINGS.md"), "| 2026-10-23 | [t-1](.tickets/t-1/learnings.md) | f | UNPROMOTED |\n")
	code, out := logbookGet(t, "GET", "/api/logbook")
	if code != http.StatusOK {
		t.Fatalf("GET /api/logbook = %d, want 200", code)
	}
	if got := out["handoff"]["text"]; got != "# Handoff\n## Current Focus\nx <img src=x onerror=alert(1)>\n" {
		t.Errorf("handoff text = %q, want the file verbatim", got)
	}
	if out["handoff"]["mtime"] == nil || out["learnings"]["text"] == nil {
		t.Errorf("want mtime on handoff and text on learnings, got %v", out)
	}

	// t-7f7c: the three newer files come back like the first two: absent = missing, present = text and mtime, symlink / directory / oversize = an error and no text
	for _, f := range []struct{ key, name string }{{"promoted", "PROMOTED.md"}, {"decisions", "DECISIONS.md"}, {"learnings_archive", "LEARNINGS-archive.md"}} {
		if out[f.key]["missing"] != true || out[f.key]["text"] != nil {
			t.Errorf("absent %s = %v, want {missing:true}", f.name, out[f.key])
		}
		writeFile(t, filepath.Join(root, f.name), "# "+f.name+"\n")
		_, o := logbookGet(t, "GET", "/api/logbook")
		if o[f.key]["text"] != "# "+f.name+"\n" || o[f.key]["mtime"] == nil {
			t.Errorf("%s = %v, want its text and mtime", f.name, o[f.key])
		}
		os.Remove(filepath.Join(root, f.name))
		writeFile(t, filepath.Join(root, f.name), strings.Repeat("a", logbookMaxBytes+1))
		_, o = logbookGet(t, "GET", "/api/logbook")
		if e, _ := o[f.key]["error"].(string); !strings.Contains(e, "4 MB") || o[f.key]["text"] != nil {
			t.Errorf("oversize %s = %v, want the size refusal and no text", f.name, o[f.key])
		}
		os.Remove(filepath.Join(root, f.name))
		if err := os.Symlink(filepath.Join(root, "HANDOFF.md"), filepath.Join(root, f.name)); err == nil {
			_, o = logbookGet(t, "GET", "/api/logbook")
			if e, _ := o[f.key]["error"].(string); !strings.Contains(e, "symbolic link") || o[f.key]["text"] != nil {
				t.Errorf("symlinked %s = %v, want the symlink refusal and no text", f.name, o[f.key])
			}
			os.Remove(filepath.Join(root, f.name))
		}
		if err := os.Mkdir(filepath.Join(root, f.name), 0755); err != nil {
			t.Fatal(err)
		}
		_, o = logbookGet(t, "GET", "/api/logbook")
		if e, _ := o[f.key]["error"].(string); !strings.Contains(e, "not a regular file") {
			t.Errorf("directory %s error = %q", f.name, e)
		}
		os.Remove(filepath.Join(root, f.name))
	}

	// a missing file says so
	os.Remove(filepath.Join(root, "LEARNINGS.md"))
	_, out = logbookGet(t, "GET", "/api/logbook")
	if out["learnings"]["missing"] != true || out["learnings"]["text"] != nil {
		t.Errorf("missing LEARNINGS.md = %v, want {missing:true}", out["learnings"])
	}

	// a directory named like the file, a symlink and an oversize file each carry a reason
	os.Remove(filepath.Join(root, "HANDOFF.md"))
	if err := os.Mkdir(filepath.Join(root, "HANDOFF.md"), 0755); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(t.TempDir(), "secret.md")
	writeFile(t, other, "outside the project")
	if err := os.Symlink(other, filepath.Join(root, "LEARNINGS.md")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	_, out = logbookGet(t, "GET", "/api/logbook")
	if e, _ := out["handoff"]["error"].(string); !strings.Contains(e, "not a regular file") {
		t.Errorf("directory HANDOFF.md error = %q", e)
	}
	if e, _ := out["learnings"]["error"].(string); !strings.Contains(e, "symbolic link") || out["learnings"]["text"] != nil {
		t.Errorf("symlinked LEARNINGS.md = %v, want the symlink refusal and no text", out["learnings"])
	}
	os.Remove(filepath.Join(root, "HANDOFF.md"))
	os.Remove(filepath.Join(root, "LEARNINGS.md"))
	writeFile(t, filepath.Join(root, "HANDOFF.md"), strings.Repeat("a", logbookMaxBytes+1))
	_, out = logbookGet(t, "GET", "/api/logbook")
	if e, _ := out["handoff"]["error"].(string); !strings.Contains(e, "4 MB") || out["handoff"]["text"] != nil {
		t.Errorf("oversize HANDOFF.md = %v, want the size refusal and no text", out["handoff"])
	}
	writeFile(t, filepath.Join(root, "HANDOFF.md"), strings.Repeat("a", logbookMaxBytes))
	_, out = logbookGet(t, "GET", "/api/logbook")
	if out["handoff"]["text"] == nil {
		t.Errorf("a file of exactly 4 MB must still be served, got %v", out["handoff"])
	}

	// not a write route, and an unknown project is refused like the other project-scoped reads
	if code, _ := logbookGet(t, "POST", "/api/logbook"); code == http.StatusOK {
		t.Errorf("POST /api/logbook = %d, want a refusal", code)
	}
	if code, _ := logbookGet(t, "GET", "/api/logbook?project=nope"); code != http.StatusBadRequest {
		t.Errorf("GET /api/logbook?project=nope = %d, want 400", code)
	}
}

// t-40f8, prod path: GET /api/logbook. canon's own DECISIONS.md (about 700 KB) is read whole; the Projects card, which polls
// every 30 s and shows only the learnings count, asks for files=learnings and gets only that key, with no other file read.
func TestLogbookSizeAndFiles(t *testing.T) {
	root := setupTestProject(t)
	big := "| Date | Decision | Reason |\n|---|---|---|\n" + strings.Repeat("| 2026-10-01 | "+strings.Repeat("d", 1400)+" | r |\n", 500)
	writeFile(t, filepath.Join(root, "DECISIONS.md"), big)
	writeFile(t, filepath.Join(root, "LEARNINGS.md"), "| 2026-10-23 | [t-1](.tickets/t-1/learnings.md) | f | UNPROMOTED |\n")
	writeFile(t, filepath.Join(root, "HANDOFF.md"), "# Handoff\n")
	_, out := logbookGet(t, "GET", "/api/logbook")
	if len(big) < 700_000 || out["decisions"]["text"] != big {
		t.Fatalf("a %d-byte DECISIONS.md must be read whole, got error %v", len(big), out["decisions"]["error"])
	}
	if len(out) != 5 {
		t.Errorf("no files= must keep all five keys, got %d", len(out))
	}
	// over the cap DECISIONS.md is refused; the card's files=learnings never reads it, so its reply carries no error for it
	writeFile(t, filepath.Join(root, "DECISIONS.md"), strings.Repeat("a", logbookMaxBytes+1))
	for _, q := range []string{"files=learnings", "files=bogus,learnings", "files=learnings,../DECISIONS.md"} {
		_, o := logbookGet(t, "GET", "/api/logbook?"+q)
		if len(o) != 1 || o["learnings"]["text"] == nil {
			t.Errorf("%s = %v, want only learnings with its text", q, o)
		}
	}
	if _, o := logbookGet(t, "GET", "/api/logbook?files=decisions,handoff"); len(o) != 2 || o["handoff"]["text"] != "# Handoff\n" || o["decisions"]["error"] == nil {
		t.Errorf("files=decisions,handoff = %v, want those two keys (decisions refused for size)", o)
	}
}
