package board

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

// t-c6bb: the Logbook is the board's read-only view of a project's HANDOFF.md and LEARNINGS.md (t-7f7c: also PROMOTED.md, DECISIONS.md, LEARNINGS-archive.md). The route serves each file's text
// and the page parses it, so this side knows no format. Both files can come from a PR or a clone, so only these fixed names
// under the project root are read, regular files only, up to a size cap. A failed read says why (and a missing file says so): it
// never looks like an empty file. t-40f8: 4 MB, a guard against an absurd file; canon's own DECISIONS.md passed 512 KB at 700 KB.
const logbookMaxBytes = 4 << 20

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
		return map[string]any{"error": name + " is larger than 4 MB"}
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"text": string(raw), "mtime": fi.ModTime().UTC().Format(time.RFC3339)}
}

// logbookFiles maps each reply key to its file (t-7f7c: the Promoted and Decisions tabs; same reader, same checks).
var logbookFiles = map[string]string{
	"handoff":           "HANDOFF.md",
	"learnings":         "LEARNINGS.md",
	"promoted":          "PROMOTED.md",
	"decisions":         "DECISIONS.md",
	"learnings_archive": "LEARNINGS-archive.md",
}

// loadLogbook reads every Logbook file, or with only (t-40f8: a comma list of reply keys, unknown keys ignored) just those:
// the Projects card polls this route every 30 s and shows only the learnings count.
func loadLogbook(root, only string) map[string]any {
	if root == "" {
		root = projectRoot
	}
	want := map[string]bool{}
	for _, k := range strings.Split(only, ",") {
		if _, ok := logbookFiles[k]; ok {
			want[k] = true
		}
	}
	out := map[string]any{}
	for key, name := range logbookFiles {
		if only == "" || want[key] {
			out[key] = readLogbookFile(root, name)
		}
	}
	return out
}
