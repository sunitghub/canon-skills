// Package artifact is the schema for a ticket's artifacts (t-c2de): strict on the lines canon parses, never on prose.
// Each rule has a stable id so a reader, a pipeline node (t-6a4d produces:) or a person can name it. Slice 1 only
// reports: the shell readers keep their own matches until each t-63ac port reads this package instead.
package artifact

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Rule is one strict line shape: Allowed is printed beside every finding, so a writer sees the fix.
type Rule struct {
	ID, File, Allowed string
}

// Finding is one line that breaks a rule. Line 1 also stands for "missing from the file".
type Finding struct {
	Path    string
	Line    int
	Rule    string
	Problem string
	Allowed string
}

func (f Finding) String() string {
	return fmt.Sprintf("%s:%d: %s: %s; allowed: %s", f.Path, f.Line, f.Rule, f.Problem, f.Allowed)
}

// Files are the artifacts the schema knows, in the order a ticket folder is checked.
var Files = []string{"ticket.md", "acceptance.md", "plan.md", "eval-report.md", "review-notes.md", "spec-review.md"}

// MaxSize caps one artifact: a ticket file is a few KB, so anything near this is not one.
const MaxSize = 4 << 20

// Rules is the schema. The shapes follow the close path's readers (tools/sprint) with the user's 2026-11-24 picks:
// Tier case-insensitive with `*` stripped, a duplicate frontmatter key an error, `status` read from frontmatter only.
var Rules = []Rule{
	{"ticket.frontmatter", "ticket.md", "a first line `---` and a closing `---` line"},
	{"ticket.key-duplicate", "ticket.md", "each frontmatter key once"},
	{"ticket.field-shape", "ticket.md", "`<key>: <value>` with one space after the colon"},
	{"ticket.id", "ticket.md", "`id: t-xxxx`, equal to the ticket's folder name"},
	{"ticket.status", "ticket.md", "`status:` open, in_progress, closed, cancelled or archived"},
	{"ticket.type", "ticket.md", "`type:` bug, feature, task, chore, epic or docs"},
	{"ticket.priority", "ticket.md", "`priority:` an integer 0-4"},
	{"ticket.flag", "ticket.md", "`manual`, `demo`, `eval_override`, `ci`: true or false"},
	{"ticket.eval-fail-count", "ticket.md", "`eval_fail_count:` a non-negative integer"},
	{"acceptance.section", "acceptance.md", "`## Criteria`, `## Test Plan` and `## QA`, once each"},
	{"acceptance.box", "acceptance.md", "`- [ ] <text>`, `- [x] <text>` or `- [X] <text>` (`*` bullets and indent allowed)"},
	{"acceptance.wrapup-row", "acceptance.md", "`| <gate> | ran or skipped | <reason, not empty, - or —> |`"},
	{"plan.signoff", "plan.md", "one `## Sign-off` section"},
	{"plan.tier", "plan.md", "one `Tier: trivial|bugfix|normal|high-risk` line in `## Sign-off` (case-insensitive, `*` ignored)"},
	{"plan.approval-box", "plan.md", "exactly one `- [ ] Plan approved` or `- [x] Plan approved` line"},
	{"plan.approved-stamp", "plan.md", "`Approved: sha256:<64 hex> <YYYY-MM-DDThh:mm:ssZ>`"},
	{"plan.pipeline-stamp", "plan.md", "`Pipeline: sha256:<hex> …`"},
	{"eval.run-id", "eval-report.md", "exactly one `evaluator-run-id: <digits>-<digits>`"},
	{"eval.model", "eval-report.md", "at least one `Model: <model>` line"},
	{"eval.graded-head", "eval-report.md", "one `graded-head: <40-64 lowercase hex>` value"},
	{"eval.verdict", "eval-report.md", "exactly one line starting `pass:`, `fail:`, `partial:` or `not-run:` and a reason"},
	{"review.verdict", "review-notes.md", "a `## Verdict` heading whose first word is YES or NO"},
	{"spec.verdict", "spec-review.md", "a `## Verdict` heading whose first word is READY or GAPS (not the template's `READY | GAPS`)"},
}

var ruleByID = func() map[string]Rule {
	m := make(map[string]Rule, len(Rules))
	for _, r := range Rules {
		m[r.ID] = r
	}
	return m
}()

