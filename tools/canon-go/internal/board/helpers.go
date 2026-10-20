// helpers.go — the board binary's helper subcommands (t-b62a). They replace the inline python3 the shell
// tools ran (and the Windows-only sprint-headless-json-win.exe and settings-merge.ps1), so no shipped path
// needs Python: the board binary is fetched on every OS already.
//
//	sprint-check headless-json                     claude -p's JSON on stdin -> one TSV line (tools/sprint-headless*)
//	sprint-check json-strings <file>               a JSON array of strings -> one per line (--allowed-tools-file)
//	sprint-check settings <status|add|remove> <settings.json> <allow|deny> <rule>...
//	                                               permissions rules in .claude/settings.json (tools/skills/prompts.sh)
//	sprint-check skill-check <skill-dir>           the Skill Eval checks as JSON (was tools/skill-check)
//	sprint-check event <kind> --project <dir> --source <name> key=value...   (sources: internal/events)
//	                                               one event line (t-f182); always exits 0, prints nothing
package board

import (
	"bytes"
	"canon/internal/events"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// runHelper runs a helper subcommand; handled is false when args[0] names none (the board starts instead).
func runHelper(args []string, stdin io.Reader, stdout, stderr io.Writer) (code int, handled bool) {
	if len(args) == 0 {
		return 0, false
	}
	switch args[0] {
	case "headless-json":
		data, err := io.ReadAll(stdin)
		if err != nil {
			fmt.Fprintln(stderr, "sprint-check headless-json: cannot read stdin:", err)
			return 1, true
		}
		fmt.Fprintln(stdout, formatHeadlessResult(data))
		return 0, true
	case "json-strings":
		if len(args) != 2 {
			fmt.Fprintln(stderr, "usage: sprint-check json-strings <file>")
			return 2, true
		}
		return jsonStrings(args[1], stdout, stderr), true
	case "settings":
		if len(args) < 4 {
			fmt.Fprintln(stderr, "usage: sprint-check settings <status|add|remove> <settings.json> <allow|deny> <rule>...")
			return 2, true
		}
		word, err := editSettings(args[1], args[2], args[3], args[4:])
		if err != nil {
			fmt.Fprintln(stderr, "sprint-check settings:", err)
			if word == "" {
				return 1, true
			}
		}
		fmt.Fprintln(stdout, word)
		return 0, true
	case "skill-check":
		return skillCheckCLI(args[1:], stdout, stderr), true
	case "event":
		emitEventCLI(args[1:])
		return 0, true // observer-only: an event never changes the caller's outcome
	}
	return 0, false
}

// formatHeadlessResult turns `claude -p --output-format json` into "<is_error>\t<session_id>\t<result>" for
// the shell: is_error as Python's str(bool) ("True"/"False"; absent or null reads True, so the caller's
// != "False" check fails closed), session_id "unknown" when absent, the result's newlines as \x02 so one
// line carries it through `cut` (the caller restores them with tr). Bad JSON prints "PARSE_ERROR\t\t".
func formatHeadlessResult(data []byte) string {
	var r struct {
		IsError   *bool   `json:"is_error"`
		SessionID *string `json:"session_id"`
		Result    *string `json:"result"`
	}
	if err := json.Unmarshal(data, &r); err != nil {
		return "PARSE_ERROR\t\t"
	}
	isError := "True"
	if r.IsError != nil && !*r.IsError {
		isError = "False"
	}
	sessionID := "unknown"
	if r.SessionID != nil {
		sessionID = *r.SessionID
	}
	result := ""
	if r.Result != nil {
		result = strings.ReplaceAll(*r.Result, "\n", "\x02")
	}
	return isError + "\t" + sessionID + "\t" + result
}

// jsonStrings prints each string of a JSON array file on its own line; exit 2 with the reason otherwise.
func jsonStrings(path string, stdout, stderr io.Writer) int {
	b, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(stderr, "Error: cannot read --allowed-tools-file: %v\n", err)
		return 2
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		fmt.Fprintf(stderr, "Error: invalid JSON in --allowed-tools-file: %v\n", err)
		return 2
	}
	list, ok := v.([]any)
	var out []string
	for _, x := range list {
		s, isStr := x.(string)
		if !isStr {
			ok = false
			break
		}
		out = append(out, s)
	}
	if !ok {
		fmt.Fprintln(stderr, "Error: --allowed-tools-file must be a JSON array of strings.")
		return 2
	}
	for _, s := range out {
		if strings.Contains(s, "\n") {
			fmt.Fprintln(stderr, "Error: tool entries must not contain newlines.")
			return 2
		}
	}
	for _, s := range out {
		fmt.Fprintln(stdout, s)
	}
	return 0
}

