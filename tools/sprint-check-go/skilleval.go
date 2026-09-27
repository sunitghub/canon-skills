package main

// t-b9a7: Skill Eval in the Go board (what Windows runs) — a port of tools/skill-check,
// tools/plugin-eval-gen --skill-dir and server.py's Skill Eval run/state/report, so the feature
// needs no Python, bash or jq. Same logic in two runtimes: tests/skill-eval-parity.sh compares
// /check output byte-for-byte and the generated plugin tree with diff -r. Where Python's text
// handling differs from Go's (str.isspace, \w, len() in code points, errors="replace" decoding,
// the unicode_escape codec), the helpers below reproduce Python's behavior.

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	skillEvalDefaultModel = "claude-haiku-4-5-20251001"
	skillJSONMaxDepth     = 64        // same as tools/skill-check MAX_DEPTH
	skillJSONMaxNumberLen = 100       // same as MAX_NUMBER_LEN
	skillSafeInt          = 1<<53 - 1 // same as SAFE_INT
	skillEvalRunTimeout   = 30 * time.Minute
	skillEvalWalkCap      = 20000
)

var (
	skillNameRe      = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	skillCaseIDRe    = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	skillKeyRe       = regexp.MustCompile(`^(?:([A-Za-z_][\p{L}\p{N}_-]*)|"([^"]+)"|'([^']+)')[ \t]*:[ \t]*(.*)$`)
	skillHooksLineRe = regexp.MustCompile(`(?m)^["']?hooks["']?[ \t]*:`)
	skillInjectRe    = regexp.MustCompile("(?m)!`|^```!")
	skillHex4Re      = regexp.MustCompile(`^[0-9a-fA-F]{4}$`)
	skillLowSurrRe   = regexp.MustCompile(`^[dD][c-fC-F][0-9a-fA-F]{2}$`)
	pyFloatStrRe     = regexp.MustCompile(`^[+-]?(\d+(_\d+)*)?(\.(\d+(_\d+)*)?)?([eE][+-]?\d+(_\d+)*)?$`)
	skillBools       = map[string]bool{"true": true, "false": true, "yes": true, "no": true, "on": true, "off": true, "1": true, "0": true}
	skillEfforts     = map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}
	skillSideEffects = []struct {
		word    string
		bounded bool
	}{{"git push", false}, {"git commit", false}, {"gh pr ", false}, {"rm -rf", false}, {"deploy", true}, {"publish", true}}
)

const skillEvalsFix = `Create evals/evals.json: {"skill_name": "<name>", "evals": [{"id", "case_type", "prompt", "expected_output", "expectations": [...]}]} with at least 3 cases (e.g. control, compliance, edge). Ask Claude to draft realistic prompts and assertable expectations from SKILL.md, then review them.`

// ── Python-compatible text helpers ─────────────────────────────────────────

func pyIsSpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }
func pyIsWord(r rune) bool  { return r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r) }
func pyStrip(s string) string {
	return strings.TrimFunc(s, pyIsSpace)
}
func pyRStrip(s string) string { return strings.TrimRightFunc(s, pyIsSpace) }
func runeLen(s string) int     { return utf8.RuneCountInString(s) }
func runePrefix(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		r = r[:n]
	}
	return string(r)
}

// pyDecodeReplace decodes like bytes.decode("utf-8", errors="replace"): one U+FFFD per maximal
// invalid subpart (Go's range loop would emit one per byte).
func pyDecodeReplace(b []byte) string {
	var sb strings.Builder
	for i := 0; i < len(b); {
		c := b[i]
		if c < 0x80 {
			sb.WriteByte(c)
			i++
			continue
		}
		need, lower, upper, cp := 0, byte(0x80), byte(0xBF), rune(0)
		switch {
		case c >= 0xC2 && c <= 0xDF:
			need, cp = 1, rune(c&0x1F)
		case c >= 0xE0 && c <= 0xEF:
			need, cp = 2, rune(c&0x0F)
			if c == 0xE0 {
				lower = 0xA0
			} else if c == 0xED {
				upper = 0x9F
			}
		case c >= 0xF0 && c <= 0xF4:
			need, cp = 3, rune(c&0x07)
			if c == 0xF0 {
				lower = 0x90
			} else if c == 0xF4 {
				upper = 0x8F
			}
		default:
			sb.WriteRune(utf8.RuneError)
			i++
			continue
		}
		j, seen := i+1, 0
		for seen < need && j < len(b) && b[j] >= lower && b[j] <= upper {
			cp = cp<<6 | rune(b[j]&0x3F)
			lower, upper = 0x80, 0xBF
			j++
			seen++
		}
		if seen == need {
			sb.WriteRune(cp)
		} else {
			sb.WriteRune(utf8.RuneError)
		}
		i = j
	}
	return sb.String()
}

// pyTextMode applies Python's universal-newline translation (text-mode read_text).
func pyTextMode(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
}

// pyJSONString is json.dumps(s, ensure_ascii=False) for a str — Go's encoder differs on
// U+2028/U+2029, \b/\f and invalid UTF-8.
func pyJSONString(s string) string {
	var sb strings.Builder
	sb.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString(`\"`)
		case '\\':
			sb.WriteString(`\\`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		case '\b':
			sb.WriteString(`\b`)
		case '\f':
			sb.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&sb, `\u%04x`, r)
			} else {
				sb.WriteRune(r)
			}
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

