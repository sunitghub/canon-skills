package board

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// t-37e8: ticket tags. A ticket's tags are the frontmatter line `tags: a,b`; this file is the one owner of what a tag is. `tkt`
// mirrors the rule in shell (tests/ticket-tags.sh runs one corpus through both), and the browser only mirrors it for hints.
// A tag is typed by a user and written into a file, so it is refused, never repaired, unless it is a plain lowercase word:
// nothing that could start another frontmatter line (a newline, `---`, `: `) can get through.
const maxTags = 8

var ticketTagRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,23}$`)

type starterTag struct {
	Tag   string `json:"tag"`
	Label string `json:"label"`
}

// The dropdown's starting list; a project adds its own in <project>/.tickets/tags.json.
var starterTags = []starterTag{
	{"enterprise", "Enterprise"}, {"github", "GitHub"}, {"security", "Security"}, {"nodejs", "NodeJs"}, {"go", "Go"},
	{"logging", "Logging"}, {"events", "Events"}, {"tracing", "Tracing"}, {"board", "Board"}, {"cockpit", "Cockpit"},
	{"cli", "CLI"}, {"windows", "Windows"}, {"installer", "Installer"}, {"docs", "Docs"}, {"tests", "Tests"},
	{"release", "Release"}, {"performance", "Performance"}, {"cloud", "Cloud"}, {"skills", "Skills"}, {"ci", "CI"},
	{"now", "Now"},       // t-0447: the board's NOW lane reads this tag, so it is offered, never typed in
	{"sample", "Sample"}, // t-4371: tickets that add to samples/
}

// normalizeTags turns a comma list into the stored form: lowercase, trimmed, empty entries dropped, duplicates dropped with the
// first one's place kept. It returns an error naming the first tag that is not valid, or the 9th.
func normalizeTags(csv string) ([]string, error) {
	if strings.ContainsAny(csv, "\r\n") { // as tkt: a newline is never trimmed away, it is refused
		return nil, fmt.Errorf("tags must be on one line")
	}
	for i := 0; i < len(csv); i++ { // as tkt (LC_ALL=C): any non-ASCII byte is refused, so no Unicode space trims and no Kelvin sign folds to k
		if csv[i] >= 0x80 {
			return nil, fmt.Errorf("tags must be plain ASCII: use lowercase letters, digits and dashes")
		}
	}
	var out []string
	seen := map[string]bool{}
	for _, raw := range strings.Split(csv, ",") {
		t := strings.ToLower(strings.TrimSpace(raw))
		if t == "" || seen[t] {
			continue
		}
		if !ticketTagRe.MatchString(t) {
			return nil, fmt.Errorf("%q is not a valid tag: use lowercase letters, digits and dashes, 1 to 24 characters, starting with a letter or digit", raw)
		}
		if len(out) == maxTags {
			return nil, fmt.Errorf("a ticket can have at most %d tags", maxTags)
		}
		seen[t] = true
		out = append(out, t)
	}
	return out, nil
}

// tagsPayload reads tags from a JSON payload: an array of strings or a comma string.
func tagsPayload(v any) (string, bool) {
	switch x := v.(type) {
	case nil:
		return "", true
	case string:
		return x, true
	case []any:
		parts := make([]string, 0, len(x))
		for _, e := range x {
			s, ok := e.(string)
			if !ok {
				return "", false
			}
			parts = append(parts, s)
		}
		return strings.Join(parts, ","), true
	}
	return "", false
}

// tagsFrontmatterLine is "tags: a,b" (without a newline), or "" for no tags (absent line = none, as skills and demo).
func tagsFrontmatterLine(tags []string) string {
	if len(tags) == 0 {
		return ""
	}
	return "tags: " + strings.Join(tags, ",")
}

// setTagsLine returns the frontmatter lines with every `tags:` line replaced by the new one (appended last when new).
func setTagsLine(lines []string, tags []string) []string {
	var kept []string
	for _, ln := range lines {
		if !strings.HasPrefix(ln, "tags:") {
			kept = append(kept, ln)
		}
	}
	if l := tagsFrontmatterLine(tags); l != "" {
		kept = append(kept, l)
	}
	return kept
}

// writeTags replaces an existing ticket's tags (main checkout copy). It returns false when the ticket or its frontmatter is missing.
func writeTags(id string, tags []string, root string) bool {
	path := findTicketPath(id, root)
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
	updated := "---\n" + strings.Join(setTagsLine(strings.Split(text[m[2]:m[3]], "\n"), tags), "\n") + "\n---\n" + text[m[1]:]
	if updated != text {
		return atomicWriteFile(path, []byte(updated)) == nil
	}
	return true
}

func projectTagsFile(root string) string {
	return filepath.Join(ticketsDirForRoot(root), "tags.json")
}

// readProjectTags returns the tags a project added. A missing file is none; an unreadable, non-array or invalid file is an
// error, so a broken file is shown to the user and never overwritten.
func readProjectTags(root string) ([]string, error) {
	data, err := os.ReadFile(projectTagsFile(root))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("tags.json could not be read: %v", err)
	}
	var list []string
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, fmt.Errorf("tags.json is not a JSON array of strings: fix or delete it (%v)", err)
	}
	if list == nil { // JSON null unmarshals to a nil slice without error: refuse it like any non-array file
		return nil, fmt.Errorf("tags.json is not a JSON array of strings: fix or delete it (it holds null)")
	}
	for _, t := range list {
		if !ticketTagRe.MatchString(t) {
			return nil, fmt.Errorf("tags.json holds %q, which is not a valid tag: fix or delete it", t)
		}
	}
	return list, nil
}

func isStarterTag(t string) bool {
	for _, s := range starterTags {
		if s.Tag == t {
			return true
		}
	}
	return false
}

// addProjectTag adds one valid tag to the project's list (a no-op for a starter or an already added tag).
func addProjectTag(root, tag string) error {
	tags, err := normalizeTags(tag)
	if err != nil {
		return err
	}
	if len(tags) != 1 {
		return fmt.Errorf("add one tag at a time")
	}
	t := tags[0]
	list, err := readProjectTags(root)
	if err != nil {
		return err
	}
	if isStarterTag(t) {
		return nil
	}
	for _, e := range list {
		if e == t {
			return nil
		}
	}
	list = append(list, t)
	data, _ := json.MarshalIndent(list, "", "  ")
	if err := os.MkdirAll(ticketsDirForRoot(root), 0755); err != nil {
		return fmt.Errorf("tags.json could not be written: %v", err)
	}
	if err := atomicWriteFile(projectTagsFile(root), append(data, '\n')); err != nil {
		return fmt.Errorf("tags.json could not be written: %v", err)
	}
	return nil
}

// tagsAnswer is GET /api/tags: the starter list and the project's own, and why the project's could not be read.
func tagsAnswer(root string) map[string]any {
	project, err := readProjectTags(root)
	if project == nil {
		project = []string{}
	}
	out := map[string]any{"starter": starterTags, "project": project}
	if err != nil {
		out["error"] = err.Error()
	}
	return out
}

func sendTagError(w http.ResponseWriter, err error) {
	sendJSONStatus(w, map[string]any{"ok": false, "error": err.Error()}, http.StatusBadRequest)
}