// ErrNotArtifact is returned for a file whose base name is not one of Files.
var ErrNotArtifact = errors.New("not a ticket artifact (want ticket.md, acceptance.md, plan.md, eval-report.md, review-notes.md or spec-review.md)")

// Validate checks a ticket folder (each of Files that exists) or one artifact file. The error is for a path that cannot
// be read as an artifact (missing, a link, not a regular file, too large); a missing file inside a folder is not checked.
func Validate(path string) ([]Finding, int, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, 0, err
	}
	if fi.IsDir() {
		var all []Finding
		n := 0
		for _, name := range Files {
			p := filepath.Join(path, name)
			if _, err := os.Lstat(p); errors.Is(err, os.ErrNotExist) {
				continue
			}
			fs, err := validateFile(p, name, folderName(path))
			if err != nil {
				return nil, n, err
			}
			all = append(all, fs...)
			n++
		}
		return all, n, nil
	}
	name := filepath.Base(path)
	if !knownFile(name) {
		return nil, 0, fmt.Errorf("%s: %w", path, ErrNotArtifact)
	}
	fs, err := validateFile(path, name, folderName(filepath.Dir(path)))
	if err != nil {
		return nil, 0, err
	}
	return fs, 1, nil
}

// folderName is the base name of dir made absolute, so `validate .` inside a ticket folder still names it.
func folderName(dir string) string {
	if abs, err := filepath.Abs(dir); err == nil {
		dir = abs
	}
	return filepath.Base(dir)
}

func knownFile(name string) bool {
	for _, f := range Files {
		if f == name {
			return true
		}
	}
	return false
}

func validateFile(path, name, folder string) ([]Finding, error) {
	data, err := read(path)
	if err != nil {
		return nil, err
	}
	fs := Check(name, data, folder)
	for i := range fs {
		fs[i].Path = path
	}
	return fs, nil
}

// ReadLines returns an artifact's lines as the checkers see them (BOM dropped, CRLF read as LF), with read's limits.
func ReadLines(path string) ([]string, error) {
	data, err := read(path)
	if err != nil {
		return nil, err
	}
	return lines(data), nil
}

// read returns an artifact's bytes: a regular file under MaxSize, never a link.
func read(path string) ([]byte, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: not a regular file (a link or special file is never followed)", path)
	}
	if fi.Size() > MaxSize {
		return nil, fmt.Errorf("%s: %d bytes is over the %d-byte artifact cap", path, fi.Size(), MaxSize)
	}
	return os.ReadFile(path) // #nosec G304 -- read-only; the caller names the path and it was checked to be a regular file
}

// Check validates one artifact's bytes by its file name. folder is the ticket folder's name for the id rule ("" skips it).
func Check(name string, data []byte, folder string) []Finding {
	ls := lines(data)
	c := &checker{}
	switch name {
	case "ticket.md":
		c.ticket(ls, folder)
	case "acceptance.md":
		c.acceptance(ls)
	case "plan.md":
		c.plan(ls)
	case "eval-report.md":
		c.evalReport(ls)
	case "review-notes.md":
		c.verdict(ls, "review.verdict", "YES", "NO")
	case "spec-review.md":
		c.verdict(ls, "spec.verdict", "READY", "GAPS")
	}
	return c.out
}

type checker struct{ out []Finding }

func (c *checker) add(line int, id, problem string) {
	c.out = append(c.out, Finding{Line: line, Rule: id, Problem: problem, Allowed: ruleByID[id].Allowed})
}

// lines splits the file with a BOM dropped and CRLF read as LF, as the shell readers strip `\r`.
func lines(data []byte) []string {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	s := strings.ReplaceAll(string(data), "\r\n", "\n")
	return strings.Split(s, "\n")
}

// quote shows a line in a finding: trimmed, control characters replaced, at most 60 characters.
func quote(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return '?'
		}
		return r
	}, strings.TrimSpace(s))
	if r := []rune(s); len(r) > 60 {
		s = string(r[:60]) + "…"
	}
	return "`" + s + "`"
}

// ---- ticket.md

