package board

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-3ba0: protects GET /api/projects' `missing` (the Projects card's alert and its disabled open button): true for a registered project
// whose folder was deleted, absent for one that exists, and never written back to the registry file.
func TestProjectsViewMarksMissingFolders(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	here := filepath.Join(t.TempDir(), "here")
	gone := filepath.Join(t.TempDir(), "gone")
	for _, d := range []string{here, gone} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	entries := []registryProject{{ID: "a", Path: here, Name: "here"}, {ID: "b", Path: gone, Name: "gone"}}
	if err := registrySave(entries); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(gone); err != nil {
		t.Fatal(err)
	}
	got := projectsView()
	if len(got) != 2 || got[0].Missing || !got[1].Missing {
		t.Fatalf("projectsView = %+v, want only the deleted folder missing", got)
	}
	raw, _ := json.Marshal(got)
	if !strings.Contains(string(raw), `"missing":true`) || strings.Count(string(raw), `"missing"`) != 1 {
		t.Fatalf("JSON %s: want exactly one missing:true", raw)
	}
	disk, err := os.ReadFile(registryFile())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(disk), "missing") {
		t.Fatalf("the registry file gained the computed field: %s", disk)
	}
	// The folder comes back: normal on the next read, nothing cached.
	if err := os.MkdirAll(gone, 0o755); err != nil {
		t.Fatal(err)
	}
	if again := projectsView(); again[1].Missing {
		t.Fatalf("a restored folder still reads missing: %+v", again)
	}
}