func pyJSONStrings(items []string) string {
	parts := make([]string, len(items))
	for i, s := range items {
		parts[i] = pyJSONString(s)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func pyJSONInts(items []int) string {
	parts := make([]string, len(items))
	for i, n := range items {
		parts[i] = strconv.Itoa(n)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// pyUnescapeKey mirrors skill-check's unescape_key: encode latin-1 with backslashreplace, then
// decode with the unicode_escape codec; any decode error keeps the key as written. A \N{name}
// escape is never decoded (stage 2 treats such a key as possibly "hooks").
func pyUnescapeKey(k string) string {
	if strings.Contains(k, `\N`) {
		return k
	}
	var raw []byte
	for _, r := range k {
		switch {
		case r <= 0xFF:
			raw = append(raw, byte(r))
		case r <= 0xFFFF:
			raw = append(raw, fmt.Sprintf(`\u%04x`, r)...)
		default:
			raw = append(raw, fmt.Sprintf(`\U%08x`, r)...)
		}
	}
	hexVal := func(s []byte) (int64, bool) {
		for _, c := range s {
			if !strings.ContainsRune("0123456789abcdefABCDEF", rune(c)) {
				return 0, false
			}
		}
		v, err := strconv.ParseInt(string(s), 16, 64)
		return v, err == nil
	}
	var out []rune
	for i := 0; i < len(raw); {
		c := raw[i]
		if c != '\\' {
			out = append(out, rune(c)) // latin-1
			i++
			continue
		}
		if i+1 >= len(raw) {
			return k // "\ at end of string"
		}
		e := raw[i+1]
		switch e {
		case '\n':
			i += 2
		case '\\', '\'', '"':
			out = append(out, rune(e))
			i += 2
		case 'a', 'b', 'f', 'n', 'r', 't', 'v':
			out = append(out, rune(map[byte]byte{'a': 7, 'b': 8, 'f': 12, 'n': 10, 'r': 13, 't': 9, 'v': 11}[e]))
			i += 2
		case '0', '1', '2', '3', '4', '5', '6', '7':
			j, v := i+1, 0
			for j < len(raw) && j < i+4 && raw[j] >= '0' && raw[j] <= '7' {
				v = v*8 + int(raw[j]-'0')
				j++
			}
			out = append(out, rune(v))
			i = j
		case 'x', 'u', 'U':
			n := map[byte]int{'x': 2, 'u': 4, 'U': 8}[e]
			if i+2+n > len(raw) {
				return k
			}
			v, ok := hexVal(raw[i+2 : i+2+n])
			if !ok || v > 0x10FFFF {
				return k
			}
			out = append(out, rune(v))
			i += 2 + n
		default:
			out = append(out, '\\', rune(e)) // unknown escape: kept as written
			i += 2
		}
	}
	return string(out)
}

// skillStrictJSONError mirrors skill-check's strict_json_error (same rules, same order).
func skillStrictJSONError(text string) string {
	depth := 0
	for i, n := 0, len(text); i < n; {
		ch := text[i]
		if ch == '"' {
			i++
			for i < n && text[i] != '"' {
				if text[i] == '\\' && i+1 < n {
					if text[i+1] == 'u' && i+5 < n && skillHex4Re.MatchString(text[i+2:i+6]) {
						cp, _ := strconv.ParseInt(text[i+2:i+6], 16, 32)
						if cp == 0 {
							return `a \u0000 escape`
						}
						if cp >= 0xD800 && cp <= 0xDBFF {
							if !(i+12 <= n && text[i+6:i+8] == `\u` && skillLowSurrRe.MatchString(text[i+8:i+12])) {
								return "a lone surrogate escape"
							}
							i += 12
							continue
						}
						if cp >= 0xDC00 && cp <= 0xDFFF {
							return "a lone surrogate escape"
						}
						i += 6
						continue
					}
					i += 2
					continue
				}
				i++
			}
			i++
			continue
		}
		switch {
		case ch == '[' || ch == '{':
			depth++
			if depth > skillJSONMaxDepth {
				return fmt.Sprintf("nesting deeper than %d", skillJSONMaxDepth)
			}
		case ch == ']' || ch == '}':
			depth--
		case ch == '-' || (ch >= '0' && ch <= '9'):
			j := i
			for j < n && strings.IndexByte("+-0123456789.eE", text[j]) >= 0 {
				j++
			}
			if j-i > skillJSONMaxNumberLen {
				return fmt.Sprintf("a number longer than %d characters", skillJSONMaxNumberLen)
			}
			i = j
			continue
		}
		i++
	}
	return ""
}

func skillLoadJSONStrict(text string) (any, error) {
	if why := skillStrictJSONError(text); why != "" {
		return nil, errors.New(why)
	}
	dec := json.NewDecoder(strings.NewReader(text))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if strings.TrimLeft(text[dec.InputOffset():], " \t\n\r") != "" {
		return nil, errors.New("extra data") // json.loads refuses trailing content
	}
	return v, nil
}

// jsonIntText: the canonical decimal of an integer JSON literal (Python's str(int)), or "" for
// a non-integer literal (Python parses those as float).
func jsonIntText(n json.Number) string {
	s := string(n)
	if strings.ContainsAny(s, ".eE") {
		return ""
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok {
		return ""
	}
	return v.String()
}

// ── Checks (tools/skill-check) ──────────────────────────────────────────────

type skillCheckRow struct {
	ID       string `json:"id"`
	Stage    int    `json:"stage"`
	Status   string `json:"status"`
	Evidence string `json:"evidence"`
	Fix      string `json:"fix"`
}

func skillRow(id string, stage int, status, evidence, fix string) skillCheckRow {
	return skillCheckRow{id, stage, status, evidence, fix}
}

func pick(cond bool, a, b string) string {
	if cond {
		return a
	}
	return b
}

func isRegularFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

func skillStage1(dir string) []skillCheckRow {
	path := filepath.Join(dir, "evals", "evals.json")
	if !isRegularFile(path) {
		return []skillCheckRow{skillRow("evals-present", 1, "fail", path+" not found", skillEvalsFix)}
	}
	b, err := os.ReadFile(path)
	var data any
	if err == nil && utf8.Valid(b) {
		data, err = skillLoadJSONStrict(pyTextMode(string(b)))
	} else if err == nil {
		err = errors.New("not UTF-8")
	}
	if err != nil {
		return []skillCheckRow{skillRow("evals-present", 1, "fail", path+" is not valid JSON", skillEvalsFix)}
	}
	obj, _ := data.(map[string]any)
	cases, ok := obj["evals"].([]any)
	if obj == nil || !ok {
		return []skillCheckRow{skillRow("evals-present", 1, "fail", path+` has no "evals" list`, skillEvalsFix)}
	}
	out := []skillCheckRow{skillRow("evals-present", 1, "pass", fmt.Sprintf("%d case(s) in evals/evals.json", len(cases)), "")}
	out = append(out, skillRow("evals-count", 1, pick(len(cases) >= 3, "pass", "warn"),
		fmt.Sprintf("%d case(s); minimum is 3", len(cases)),
		pick(len(cases) >= 3, "", "Add cases until you cover the happy path, a must-follow rule, and an edge.")))

	ids := make([]*string, len(cases))
	for i, c := range cases {
		m, _ := c.(map[string]any)
		switch v := m["id"].(type) {
		case string:
			ids[i] = &v
		case json.Number:
			if t := jsonIntText(v); t != "" {
				if bi, _ := new(big.Int).SetString(t, 10); bi.CmpAbs(big.NewInt(skillSafeInt)) <= 0 {
					ids[i] = &t
				}
			}
		}
	}
	var badIDs []int
	counts := map[string]int{}
	for i, v := range ids {
		if v == nil || !skillCaseIDRe.MatchString(*v) {
			badIDs = append(badIDs, i)
		}
		if v != nil {
			counts[*v]++
		}
	}
	var dupes []string
	for v, n := range counts {
		if n > 1 {
			dupes = append(dupes, v)
		}
	}
	sort.Strings(dupes)
	if len(badIDs) > 0 {
		out = append(out, skillRow("evals-ids", 1, "fail",
			fmt.Sprintf("case(s) at position %s have no usable id (letters, digits, _ and - only)", pyJSONInts(badIDs[:min(5, len(badIDs))])),
			"Give every case a short id such as 1 or \"compliance-2\"; ids become directory names when the eval is generated."))
	} else {
		out = append(out, skillRow("evals-ids", 1, pick(len(dupes) > 0, "warn", "pass"),
			pick(len(dupes) > 0, "duplicate ids: "+pyJSONStrings(dupes[:min(5, len(dupes))]), "every case has a unique, path-safe id"),
			pick(len(dupes) > 0, "Duplicate ids overwrite each other's generated case; make them unique.", "")))
	}

	var bad []string
	for i, c := range cases {
		if !skillCaseOK(c) {
			label := strconv.Itoa(i)
			if ids[i] != nil && *ids[i] != "" {
				label = *ids[i]
			}
			bad = append(bad, runePrefix(label, 40))
		}
	}
	out = append(out, skillRow("evals-shape", 1, pick(len(bad) > 0, "warn", "pass"),
		pick(len(bad) > 0, "cases without a text prompt and a list of text expectations: "+strings.Join(bad, ", "), "every case has a prompt and expectations"),
		pick(len(bad) > 0, "Give each case a concrete user prompt (text) and 2-3 assertable expectations (a list of text).", "")))

	typeSet := map[string]bool{}
	for _, c := range cases {
		if m, ok := c.(map[string]any); ok {
			typeSet[skillCaseType(m["case_type"])] = true
		}
	}
	types := make([]string, 0, len(typeSet))
	for t := range typeSet {
		types = append(types, t)
	}
	sort.Strings(types)
	varied := len(types) > 1 || len(cases) < 2
	out = append(out, skillRow("evals-variety", 1, pick(varied, "pass", "warn"), "case_type values: "+pyJSONStrings(types),
		pick(varied, "", "Mix case types (control, compliance, boundary, edge) so the eval is not one scenario repeated.")))
	return out
}

func skillCaseOK(c any) bool {
	m, ok := c.(map[string]any)
	if !ok {
		return false
	}
	p, ok := m["prompt"].(string)
	if !ok || pyStrip(p) == "" {
		return false
	}
	exps, ok := m["expectations"].([]any)
	if !ok || len(exps) == 0 {
		return false
	}
	for _, e := range exps {
		s, ok := e.(string)
		if !ok || pyStrip(s) == "" {
			return false
		}
	}
	return true
}

func skillCaseType(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case nil:
		return "<null>"
	case bool:
		return "<boolean>"
	case json.Number:
		return "<number>"
	case []any:
		return "<array>"
	default:
		return "<object>"
	}
}

// skillParseFrontmatter mirrors skill-check's parse_frontmatter.
func skillParseFrontmatter(text string) (map[string]string, []string, string, string) {
	if !strings.HasPrefix(text, "---\n") {
		return nil, nil, text, "first line is not '---'"
	}
	start, end := -1, -1
	for p := 3; p+4 <= len(text); p++ {
		if text[p:p+4] != "\n---" {
			continue
		}
		k := p + 4
		for k < len(text) && (text[k] == ' ' || text[k] == '\t') {
			k++
		}
		if k == len(text) {
			start, end = p, k
			break
		}
		if text[k] == '\n' {
			start, end = p, k+1
			break
		}
	}
	if start < 0 {
		return nil, nil, text, "no closing '---'"
	}
	fields := map[string]string{}
	var order []string
	last, have := "", false
	for _, line := range strings.Split(text[4:max(4, start)], "\n") {
		if m := skillKeyRe.FindStringSubmatch(line); m != nil {
			switch {
			case m[1] != "":
				last = m[1]
			case m[2] != "":
				last = pyUnescapeKey(m[2])
			default:
				last = m[3]
			}
			have = true
			if _, seen := fields[last]; !seen {
				order = append(order, last)
			}
			fields[last] = strings.Trim(pyStrip(m[4]), `'"`)
		} else if have && (strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") || strings.HasPrefix(line, "-")) {
			fields[last] = pyStrip(fields[last] + " " + pyStrip(line))
		}
	}
	return fields, order, text[end:], ""
}

func skillHiddenHooks(text string) bool {
	lines := strings.Split(text, "\n")
	if len(lines) > 80 {
		lines = lines[:80]
	}
	var fences []int
	for i, l := range lines {
		if pyRStrip(l) == "---" {
			fences = append(fences, i)
		}
	}
	if len(fences) < 3 {
		return false
	}
	return skillHooksLineRe.MatchString(strings.Join(lines[fences[1]+1:fences[len(fences)-1]], "\n"))
}

func runesFoldEqual(a []rune, b string) bool {
	br := []rune(b)
	if len(a) < len(br) {
		return false
	}
	for i, r := range br {
		if a[i] == r {
			continue
		}
		f := unicode.SimpleFold(r)
		for f != r && f != a[i] {
			f = unicode.SimpleFold(f)
		}
		if f != a[i] {
			return false
		}
	}
	return true
}

// skillSideEffect mirrors SIDE_EFFECT.search on the whitespace-collapsed body: leftmost
// position, alternatives in order, Python's Unicode \b for deploy/publish.
func skillSideEffect(body string) string {
	var collapsed []rune
	inSpace := false
	for _, r := range body {
		if pyIsSpace(r) {
			if !inSpace {
				collapsed = append(collapsed, ' ')
			}
			inSpace = true
			continue
		}
		inSpace = false
		collapsed = append(collapsed, r)
	}
	for p := range collapsed {
		for _, alt := range skillSideEffects {
			n := runeLen(alt.word)
			if !runesFoldEqual(collapsed[p:], alt.word) {
				continue
			}
			if alt.bounded {
				if p > 0 && pyIsWord(collapsed[p-1]) {
					continue
				}
				if p+n < len(collapsed) && pyIsWord(collapsed[p+n]) {
					continue
				}
			}
			return string(collapsed[p : p+n])
		}
	}
	return ""
}

func skillStage2(dir string) []skillCheckRow {
	md := filepath.Join(dir, "SKILL.md")
	if !isRegularFile(md) {
		return []skillCheckRow{skillRow("skill-md-present", 2, "fail", md+" not found", "Add a SKILL.md with YAML frontmatter.")}
	}
	out := []skillCheckRow{skillRow("skill-md-present", 2, "pass", "SKILL.md found", "")}
	b, err := os.ReadFile(md)
	if err != nil {
		return []skillCheckRow{skillRow("skill-md-present", 2, "fail", md+" is not readable", "Fix the file permissions on SKILL.md.")}
	}
	text := pyTextMode(pyDecodeReplace(b))
	bom := strings.HasPrefix(text, "\ufeff")
	if bom {
		text = strings.TrimPrefix(text, "\ufeff")
	}
	fm, keys, body, perr := skillParseFrontmatter(text)
	if perr != "" {
		return append(out, skillRow("frontmatter", 2, "fail", "frontmatter unreadable: "+perr,
			"SKILL.md must start with a '---' line and close the block with '---'; otherwise the whole file is treated as content."))
	}
	out = append(out, skillRow("frontmatter", 2, "pass", "frontmatter block is well-formed", ""))
	out = append(out, skillRow("bom", 2, pick(bom, "warn", "pass"),
		pick(bom, "SKILL.md starts with a UTF-8 byte-order mark", "no byte-order mark"),
		pick(bom, "Save SKILL.md as UTF-8 without BOM; some readers only accept frontmatter that starts with '---'.", "")))

	var bad []string
	for _, k := range []string{"disable-model-invocation", "user-invocable", "background"} {
		if v, ok := fm[k]; ok && !skillBools[strings.ToLower(v)] {
			bad = append(bad, k+"="+pyJSONString(v))
		}
	}
	if v, ok := fm["effort"]; ok && !skillEfforts[strings.ToLower(v)] {
		bad = append(bad, "effort="+pyJSONString(v))
	}
	if v, ok := fm["context"]; ok && strings.ToLower(v) != "fork" {
		bad = append(bad, "context="+pyJSONString(v))
	}
	if v, ok := fm["shell"]; ok && strings.ToLower(v) != "bash" && strings.ToLower(v) != "powershell" {
		bad = append(bad, "shell="+pyJSONString(v))
	}
	out = append(out, skillRow("field-values", 2, pick(len(bad) > 0, "fail", "pass"),
		pick(len(bad) > 0, "invalid: "+strings.Join(bad, ", "), "boolean and enum fields are valid"),
		pick(len(bad) > 0, "Booleans take true/false/yes/no/on/off/1/0; effort is low|medium|high|xhigh|max; context is fork; shell is bash|powershell.", "")))

	desc := fm["description"]
	out = append(out, skillRow("description-present", 2, pick(desc != "", "pass", "warn"),
		pick(desc != "", "description set", "no description; the first non-empty body line is used instead"),
		pick(desc != "", "", "Add a description that states what the skill does and when to use it — Claude reads it to decide when to load the skill.")))
	combined := runeLen(desc) + runeLen(fm["when_to_use"])
	out = append(out, skillRow("description-length", 2, pick(combined <= 1536, "pass", "warn"),
		fmt.Sprintf("description + when_to_use = %d chars (limit 1536)", combined),
		pick(combined <= 1536, "", "Text past 1,536 characters is truncated. Put the key use case and trigger phrases first.")))
	lines := 0
	if pyStrip(body) != "" {
		lines = len(strings.Split(strings.Trim(body, "\n"), "\n"))
	}
	out = append(out, skillRow("body-length", 2, pick(lines < 500, "pass", "warn"),
		fmt.Sprintf("body is %d lines (guidance: under 500)", lines),
		pick(lines < 500, "", "Move detailed reference into supporting files the skill loads when needed.")))
	comp := runeLen(fm["compatibility"])
	out = append(out, skillRow("compatibility-length", 2, pick(comp <= 500, "pass", "warn"),
		fmt.Sprintf("compatibility is %d chars (limit 500)", comp),
		pick(comp <= 500, "", "Shorten the compatibility field to 500 characters or fewer.")))
	tokens := runeLen(text) / 4
	out = append(out, skillRow("compaction-size", 2, pick(tokens <= 5000, "pass", "warn"),
		fmt.Sprintf("about %d tokens (only the first 5,000 survive compaction)", tokens),
		pick(tokens <= 5000, "", "Trim SKILL.md or move detail to supporting files so the essentials fit in the first 5,000 tokens.")))
	guard := strings.ToLower(fm["disable-model-invocation"])
	guarded := guard == "true" || guard == "yes" || guard == "on" || guard == "1"
	side := skillSideEffect(body)
	flag := side != "" && !guarded
	out = append(out, skillRow("side-effects-guarded", 2, pick(flag, "warn", "pass"),
		pick(flag, "body mentions "+pyJSONString(pyStrip(side))+" and Claude may auto-invoke the skill", "no unguarded side-effect wording found (heuristic)"),
		pick(flag, "Set disable-model-invocation: true for workflows that push, commit, deploy or delete, so they run only when you invoke them.", "")))
	hidden := skillHiddenHooks(text)
	_, hooks := fm["hooks"]
	undecoded := false
	for _, k := range keys {
		if strings.Contains(k, `\N`) {
			undecoded = true
		}
	}
	hasHooks := hooks || hidden || undecoded
	out = append(out, skillRow("trust-hooks", 2, pick(hasHooks, "warn", "pass"),
		pick(hasHooks, "frontmatter registers hooks, which run outside a sandbox", "no hooks in frontmatter"),
		pick(hasHooks, "Review the hook commands before running an eval; an automated run should refuse this skill.", "")))
	out = append(out, skillRow("frontmatter-fences", 2, pick(hidden, "warn", "pass"),
		pick(hidden, "a hooks key follows the first closing '---', so readers may disagree about the frontmatter", "one frontmatter block"),
		pick(hidden, "Keep '---' out of the frontmatter values and close the block once.", "")))
	inj := skillInjectRe.MatchString(body)
	out = append(out, skillRow("trust-shell-injection", 2, pick(inj, "warn", "pass"),
		pick(inj, "body has !`command` or ```! blocks, which run before the skill is sent", "no shell-injection blocks"),
		pick(inj, "Review those commands; a failing one aborts the whole invocation.", "")))
	return out
}

// ── Server side (server.py's Skill Eval section) ───────────────────────────

var (
	skillEvalMu sync.Mutex
	// skillEvalStateMu serializes the read-modify-write of .reports/skillEvalRuns.json: two runs
	// finishing together would otherwise interleave their writes and corrupt the file.
	skillEvalStateMu sync.Mutex
	skillEvalRuns    = map[string]map[string]any{}
)

// skillEvalNow is Python's time.time(): seconds as a float. Tests point runs at a stub claude
// through SKILL_EVAL_CLAUDE_BIN, which runSkillEval reads on every run.
func skillEvalNow() float64 { return float64(time.Now().UnixNano()) / 1e9 }

// canonRootDir: canon's repo root, from the resolved app.html (…/tools/sprint-check-app/app.html),
// so a binary built elsewhere (tests, tools/sprint-check-win.exe) finds the same root as server.py.
// "" when that directory isn't canon — callers then refuse (fail closed), since the "inside
// canon" refusal and the eval cache both depend on it.
func canonRootDir() string {
	root := resolvedOrAbs(filepath.Dir(filepath.Dir(filepath.Dir(appHTML))))
	if !isRegularFile(filepath.Join(root, "tools", "skill-check")) {
		return ""
	}
	return root
}

// samePath compares two resolved absolute paths; Windows paths are case-insensitive.
func samePath(a, b string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

func resolvedOrAbs(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	a, _ := filepath.Abs(p)
	return a
}

// strictlyInside: p is a descendant of root by path components (case-insensitive on Windows via
// filepath.Rel), never a string-prefix test.
func strictlyInside(p, root string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil || rel == "." || rel == ".." || filepath.IsAbs(rel) {
		return false
	}
	return !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func expandUser(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		if h, err := os.UserHomeDir(); err == nil {
			return filepath.Join(h, p[1:])
		}
	}
	return p
}

// plainMode: a regular file or a plain directory. Since Go 1.23, Windows junctions and mount points
// report ModeIrregular (possibly together with ModeDir) instead of ModeSymlink, and EvalSymlinks no
// longer follows them — so a directory bit alone never proves an entry is safe to trust.
func plainMode(m fs.FileMode) bool {
	if m&(fs.ModeSymlink|fs.ModeIrregular) != 0 {
		return false
	}
	return m.IsRegular() || m.IsDir()
}

// plainDirsBetween: every path component from root (exclusive) down to p (inclusive) is a plain
// directory — a junction anywhere on the way would point the checks at another folder.
func plainDirsBetween(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return false
	}
	cur := root
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		cur = filepath.Join(cur, part)
		st, err := os.Lstat(cur)
		if err != nil || !st.IsDir() || !plainMode(st.Mode()) {
			return false
		}
	}
	return true
}

// validateSkillDir mirrors server.py's validate_skill_dir. It is stricter in one way on purpose:
// any entry that is neither a regular file nor a directory refuses the folder — Windows junctions
// and mount points report ModeIrregular (not ModeSymlink) since Go 1.23.
func validateSkillDir(root, raw string) (string, string) {
	abs, err := filepath.Abs(expandUser(raw))
	if err != nil {
		return "", "skill folder not found"
	}
	p, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", "skill folder not found"
	}
	st, err := os.Stat(p)
	if err != nil {
		return "", "skill folder not found"
	}
	if !st.IsDir() {
		return "", "not a folder"
	}
	proot := resolvedOrAbs(root)
	if !strictlyInside(p, proot) || !plainDirsBetween(proot, p) {
		return "", "skill folder must be inside the selected project"
	}
	canon := canonRootDir()
	if canon == "" || samePath(p, canon) || strictlyInside(p, canon) {
		return "", "canon's own skills are checked internally, not here"
	}
	if !skillNameRe.MatchString(filepath.Base(p)) {
		return "", "folder name must match [a-z0-9][a-z0-9-]*"
	}
	seen, bad := 0, false
	_ = filepath.WalkDir(p, func(path string, d fs.DirEntry, err error) error {
		if path == p {
			return nil
		}
		if err != nil {
			return nil // unreadable entries are skipped, as os.walk does
		}
		seen++
		if seen > skillEvalWalkCap || !plainMode(d.Type()) {
			bad = true
			return filepath.SkipAll
		}
		return nil
	})
	if bad {
		return "", "skill folder contains a symbolic link (or is too large); remove it and retry"
	}
	return p, ""
}

func skillEvalCheck(root, raw string) map[string]any {
	p, errMsg := validateSkillDir(root, raw)
	if errMsg != "" {
		return map[string]any{"ok": false, "error": errMsg}
	}
	checks := append(skillStage1(p), skillStage2(p)...)
	return map[string]any{"ok": true, "skill_dir": p, "skill": filepath.Base(p), "checks": checks}
}

func skillEvalBlocker(checks []skillCheckRow, allowTrust bool) string {
	var fails, trust []string
	for _, c := range checks {
		if c.Status == "fail" {
			fails = append(fails, c.ID)
		}
		if strings.HasPrefix(c.ID, "trust-") && c.Status == "warn" {
			trust = append(trust, c.ID)
		}
	}
	if len(fails) > 0 {
		return "fix failing check(s) first: " + strings.Join(fails, ", ")
	}
	if len(trust) > 0 && !allowTrust {
		return "skill runs code outside the sandbox (" + strings.Join(trust, ", ") + "); review it and pass allow_trust to run anyway"
	}
	return ""
}

func skillEvalKey(root, skillDir string) string { return resolvedOrAbs(root) + "\x00" + skillDir }
func skillEvalTag(root, skillDir string) string {
	sum := sha1.Sum([]byte(resolvedOrAbs(root) + "|" + skillDir))
	return hex.EncodeToString(sum[:])[:12]
}
func skillEvalStatePath(root string) string {
	return filepath.Join(root, ".reports", "skillEvalRuns.json")
}

func skillEvalStateLoad(root string) map[string]any {
	b, err := os.ReadFile(skillEvalStatePath(root))
	if err != nil {
		return map[string]any{}
	}
	var d map[string]any
	if json.Unmarshal(b, &d) != nil || d == nil {
		return map[string]any{}
	}
	return d
}

func skillEvalStateSave(root, key string, entry map[string]any) {
	dir := filepath.Dir(skillEvalStatePath(root))
	if st, err := os.Lstat(dir); err == nil {
		if !st.IsDir() || !plainMode(st.Mode()) || !samePath(filepath.Dir(resolvedOrAbs(dir)), resolvedOrAbs(root)) {
			return // a project-controlled .reports link must not redirect this write outside the project
		}
	}
	if os.MkdirAll(dir, 0o755) != nil {
		return
	}
	skillEvalStateMu.Lock()
	defer skillEvalStateMu.Unlock()
	state := skillEvalStateLoad(root)
	state[key] = entry
	if b, err := json.MarshalIndent(state, "", "  "); err == nil {
		_ = os.WriteFile(skillEvalStatePath(root), b, 0o644)
	}
}

func skillEvalSummary(resultPath string) map[string]any {
	b, err := os.ReadFile(resultPath)
	if err != nil {
		return map[string]any{}
	}
	var d map[string]any
	if json.Unmarshal(b, &d) != nil || d == nil {
		return map[string]any{}
	}
	keep := map[string]any{}
	if agg, ok := d["aggregates"].(map[string]any); ok {
		for _, k := range []string{"casesTotal", "casesPassed", "overallScore", "meanDelta"} {
			if v, ok := agg[k]; ok {
				keep[k] = v
			}
		}
	}
	for _, k := range []string{"costUsd", "partial", "partialReason"} {
		if v, ok := d[k]; ok {
			keep[k] = v
		}
	}
	mean := func(arm any) any {
		items, _ := arm.([]any)
		sum, n := 0.0, 0
		for _, it := range items {
			m, ok := it.(map[string]any)
			if !ok {
				continue
			}
			switch s := m["score"].(type) {
			case float64:
				sum, n = sum+s, n+1
			case bool: // Python's isinstance(True, int)
				if s {
					sum++
				}
				n++
			}
		}
		if n == 0 {
			return nil
		}
		return sum / float64(n)
	}
	cases := []any{}
	list, _ := d["cases"].([]any)
	for _, c := range list {
		m, ok := c.(map[string]any)
		if !ok {
			continue
		}
		arms, isMap := m["arms"].(map[string]any)
		if m["arms"] != nil && !isMap && pyTruthy(m["arms"]) {
			continue
		}
		name := m["name"]
		if !pyTruthy(name) {
			name = m["id"]
		}
		cases = append(cases, map[string]any{"name": name, "with": mean(arms["with"]), "without": mean(arms["without"])})
	}
	keep["cases"] = cases
	return keep
}

func pyTruthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case float64:
		return t != 0
	case string:
		return t != ""
	case []any:
		return len(t) > 0
	case map[string]any:
		return len(t) > 0
	}
	return true
}