var (
	keyRe      = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*):(.*)$`)
	idRe       = regexp.MustCompile(`^t-[0-9a-z]{4}$`)
	priorityRe = regexp.MustCompile(`^[0-4]$`)
	countRe    = regexp.MustCompile(`^[0-9]+$`)
)

var enums = map[string]struct {
	rule   string
	values []string
}{
	"status":        {"ticket.status", []string{"open", "in_progress", "closed", "cancelled", "archived"}},
	"type":          {"ticket.type", []string{"bug", "feature", "task", "chore", "epic", "docs"}},
	"manual":        {"ticket.flag", []string{"true", "false"}},
	"demo":          {"ticket.flag", []string{"true", "false"}},
	"eval_override": {"ticket.flag", []string{"true", "false"}},
	"ci":            {"ticket.flag", []string{"true", "false"}},
}

// strictKeys are the frontmatter keys whose value form is checked; any other key is free.
var strictKeys = map[string]bool{"id": true, "status": true, "type": true, "priority": true, "manual": true, "demo": true,
	"eval_override": true, "ci": true, "eval_fail_count": true}

// Field is one frontmatter key with its line number (1-based) and raw value (text after the colon, untrimmed).
type Field struct {
	Key, Raw string
	Line     int
}

// Frontmatter returns the frontmatter block's key lines and the line of its closing `---` (0 when the block is
// missing or not closed). Lines that are not `key:` (list items, blanks) are skipped, never an error.
func Frontmatter(ls []string) ([]Field, int) {
	if len(ls) == 0 || ls[0] != "---" {
		return nil, 0
	}
	var fs []Field
	for i := 1; i < len(ls); i++ {
		if ls[i] == "---" {
			return fs, i + 1
		}
		if m := keyRe.FindStringSubmatch(ls[i]); m != nil {
			fs = append(fs, Field{Key: m[1], Raw: m[2], Line: i + 1})
		}
	}
	return nil, 0
}

func (c *checker) ticket(ls []string, folder string) {
	if len(ls) == 0 || ls[0] != "---" {
		c.add(1, "ticket.frontmatter", "the first line is "+quote(first(ls))+", not `---`")
		return
	}
	fs, end := Frontmatter(ls)
	if end == 0 {
		c.add(1, "ticket.frontmatter", "the `---` block is not closed")
		return
	}
	seen := map[string]int{}
	for _, f := range fs {
		if prev, ok := seen[f.Key]; ok {
			c.add(f.Line, "ticket.key-duplicate", fmt.Sprintf("`%s` also on line %d", f.Key, prev))
			continue
		}
		seen[f.Key] = f.Line
		if !strictKeys[f.Key] {
			continue
		}
		v := strings.Trim(f.Raw, " \t") // ASCII blanks only: a trailing NBSP or U+2028 is invisible but breaks the shell readers' exact compare
		if !strings.HasPrefix(f.Raw, " ") || strings.HasPrefix(f.Raw, "  ") || v == "" {
			c.add(f.Line, "ticket.field-shape", quote(f.Key+":"+f.Raw))
			continue
		}
		switch f.Key {
		case "id":
			if !idRe.MatchString(v) {
				c.add(f.Line, "ticket.id", quote(v))
			} else if folder != "" && v != folder {
				c.add(f.Line, "ticket.id", fmt.Sprintf("`%s` in folder `%s`", v, folder))
			}
		case "priority":
			if !priorityRe.MatchString(v) {
				c.add(f.Line, "ticket.priority", quote(v))
			}
		case "eval_fail_count":
			if !countRe.MatchString(v) {
				c.add(f.Line, "ticket.eval-fail-count", quote(v))
			}
		default:
			e := enums[f.Key]
			if !oneOf(v, e.values) {
				c.add(f.Line, e.rule, fmt.Sprintf("`%s` is %s", f.Key, quote(v)))
			}
		}
	}
	for _, k := range []string{"id", "status", "type", "priority"} {
		if _, ok := seen[k]; !ok {
			c.add(1, "ticket."+k, "no `"+k+":` key")
		}
	}
}

func first(ls []string) string {
	if len(ls) == 0 {
		return ""
	}
	return ls[0]
}

func oneOf(v string, vs []string) bool {
	for _, x := range vs {
		if v == x {
			return true
		}
	}
	return false
}

// ---- sections (acceptance.md, plan.md, review-notes.md)

var headingRe = regexp.MustCompile(`^##[ \t]+(.*?)[ \t]*$`)