// orderedObject is a JSON object that keeps its key order and each value's own text, so a settings edit
// changes only the list it means to (t-f01d: never disturb a user's other keys).
type orderedObject struct {
	keys []string
	vals map[string]json.RawMessage
}

func parseOrderedObject(raw []byte) (*orderedObject, bool) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil, false
	}
	o := &orderedObject{vals: map[string]json.RawMessage{}}
	for dec.More() {
		t, err := dec.Token()
		k, isKey := t.(string)
		if err != nil || !isKey {
			return nil, false
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, false
		}
		if _, dup := o.vals[k]; !dup { // a repeated key keeps its first place and its last value, as Python's json does
			o.keys = append(o.keys, k)
		}
		o.vals[k] = v
	}
	if t, err := dec.Token(); err != nil || t != json.Delim('}') {
		return nil, false
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, false
	}
	return o, true
}

func (o *orderedObject) set(k string, v json.RawMessage) {
	if _, ok := o.vals[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.vals[k] = v
}

func (o *orderedObject) del(k string) {
	if _, ok := o.vals[k]; !ok {
		return
	}
	delete(o.vals, k)
	for i, key := range o.keys {
		if key == k {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
}

func (o *orderedObject) marshal() json.RawMessage {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range o.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, _ := marshalNoEscape(k)
		b.Write(kb)
		b.WriteByte(':')
		b.Write(o.vals[k])
	}
	b.WriteByte('}')
	return b.Bytes()
}

func marshalNoEscape(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

var errSettingsInvalid = errors.New("not a JSON object with an object `permissions` and a list there (left as is)")

// editSettings reads or edits permissions.<key> in a Claude Code settings file and returns the one word
// tools/skills/prompts.sh reads: present | absent (status), ok (add, remove) or invalid. An invalid or
// symlinked file is never written; a write is a temp file renamed over the original, keeping its mode.
func editSettings(mode, path, key string, rules []string) (string, error) {
	if mode != "status" && mode != "add" && mode != "remove" {
		return "", fmt.Errorf("mode must be status, add or remove, not %q", mode)
	}
	if key != "allow" && key != "deny" {
		return "", fmt.Errorf("list must be allow or deny, not %q", key)
	}
	none := map[string]string{"status": "absent", "add": "", "remove": "ok"}[mode]
	perm := os.FileMode(0o644)
	root := &orderedObject{vals: map[string]json.RawMessage{}}
	st, err := os.Lstat(path)
	switch {
	case err == nil && st.Mode()&os.ModeSymlink != 0:
		return "invalid", fmt.Errorf("%s is a symbolic link: edit the file it points to by hand", path)
	case err == nil && !st.Mode().IsRegular():
		return "invalid", fmt.Errorf("%s is not a regular file", path)
	case err == nil:
		perm = st.Mode().Perm()
		raw, rerr := os.ReadFile(path)
		if rerr != nil {
			return "", rerr
		}
		raw = bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")) // Windows PowerShell 5.1 writes a BOM; the JSON is still good
		o, ok := parseOrderedObject(raw)
		if !ok {
			return "invalid", errSettingsInvalid
		}
		root = o
	case errors.Is(err, os.ErrNotExist):
		if none != "" {
			return none, nil
		}
	default:
		return "", err
	}

	perms := &orderedObject{vals: map[string]json.RawMessage{}}
	if raw, ok := root.vals["permissions"]; ok {
		o, ok := parseOrderedObject(raw)
		if !ok {
			return "invalid", errSettingsInvalid
		}
		perms = o
	} else if none != "" {
		return none, nil
	}
	var list []json.RawMessage
	if raw, ok := perms.vals[key]; ok {
		if err := json.Unmarshal(raw, &list); err != nil || bytes.HasPrefix(bytes.TrimSpace(raw), []byte("null")) {
			return "invalid", errSettingsInvalid
		}
	}
	has := func(rule string) bool {
		for _, item := range list {
			var s string
			if json.Unmarshal(item, &s) == nil && s == rule {
				return true
			}
		}
		return false
	}

	switch mode {
	case "status":
		for _, r := range rules {
			if !has(r) {
				return "absent", nil
			}
		}
		return "present", nil
	case "add":
		for _, r := range rules {
			if !has(r) {
				b, _ := marshalNoEscape(r)
				list = append(list, b)
			}
		}
	case "remove":
		kept := list[:0:0]
		for _, item := range list {
			var s string
			if json.Unmarshal(item, &s) == nil && contains(rules, s) {
				continue
			}
			kept = append(kept, item)
		}
		list = kept
	}

	if mode == "remove" && len(list) == 0 {
		perms.del(key)
		if len(perms.keys) == 0 {
			root.del("permissions")
		} else {
			root.set("permissions", perms.marshal())
		}
	} else {
		perms.set(key, rawList(list))
		root.set("permissions", perms.marshal())
	}
	var out bytes.Buffer
	if err := json.Indent(&out, root.marshal(), "", "  "); err != nil {
		return "", err
	}
	out.WriteByte('\n')
	if err := writeFileAtomic(path, out.Bytes(), perm); err != nil {
		return "", err
	}
	return "ok", nil
}

// rawList joins items into a JSON array as written: json.Marshal would rewrite & < > inside them as \u0026….
func rawList(items []json.RawMessage) json.RawMessage {
	var b bytes.Buffer
	b.WriteByte('[')
	for i, item := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(item)
	}
	b.WriteByte(']')
	return b.Bytes()
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// writeFileAtomic writes data beside path and renames it over path, so a crash never leaves half a file.
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(name, perm)
	}
	if werr == nil {
		werr = os.Rename(name, path)
	}
	if werr != nil {
		os.Remove(name)
	}
	return werr
}

// skillCheckCLI is the command-line Skill Eval check (it was the Python tools/skill-check): the same checks
// the board's /api/skill-eval/check runs, printed as {"skill", "checks"}. Exit 0 = no fail, 1 = a fail,
// 2 = bad usage, not a folder, or a folder inside canon (canon's own skills are checked internally).
func skillCheckCLI(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprintln(stderr, "skill-check — free, deterministic checks on a skill folder (no model calls).\n\nUsage: sprint-check skill-check <skill-dir>")
		return 2
	}
	p, err := filepath.Abs(args[0])
	if err == nil {
		p, err = filepath.EvalSymlinks(p)
	}
	if st, serr := os.Stat(p); err != nil || serr != nil || !st.IsDir() {
		fmt.Fprintf(stderr, "skill-check: %s is not a directory\n", args[0])
		return 2
	}
	canon := cliCanonRoot()
	if canon == "" || samePath(p, canon) || strictlyInside(p, canon) {
		fmt.Fprintln(stderr, "skill-check: refusing a path inside the canon repo — its skills are checked internally")
		return 2
	}
	checks := append(skillStage1(p), skillStage2(p)...)
	enc := json.NewEncoder(stdout)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	enc.Encode(struct {
		Skill  string          `json:"skill"`
		Checks []skillCheckRow `json:"checks"`
	}{filepath.Base(p), checks})
	for _, c := range checks {
		if c.Status == "fail" {
			return 1
		}
	}
	return 0
}