// pyStr is Python's str() of a JSON value from the request body (server.py passes str(...)).
func pyStr(v any) string {
	switch t := v.(type) {
	case nil:
		return "None"
	case string:
		return t
	case bool:
		return pick(t, "True", "False")
	case float64:
		return pyFloatRepr(t, true)
	case []any:
		parts := make([]string, len(t))
		for i, x := range t {
			parts[i] = pyRepr(x)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = pyRepr(k) + ": " + pyRepr(t[k])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return fmt.Sprint(v)
}

func pyRepr(v any) string {
	if s, ok := v.(string); ok {
		return "'" + s + "'"
	}
	return pyStr(v)
}

// pyFloatRepr: Python's repr(float); intLike prints an integral value as JSON ints parse (3, not 3.0).
func pyFloatRepr(f float64, intLike bool) string {
	switch {
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	case math.IsNaN(f):
		return "nan"
	}
	if intLike && f == math.Trunc(f) && math.Abs(f) < 1e16 {
		return strconv.FormatFloat(f, 'f', 0, 64)
	}
	e := strconv.FormatFloat(f, 'e', -1, 64)
	mant, exp, _ := strings.Cut(e, "e")
	x, _ := strconv.Atoi(exp)
	if x < -4 || x >= 16 {
		sign := "+"
		if x < 0 {
			sign, x = "-", -x
		}
		return fmt.Sprintf("%se%s%02d", mant, sign, x)
	}
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.ContainsAny(s, ".") {
		s += ".0"
	}
	return s
}

// pyFloat is Python's float(x) for the request's max_cost_usd; ok=false where float() raises.
func pyFloat(v any) (float64, bool) {
	switch t := v.(type) {
	case float64:
		return t, true
	case bool:
		if t {
			return 1, true
		}
		return 0, true
	case string:
		s := strings.ToLower(pyStrip(t))
		sign := 1.0
		body := s
		if strings.HasPrefix(body, "+") || strings.HasPrefix(body, "-") {
			if body[0] == '-' {
				sign = -1
			}
			body = body[1:]
		}
		switch body {
		case "inf", "infinity":
			return sign * math.Inf(1), true
		case "nan":
			return math.NaN(), true
		}
		if !pyFloatStrRe.MatchString(s) || !strings.ContainsAny(s, "0123456789") {
			return 0, false
		}
		f, err := strconv.ParseFloat(strings.ReplaceAll(s, "_", ""), 64)
		if err != nil && !errors.Is(err, strconv.ErrRange) {
			return 0, false
		}
		return f, true
	}
	return 0, false
}

func skillEvalMaxCost(v any) float64 {
	c, ok := pyFloat(v)
	if !ok || math.IsNaN(c) || math.IsInf(c, 0) {
		c = 3.0 // NaN passes min/max clamps and would leave the cap unenforced
	}
	return math.Min(math.Max(c, 0.5), 10.0)
}

func startSkillEvalRun(root string, payload map[string]any) map[string]any {
	fail := func(msg string) map[string]any { return map[string]any{"ok": false, "error": msg} }
	if payload["confirm_cost"] != true {
		return fail("confirm_cost required: this run spends model usage")
	}
	model := ""
	if v, ok := payload["model"]; ok {
		model = pyStr(v)
	}
	if model != "" && !upkeepModelRe.MatchString(model) {
		return fail("model must be a plain model id (letters, digits, . _ : [ ] -)")
	}
	rawDir := ""
	if v, ok := payload["skill_dir"]; ok {
		rawDir = pyStr(v)
	}
	chk := skillEvalCheck(root, rawDir)
	if chk["ok"] != true {
		return chk
	}
	if blocker := skillEvalBlocker(chk["checks"].([]skillCheckRow), payload["allow_trust"] == true); blocker != "" {
		return fail(blocker)
	}
	maxCost := 3.0
	if v, ok := payload["max_cost_usd"]; ok {
		maxCost = skillEvalMaxCost(v)
	}
	if model == "" {
		model = skillEvalDefaultModel
	}
	skillDir := chk["skill_dir"].(string)
	key := skillEvalKey(root, skillDir)
	skillEvalMu.Lock()
	if skillEvalRuns[key] != nil && skillEvalRuns[key]["status"] == "running" {
		skillEvalMu.Unlock()
		return map[string]any{"ok": false, "busy": true, "status": "running"}
	}
	skillEvalRuns[key] = map[string]any{"status": "running", "output": "", "summary": map[string]any{}, "report_path": "", "started_at": skillEvalNow()}
	skillEvalMu.Unlock()
	go runSkillEval(root, skillDir, model, maxCost)
	return map[string]any{"ok": true, "status": "running", "max_cost_usd": maxCost}
}

func runSkillEval(root, skillDir, model string, maxCost float64) {
	key := skillEvalKey(root, skillDir)
	plugin := filepath.Join(canonRootDir(), ".canon-cache", "skill-eval", skillEvalTag(root, skillDir))
	resultPath := filepath.Join(plugin, "last-run.json")
	output, status, reportPath := "", "error", ""
	if n, err := pluginEvalGen(skillDir, plugin); err != nil {
		output = "plugin-eval-gen: " + err.Error() + "\n"
	} else {
		output = fmt.Sprintf("plugin-eval-gen: wrote %d case(s) for %s\n", n, filepath.Base(skillDir))
		_ = os.Remove(resultPath)
		_ = os.RemoveAll(filepath.Join(plugin, "evals", "results")) // a previous run's report must not be served for this one
		bin := os.Getenv("SKILL_EVAL_CLAUDE_BIN")
		if bin == "" {
			bin = "claude"
		}
		ctx, cancel := context.WithTimeout(context.Background(), skillEvalRunTimeout)
		// No --allow-tools / --allow-real-servers: read-only tools, no real MCP servers.
		cmd := exec.CommandContext(ctx, bin, "plugin", "eval", plugin, "--trust-plugin", "--runs", "2",
			"--max-cost-usd", pyFloatRepr(maxCost, false), "--model", model, "--no-publish", "--json", resultPath)
		cmd.Dir = plugin
		out, err := cmd.CombinedOutput()
		cancel()
		output += string(out)
		code := 0
		if err != nil {
			var ee *exec.ExitError
			if errors.As(err, &ee) && ctx.Err() == nil {
				code = ee.ExitCode()
			} else {
				code = -1
				output += "\nError: " + err.Error()
			}
		}
		reports, _ := filepath.Glob(filepath.Join(plugin, "evals", "results", "*", "report.html"))
		sort.Strings(reports)
		if len(reports) > 0 {
			reportPath = reports[len(reports)-1]
		}
		if (code == 0 || code == 1) && isRegularFile(resultPath) {
			status = "done"
		}
	}
	summary := map[string]any{}
	if status == "done" {
		summary = skillEvalSummary(resultPath)
	}
	finished := skillEvalNow()
	skillEvalMu.Lock()
	st := skillEvalRuns[key]
	if st == nil {
		st = map[string]any{}
		skillEvalRuns[key] = st
	}
	for k, v := range map[string]any{"status": status, "output": output, "summary": summary, "report_path": reportPath, "finished_at": finished} {
		st[k] = v
	}
	skillEvalMu.Unlock()
	tail := output
	if len(tail) > 2048 {
		tail = tail[len(tail)-2048:]
	}
	skillEvalStateSave(root, skillDir, map[string]any{"status": status, "summary": summary, "report_path": reportPath,
		"finished_at": finished, "model": model, "output": tail})
}

func getSkillEvalState(root, raw string) map[string]any {
	p, errMsg := validateSkillDir(root, raw)
	if errMsg != "" {
		return map[string]any{"ok": false, "error": errMsg}
	}
	copyWithout := func(src map[string]any) map[string]any {
		out := map[string]any{"ok": true}
		for k, v := range src {
			if k != "output" {
				out[k] = v
			}
		}
		return out
	}
	skillEvalMu.Lock()
	live := skillEvalRuns[skillEvalKey(root, p)]
	if live != nil {
		res := copyWithout(live)
		skillEvalMu.Unlock()
		return res
	}
	skillEvalMu.Unlock()
	if persisted, ok := skillEvalStateLoad(root)[p].(map[string]any); ok && len(persisted) > 0 {
		return copyWithout(persisted)
	}
	return map[string]any{"ok": true, "status": "never"}
}

func getSkillEvalReport(root, raw string) map[string]any {
	st := getSkillEvalState(root, raw)
	if st["ok"] != true {
		return st
	}
	report, _ := st["report_path"].(string)
	if report == "" {
		return map[string]any{"ok": false, "error": "no report yet"}
	}
	p, _ := validateSkillDir(root, raw)
	cache := resolvedOrAbs(filepath.Join(canonRootDir(), ".canon-cache", "skill-eval", skillEvalTag(root, p)))
	if !strictlyInside(resolvedOrAbs(report), cache) {
		return map[string]any{"ok": false, "error": "report path outside this run's cache dir"}
	}
	summary := st["summary"]
	if summary == nil {
		summary = map[string]any{}
	}
	return map[string]any{"ok": true, "summary": summary, "report_path": report}
}

// ── Plugin generation (tools/plugin-eval-gen --skill-dir) ──────────────────

const skillEvalPromptHead = "---\nmax_turns: 10\nallowed_tools: [Read, Glob, Grep, Skill]\n---\n\n"
const skillEvalCriteriaHead = "---\ntype: llm\n---\n\nIgnore any mention of a failed or skipped memory save.\n\nPASS if the response satisfies all of:\n"

var skillMemoryRe = regexp.MustCompile(`(?i)memory`)

// pluginEvalGen writes the same tree as `plugin-eval-gen --skill-dir <skillDir> --plugin-dir <plugin>`
// (defaults: no --write, no --keep-memory). Every case is validated before anything is written.
func pluginEvalGen(skillDir, plugin string) (int, error) {
	skill := filepath.Base(skillDir)
	if !skillNameRe.MatchString(skill) {
		return 0, errors.New("skill name must match [a-z0-9][a-z0-9-]*")
	}
	b, err := os.ReadFile(filepath.Join(skillDir, "evals", "evals.json"))
	if err != nil || !utf8.Valid(b) {
		return 0, errors.New("evals/evals.json not readable")
	}
	data, err := skillLoadJSONStrict(pyTextMode(string(b)))
	obj, _ := data.(map[string]any)
	cases, ok := obj["evals"].([]any)
	if err != nil || !ok {
		return 0, errors.New(`evals/evals.json has no "evals" list`)
	}
	type genCase struct {
		id, prompt, ctype string
		exps              []string
	}
	var gc []genCase
	for i, c := range cases {
		m, _ := c.(map[string]any)
		var id string
		switch v := m["id"].(type) {
		case string:
			id = v
		case json.Number:
			id = jsonIntText(v)
		default:
			return 0, fmt.Errorf("case %d has no usable id (a string or number is required)", i)
		}
		if !skillCaseIDRe.MatchString(id) {
			return 0, fmt.Errorf("case %d has an unsafe id (letters, digits, _ and - only)", i)
		}
		prompt, pok := m["prompt"].(string)
		list, lok := m["expectations"].([]any)
		exps := make([]string, 0, len(list))
		for _, e := range list {
			s, ok := e.(string)
			if !ok {
				lok = false
				break
			}
			exps = append(exps, s)
		}
		if !pok || !lok {
			return 0, fmt.Errorf("case %d needs a text prompt and a list of text expectations", i)
		}
		ctype, _ := m["case_type"].(string)
		gc = append(gc, genCase{id, prompt, ctype, exps})
	}

	if err := os.MkdirAll(filepath.Join(plugin, ".claude-plugin"), 0o755); err != nil {
		return 0, err
	}
	_ = os.MkdirAll(filepath.Join(plugin, "evals"), 0o755)
	if err := os.WriteFile(filepath.Join(plugin, ".claude-plugin", "plugin.json"),
		[]byte(`{"name":"canon-eval","version":"0.0.0","description":"generated by tools/plugin-eval-gen"}`+"\n"), 0o644); err != nil {
		return 0, err
	}
	dst := filepath.Join(plugin, "skills", skill)
	_ = os.RemoveAll(dst)
	if old, _ := filepath.Glob(filepath.Join(plugin, "evals", skill+"-*")); len(old) > 0 {
		for _, o := range old {
			_ = os.RemoveAll(o)
		}
	}
	if err := copySkillTree(skillDir, dst); err != nil {
		return 0, err
	}
	_ = os.RemoveAll(filepath.Join(dst, "evals"))

	prefix := regexp.MustCompile(`^/` + regexp.QuoteMeta(skill) + ` +`)
	for _, c := range gc {
		dir := filepath.Join(plugin, "evals", skill+"-"+c.id)
		if err := os.MkdirAll(filepath.Join(dir, "graders"), 0o755); err != nil {
			return 0, err
		}
		prompt := prefix.ReplaceAllLiteralString(c.prompt, "Use the "+skill+" skill: ")
		prompt = strings.TrimRight(prompt, "\n") // bash $(...) strips trailing newlines
		if err := os.WriteFile(filepath.Join(dir, "prompt.md"), []byte(skillEvalPromptHead+prompt+"\n"), 0o644); err != nil {
			return 0, err
		}
		var rubric []string
		for _, e := range c.exps {
			if !skillMemoryRe.MatchString(e) {
				rubric = append(rubric, "- "+e)
			}
		}
		criteria := skillEvalCriteriaHead + strings.TrimRight(strings.Join(rubric, "\n"), "\n") + "\nFAIL otherwise.\n"
		if err := os.WriteFile(filepath.Join(dir, "graders", "criteria.md"), []byte(criteria), 0o644); err != nil {
			return 0, err
		}
		fired := filepath.Join(dir, "graders", "skill-fired.md")
		_ = os.Remove(fired)
		switch c.ctype {
		case "boundary", "over-caution", "self-check":
		default:
			body := "---\ntype: tool_used\ntool: Skill\ninput_match: '\"skill\"\\s*:\\s*\"(?:[\\w-]+:)?" + skill + "\"'\n---\n"
			if err := os.WriteFile(fired, []byte(body), 0o644); err != nil {
				return 0, err
			}
		}
	}
	return len(gc), nil
}

// copySkillTree copies regular files and directories (cp -R, then `find -type l -delete`).
func copySkillTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		target := filepath.Join(dst, rel)
		info, ierr := d.Info()
		if ierr != nil {
			return ierr
		}
		switch {
		case d.IsDir():
			return os.MkdirAll(target, info.Mode().Perm()|0o700)
		case info.Mode().IsRegular():
			b, rerr := os.ReadFile(path)
			if rerr != nil {
				return rerr
			}
			return os.WriteFile(target, b, info.Mode().Perm())
		}
		return nil // links and other non-regular entries are dropped
	})
}