// section is the body of one `## Name` heading: index of the heading line and the line indexes under it, with lines
// inside a ``` or ~~~ fence left out (a quoted example is prose).
type section struct {
	name    string
	heading int
	body    []int
}

func sections(ls []string) []section {
	var out []section
	for _, i := range unfenced(ls) {
		if m := headingRe.FindStringSubmatch(ls[i]); m != nil {
			out = append(out, section{name: m[1], heading: i})
			continue
		}
		if len(out) > 0 {
			out[len(out)-1].body = append(out[len(out)-1].body, i)
		}
	}
	return out
}

func named(ss []section, name string) []section {
	var out []section
	for _, s := range ss {
		if s.name == name {
			out = append(out, s)
		}
	}
	return out
}

// requireOnce reports a section that is missing (line 1) or repeated (at each later heading).
func (c *checker) requireOnce(ss []section, name, rule string) {
	got := named(ss, name)
	if len(got) == 0 {
		c.add(1, rule, "no `## "+name+"` heading")
	}
	for _, s := range got[min(1, len(got)):] {
		c.add(s.heading+1, rule, fmt.Sprintf("`## %s` again (first on line %d)", name, got[0].heading+1))
	}
}

// ---- acceptance.md

var (
	boxStartRe = regexp.MustCompile(`^[ \t]*[-*] \[`)
	boxRe      = regexp.MustCompile(`^[ \t]*[-*] \[[ xX]\][ \t]+\S`)
)

func (c *checker) acceptance(ls []string) {
	ss := sections(ls)
	for _, n := range []string{"Criteria", "Test Plan", "QA"} {
		c.requireOnce(ss, n, "acceptance.section")
	}
	for _, s := range ss {
		switch s.name {
		case "Criteria", "Test Plan", "QA":
			for _, i := range s.body {
				if !boxStartRe.MatchString(ls[i]) {
					continue
				}
				if !boxRe.MatchString(ls[i]) {
					c.add(i+1, "acceptance.box", quote(ls[i]))
				}
			}
		case "Wrapup Gates":
			for _, i := range s.body {
				c.wrapupRow(ls[i], i+1)
			}
		}
	}
}

var rowStartRe = regexp.MustCompile(`^\|[ \t]*[A-Za-z]`)

// cells splits a table row on `|`, leaving an escaped `\|` inside its cell.
func cells(row string) []string {
	row = strings.TrimSpace(row)
	row = strings.TrimPrefix(row, "|")
	row = strings.TrimSuffix(row, "|")
	var out []string
	var b strings.Builder
	for i := 0; i < len(row); i++ {
		if row[i] == '\\' && i+1 < len(row) && row[i+1] == '|' {
			b.WriteString(`\|`)
			i++
			continue
		}
		if row[i] == '|' {
			out = append(out, strings.TrimSpace(b.String()))
			b.Reset()
			continue
		}
		b.WriteByte(row[i])
	}
	return append(out, strings.TrimSpace(b.String()))
}

func (c *checker) wrapupRow(l string, n int) {
	if !rowStartRe.MatchString(l) {
		return
	}
	cs := cells(l)
	if strings.EqualFold(cs[0], "gate") {
		return
	}
	if len(cs) < 3 {
		c.add(n, "acceptance.wrapup-row", fmt.Sprintf("%d cells", len(cs)))
		return
	}
	if cs[1] != "ran" && cs[1] != "skipped" {
		c.add(n, "acceptance.wrapup-row", fmt.Sprintf("`%s` status %s", cs[0], quote(cs[1])))
	}
	if r := cs[2]; r == "" || r == "-" || r == "—" {
		c.add(n, "acceptance.wrapup-row", fmt.Sprintf("`%s` has no reason", cs[0]))
	}
}

// ---- plan.md