// cliCanonRoot finds canon's root without a running board: beside the binary (tools/sprint-check-bin/ or
// tools/), else the project the current directory is in. "" (refuse) when neither is canon.
func cliCanonRoot() string {
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		if filepath.Base(dir) == "sprint-check-bin" {
			dir = filepath.Dir(dir)
		}
		candidates = append(candidates, filepath.Dir(dir))
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates, findProjectRoot(wd))
	}
	for _, c := range candidates {
		if isCanonRoot(c) {
			return resolvedOrAbs(c)
		}
	}
	return ""
}

// isCanonRoot: canon's own checkout or install, marked by tools/src-key.sh (t-8020's release-key owner).
func isCanonRoot(dir string) bool { return isRegularFile(filepath.Join(dir, "tools", "src-key.sh")) }

// emitEventCLI is the shell tools' event writer: `event <kind> --project <dir> --source <name> key=value...`. A bad
// argument is noted in events/emit-errors.log like any other failure; nothing is printed.
func emitEventCLI(args []string) {
	home := events.Home()
	if len(args) == 0 {
		events.Emit(home, "", "", "", nil) // notes the missing kind
		return
	}
	kind, project, source := args[0], "", ""
	data := map[string]string{}
	for i := 1; i < len(args); i++ {
		switch a := args[i]; {
		case (a == "--project" || a == "--source") && i+1 < len(args):
			if a == "--project" {
				project = args[i+1]
			} else {
				source = args[i+1]
			}
			i++
		case strings.Contains(a, "="):
			k, v, _ := strings.Cut(a, "=")
			data[k] = v
		default:
			data[a] = "" // an argument that is not key=value is an unknown field: refused by the schema
		}
	}
	events.Emit(home, kind, source, project, data)
}
