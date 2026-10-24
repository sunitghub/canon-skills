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
	if e, _ := out["handoff"]["error"].(string); !strings.Contains(e, "512 KB") || out["handoff"]["text"] != nil {
		t.Errorf("oversize HANDOFF.md = %v, want the size refusal and no text", out["handoff"])
	}
	writeFile(t, filepath.Join(root, "HANDOFF.md"), strings.Repeat("a", logbookMaxBytes))
	_, out = logbookGet(t, "GET", "/api/logbook")
	if out["handoff"]["text"] == nil {
		t.Errorf("a file of exactly 512 KB must still be served, got %v", out["handoff"])
	}

	// not a write route, and an unknown project is refused like the other project-scoped reads
	if code, _ := logbookGet(t, "POST", "/api/logbook"); code == http.StatusOK {
		t.Errorf("POST /api/logbook = %d, want a refusal", code)
	}
	if code, _ := logbookGet(t, "GET", "/api/logbook?project=nope"); code != http.StatusBadRequest {
		t.Errorf("GET /api/logbook?project=nope = %d, want 400", code)
	}
}