var (
	tierLineRe = regexp.MustCompile(`^[ \t]*tier[ \t]*:`)
	tierRe     = regexp.MustCompile(`^[ \t]*tier[ \t]*:[ \t]*(trivial|bugfix|normal|high-risk)([^a-z0-9-]|$)`)
	approvalRe = regexp.MustCompile(`^[ \t]*[-*] \[[^\]]*\][ \t]*Plan approved`)
	approvalOK = regexp.MustCompile(`^[ \t]*[-*] \[[ xX]\] Plan approved`)
	approvedRe = regexp.MustCompile(`^[ \t]*Approved:`)
	approvedOK = regexp.MustCompile(`^[ \t]*Approved: sha256:[0-9a-f]{64} [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z[ \t]*$`)
	pipelineRe = regexp.MustCompile(`^[ \t]*Pipeline:`)
	pipelineOK = regexp.MustCompile(`^[ \t]*Pipeline: sha256:[0-9a-f]+([ \t]|$)`)
)

func (c *checker) plan(ls []string) {
	ss := sections(ls)
	c.requireOnce(ss, "Sign-off", "plan.signoff")
	var boxes []int
	for _, s := range ss {
		for _, i := range s.body {
			if approvalRe.MatchString(ls[i]) {
				boxes = append(boxes, i)
			}
		}
	}
	switch {
	case len(boxes) == 0:
		c.add(1, "plan.approval-box", "no `Plan approved` box")
	case len(boxes) > 1:
		c.add(boxes[1]+1, "plan.approval-box", fmt.Sprintf("a second `Plan approved` box (first on line %d)", boxes[0]+1))
	}
	for _, i := range boxes {
		if !approvalOK.MatchString(ls[i]) {
			c.add(i+1, "plan.approval-box", quote(ls[i]))
		}
	}
	signoff := named(ss, "Sign-off")
	if len(signoff) == 0 {
		return
	}
	tiers := 0
	for _, i := range signoff[0].body {
		l := strings.ToLower(strings.ReplaceAll(ls[i], "*", ""))
		if tierLineRe.MatchString(l) {
			if tiers++; tiers > 1 {
				c.add(i+1, "plan.tier", "a second `Tier:` line")
			} else if !tierRe.MatchString(l) {
				c.add(i+1, "plan.tier", quote(ls[i]))
			}
		}
		if approvedRe.MatchString(ls[i]) && !approvedOK.MatchString(ls[i]) {
			c.add(i+1, "plan.approved-stamp", quote(ls[i]))
		}
		if pipelineRe.MatchString(ls[i]) && !pipelineOK.MatchString(ls[i]) {
			c.add(i+1, "plan.pipeline-stamp", quote(ls[i]))
		}
	}
}

// ---- eval-report.md

var (
	runIDLineRe = regexp.MustCompile(`^evaluator-run-id:`)
	runIDRe     = regexp.MustCompile(`^evaluator-run-id:[ \t]+[0-9]+-[0-9]+[ \t]*$`)
	modelLineRe = regexp.MustCompile(`^Model:`)
	modelRe     = regexp.MustCompile(`^Model:[ \t]+\S`)
	headLineRe  = regexp.MustCompile(`^graded-head:[ \t]*(.*?)[ \t]*$`)
	headRe      = regexp.MustCompile(`^[0-9a-f]{40,64}$`)
	verdictRe   = regexp.MustCompile(`^(pass|fail|partial|not-run):`)
	verdictOK   = regexp.MustCompile(`^(pass|fail|partial|not-run):[ \t]+\S`)
)

// unfenced is every line index outside a ``` or ~~~ fence: a quoted example or log is prose, never a strict line.
func unfenced(ls []string) []int {
	var out []int
	fence := ""
	for i, l := range ls {
		t := strings.TrimLeft(l, " \t")
		if fence != "" {
			if strings.HasPrefix(t, fence) {
				fence = ""
			}
			continue
		}
		if strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~") {
			fence = t[:3]
			continue
		}
		out = append(out, i)
	}
	return out
}

