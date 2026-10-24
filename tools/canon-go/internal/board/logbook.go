package board

import (
	"os"
	"path/filepath"
	"time"
)

// t-c6bb: the Logbook is the board's read-only view of a project's HANDOFF.md and LEARNINGS.md. The route serves each file's text
// and the page parses it, so this side knows no format. Both files can come from a PR or a clone, so only these two fixed names
// under the project root are read, regular files only, up to a size cap. A failed read says why (and a missing file says so): it
// never looks like an empty file.
const logbookMaxBytes = 512 * 1024

func readLogbookFile(root, name string) map[string]any {
	p := filepath.Join(root, name)
	fi, err := os.Lstat(p)
	if os.IsNotExist(err) {
		return map[string]any{"missing": true}
	}
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return map[string]any{"error": name + " is a symbolic link; the Logbook reads regular files only"}
	}
	if !fi.Mode().IsRegular() {
		return map[string]any{"error": name + " is not a regular file"}
	}
	if fi.Size() > logbookMaxBytes {
		return map[string]any{"error": name + " is larger than 512 KB"}
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"text": string(raw), "mtime": fi.ModTime().UTC().Format(time.RFC3339)}
}

func loadLogbook(root string) map[string]any {
	if root == "" {
		root = projectRoot
	}
	return map[string]any{
		"handoff":   readLogbookFile(root, "HANDOFF.md"),
		"learnings": readLogbookFile(root, "LEARNINGS.md"),
	}
}