func (c *checker) evalReport(ls []string) {
	var runIDs, verdicts []int
	models := 0
	heads := map[string]int{}
	var headOrder []string
	for _, i := range unfenced(ls) {
		l := ls[i]
		switch {
		case runIDLineRe.MatchString(l):
			runIDs = append(runIDs, i)
			if !runIDRe.MatchString(l) {
				c.add(i+1, "eval.run-id", quote(l))
			}
		case modelLineRe.MatchString(l):
			if modelRe.MatchString(l) {
				models++
			} else {
				c.add(i+1, "eval.model", "an empty `Model:` line")
			}
		case verdictRe.MatchString(l):
			verdicts = append(verdicts, i)
			if !verdictOK.MatchString(l) {
				c.add(i+1, "eval.verdict", quote(l)+" has no reason")
			}
		default:
			if m := headLineRe.FindStringSubmatch(l); m != nil {
				if _, ok := heads[m[1]]; !ok {
					heads[m[1]] = i
					headOrder = append(headOrder, m[1])
				}
				if !headRe.MatchString(m[1]) {
					c.add(i+1, "eval.graded-head", quote(m[1])+" is not a full commit hash")
				}
			}
		}
	}
	switch {
	case len(runIDs) == 0:
		c.add(1, "eval.run-id", "no `evaluator-run-id:` line")
	case len(runIDs) > 1:
		c.add(runIDs[1]+1, "eval.run-id", fmt.Sprintf("a second `evaluator-run-id:` (first on line %d)", runIDs[0]+1))
	}
	if models == 0 && !hasEmptyModel(c.out) {
		c.add(1, "eval.model", "no `Model:` line")
	}
	switch {
	case len(headOrder) == 0:
		c.add(1, "eval.graded-head", "no `graded-head:` line")
	case len(headOrder) > 1:
		c.add(heads[headOrder[1]]+1, "eval.graded-head", fmt.Sprintf("a second value (first on line %d)", heads[headOrder[0]]+1))
	}
	switch {
	case len(verdicts) == 0:
		c.add(1, "eval.verdict", "no verdict line")
	case len(verdicts) > 1:
		c.add(verdicts[1]+1, "eval.verdict", fmt.Sprintf("a second verdict line (first on line %d)", verdicts[0]+1))
	}
}

func hasEmptyModel(fs []Finding) bool {
	for _, f := range fs {
		if f.Rule == "eval.model" {
			return true
		}
	}
	return false
}

// ---- review-notes.md, spec-review.md

var verdictHeadingRe = regexp.MustCompile(`^##[ \t]+Verdict`)

// verdict checks the first non-blank line under the first `## Verdict`: its first word (`*` ignored) is one of words,
// and it is not the protocol's unfilled template (`READY | GAPS — …`, a `|` as the second word).
func (c *checker) verdict(ls []string, rule string, words ...string) {
	idx := unfenced(ls)
	for k, i := range idx {
		if !verdictHeadingRe.MatchString(ls[i]) {
			continue
		}
		for _, j := range idx[k+1:] {
			w := strings.Fields(strings.ReplaceAll(ls[j], "*", ""))
			if len(w) == 0 {
				continue
			}
			if headingRe.MatchString(ls[j]) {
				break // an empty section: the next heading is not its verdict
			}
			if !oneOf(strings.ToUpper(w[0]), words) || (len(w) > 1 && w[1] == "|") {
				c.add(j+1, rule, quote(ls[j]))
			}
			return
		}
		c.add(i+1, rule, "nothing under `## Verdict`")
		return
	}
	c.add(1, rule, "no `## Verdict` heading")
}

// ---- produces (t-2bfe): a pipeline node's postcondition names one of these rules

// present says a rule's line exists. A rule whose checker already reports its absence (a verdict) needs none here.
var present = map[string]func(ls []string) bool{
	"spec.verdict": func([]string) bool { return true },
	"plan.approved-stamp": func(ls []string) bool {
		for _, s := range named(sections(ls), "Sign-off") {
			for _, i := range s.body {
				if approvedOK.MatchString(ls[i]) {
					return true
				}
			}
		}
		return false
	},
}

// Produces reports whether id names a rule a pipeline node's `produces:` may name.
func Produces(id string) bool { _, ok := present[id]; return ok }

// Holds reports whether ticket folder dir holds rule id's line, well-formed: false for a missing file. The error is for a
// rule no node may name or a file that cannot be read as an artifact (a link, over the cap), never read as "holds".
func Holds(dir, id string) (bool, error) {
	has, ok := present[id]
	if !ok {
		return false, fmt.Errorf("%s: not a rule a pipeline node may produce", id)
	}
	r := ruleByID[id]
	data, err := read(filepath.Join(dir, r.File))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	ls := lines(data)
	for _, f := range Check(r.File, data, "") {
		if f.Rule == id {
			return false, nil
		}
	}
	return has(ls), nil
}
