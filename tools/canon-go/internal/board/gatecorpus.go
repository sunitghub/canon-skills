package board

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// canon-go gate-corpus (t-a05d stage 1): what the closed tickets' gate reports say, counted from their FIXED shapes only. The reviewer's triage
// buckets (Act On, Consider, Noted, Dismissed) and its concern labels (the current seven and the five before t-0ca2) are line prefixes; the model and the date are header lines; the
// evaluator's verdict and its criteria table are a heading and pipe rows. A concern read out of a free-text finding is a judgement, so it is not
// attempted here (the analysts' labels live in the ticket's local corpus file). Read-only, local, no model call. Every file is untrusted: nothing a
// file says is printed except a count under a fixed word (a model is one of opus, sonnet, haiku, other, unknown; a month is digits; a label is one of
// the five template labels).

const gcoMaxFile = 256 << 10

var (
	gcoBucketRe  = regexp.MustCompile(`^(Act On|Consider|Noted|Dismissed):[ \t]*(.*)$`)
	gcoConcernRe = regexp.MustCompile(`^[-*]?[ \t]*(Correctness|Guards that cannot fail|Security and trust boundaries|Error handling|Portability|Hygiene|Scope creep|Visual regression|Dead code|Unnecessary complexity|Standards violations)[^:]{0,30}:[ \t]*(.*)$`)
	gcoNoneRe    = regexp.MustCompile(`(?i)^none([^a-z0-9_]|$)`)
	gcoMonthRe   = regexp.MustCompile(`^(Reviewed|Evaluated):[ \t]*([0-9]{4}-[0-9]{2})`)
	gcoModelRe   = regexp.MustCompile(`^Model:[ \t]*(.*)$`)
	gcoVerdictRe = regexp.MustCompile(`^(pass|fail|partial|not-run):`)
	gcoIDRe      = regexp.MustCompile(`^t-[a-z0-9]+$`)
	gcoHeadVerRe = regexp.MustCompile(`^## Verdict:?[ \t]*(pass|fail|partial|not-run)\b`)
	gcoRevVerRe  = regexp.MustCompile(`^(?:## )?Verdict:[ \t]*\**(YES|NO)\**[ \t.]*$`)
)

// gcoMonth keeps a month key to a real year and month, so a forged date cannot make a new row for every file.
func gcoMonth(m string) string {
	if len(m) == 7 && m[:2] == "20" && m[5] >= '0' && m[5] <= '1' {
		if mm := m[5:]; mm >= "01" && mm <= "12" {
			return m
		}
	}
	return "undated"
}

var gcoBuckets = []string{"Act On", "Consider", "Noted", "Dismissed"}
var gcoConcerns = []string{"Correctness", "Guards that cannot fail", "Security and trust boundaries", "Error handling", "Visual regression", "Portability", "Hygiene", "Scope creep", "Dead code", "Unnecessary complexity", "Standards violations"} // the list since t-0ca2, then the five before it

// gcoSlice is every count for one cut of the data (everything, one model or one month).
type gcoSlice struct {
	Reviews      int            `json:"reviews"`
	Triaged      int            `json:"triaged_reviews"`
	WithActOn    int            `json:"reviews_with_act_on"`
	Lines        map[string]int `json:"bucket_lines"` // non-none lines per bucket
	Verdicts     map[string]int `json:"reviewer_verdicts"`
	Concerns     map[string]int `json:"concern_lines"` // non-none lines per template label
	Evals        int            `json:"evaluations"`
	EvalVerdicts map[string]int `json:"evaluator_verdicts"`
	Criteria     map[string]int `json:"criteria_rows"`
}

func newGcoSlice() *gcoSlice {
	return &gcoSlice{Lines: map[string]int{}, Verdicts: map[string]int{}, Concerns: map[string]int{}, EvalVerdicts: map[string]int{}, Criteria: map[string]int{}}
}

type gcoReport struct {
	Tickets    int                  `json:"tickets"`
	Unreadable map[string]int       `json:"unreadable"` // reason -> files
	RootError  bool                 `json:"tickets_folder_unreadable,omitempty"`
	Total      *gcoSlice            `json:"total"`
	ByModel    map[string]*gcoSlice `json:"by_model"`
	ByMonth    map[string]*gcoSlice `json:"by_month"`
}

func gcoModel(raw string) string {
	l := strings.ToLower(raw)
	switch {
	case strings.Contains(l, "opus"):
		return "opus"
	case strings.Contains(l, "sonnet"):
		return "sonnet"
	case strings.Contains(l, "haiku"):
		return "haiku"
	case strings.TrimSpace(l) == "":
		return "unknown"
	}
	return "other"
}

// gcoRead returns a regular file's lines (at most gcoMaxFile bytes), or a fixed reason it could not.
func gcoRead(path string) ([]string, string) {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ""
		}
		return nil, "unreadable"
	}
	if !fi.Mode().IsRegular() {
		return nil, "not a regular file"
	}
	if fi.Size() > gcoMaxFile {
		return nil, "larger than 256 KB"
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, "unreadable"
	}
	txt := strings.TrimPrefix(string(b), "\ufeff")
	return strings.Split(strings.ReplaceAll(txt, "\r\n", "\n"), "\n"), ""
}

func (r *gcoReport) cut(model, month string) []*gcoSlice {
	m, mo := r.ByModel[model], r.ByMonth[month]
	if m == nil {
		m = newGcoSlice()
		r.ByModel[model] = m
	}
	if mo == nil {
		mo = newGcoSlice()
		r.ByMonth[month] = mo
	}
	return []*gcoSlice{r.Total, m, mo}
}

func gcoReview(lines []string, r *gcoReport) {
	model, month, verdict := "unknown", "undated", "other"
	triaged, inTriage, inFindings, inVerdict := false, false, false, false
	lineCount := map[string]int{}
	concern := map[string]int{}
	for _, ln := range lines {
		switch {
		case strings.HasPrefix(ln, "## "):
			inFindings = strings.HasPrefix(ln, "## Findings")
			inVerdict = strings.HasPrefix(ln, "## Verdict")
			if m := gcoRevVerRe.FindStringSubmatch(ln); m != nil { // the heading form: ## Verdict: YES
				verdict = m[1]
			}
			inTriage = strings.HasPrefix(ln, "## Triage")
			if inTriage {
				triaged = true
			}
			continue
		}
		if m := gcoModelRe.FindStringSubmatch(ln); m != nil && model == "unknown" {
			model = gcoModel(m[1])
		}
		if m := gcoMonthRe.FindStringSubmatch(ln); m != nil && month == "undated" {
			month = gcoMonth(m[2])
		}
		if m := gcoRevVerRe.FindStringSubmatch(ln); m != nil {
			verdict = m[1]
		}
		if inVerdict && strings.TrimSpace(ln) != "" {
			if w := strings.Fields(strings.ReplaceAll(ln, "*", "")); len(w) > 0 {
				switch strings.TrimRight(w[0], ".:,") { // exactly YES or NO: a prose "No blocking findings" is not a verdict
				case "YES", "NO":
					verdict = strings.TrimRight(w[0], ".:,")
				}
			}
			inVerdict = false
		}
		if inFindings {
			if m := gcoConcernRe.FindStringSubmatch(strings.TrimSpace(ln)); m != nil && !gcoNoneRe.MatchString(strings.TrimSpace(m[2])) {
				concern[m[1]]++
			}
		}
		if m := gcoBucketRe.FindStringSubmatch(ln); inTriage && m != nil && !gcoNoneRe.MatchString(strings.TrimSpace(m[2])) {
			lineCount[m[1]]++
		}
	}
	for _, s := range r.cut(model, month) {
		s.Reviews++
		s.Verdicts[verdict]++
		if triaged {
			s.Triaged++
			if lineCount["Act On"] > 0 {
				s.WithActOn++
			}
			for b, n := range lineCount {
				s.Lines[b] += n
			}
		}
		for c, n := range concern {
			s.Concerns[c] += n
		}
	}
}

func gcoEval(lines []string, r *gcoReport) {
	model, month, verdict := "unknown", "undated", "other"
	inCriteria := false
	crit := map[string]int{}
	for _, ln := range lines {
		if strings.HasPrefix(ln, "## ") {
			inCriteria = strings.HasPrefix(ln, "## Criteria")
			if m := gcoHeadVerRe.FindStringSubmatch(ln); m != nil && verdict == "other" {
				verdict = m[1]
			}
			continue
		}
		if m := gcoModelRe.FindStringSubmatch(ln); m != nil && model == "unknown" {
			model = gcoModel(m[1])
		}
		if m := gcoMonthRe.FindStringSubmatch(ln); m != nil && month == "undated" {
			month = gcoMonth(m[2])
		}
		if m := gcoVerdictRe.FindStringSubmatch(ln); m != nil && verdict == "other" {
			verdict = m[1]
		}
		if inCriteria && strings.HasPrefix(strings.TrimSpace(ln), "|") {
			cells := strings.Split(strings.ReplaceAll(strings.Trim(strings.TrimSpace(ln), "|"), `\|`, "\x00"), "|") // an escaped pipe is part of a cell
			if len(cells) < 3 {
				continue
			}
			first, st := strings.ToLower(strings.TrimSpace(cells[0])), strings.ToLower(strings.TrimSpace(cells[1]))
			if first == "criterion" || strings.Trim(first, "-: ") == "" {
				continue
			}
			switch {
			case strings.HasPrefix(st, "pass"):
				crit["pass"]++
			case strings.HasPrefix(st, "fail"):
				crit["fail"]++
			case strings.HasPrefix(st, "partial"):
				crit["partial"]++
			case strings.HasPrefix(st, "not-run"), strings.HasPrefix(st, "not run"):
				crit["not-run"]++
			default:
				crit["other"]++
			}
		}
	}
	for _, s := range r.cut(model, month) {
		s.Evals++
		s.EvalVerdicts[verdict]++
		for k, n := range crit {
			s.Criteria[k] += n
		}
	}
}

func gateCorpus(root string) gcoReport {
	r := gcoReport{Unreadable: map[string]int{}, Total: newGcoSlice(), ByModel: map[string]*gcoSlice{}, ByMonth: map[string]*gcoSlice{}}
	entries, err := os.ReadDir(filepath.Join(root, ".tickets"))
	if err != nil {
		if !os.IsNotExist(err) {
			r.RootError = true // a folder that is there but cannot be read is not an empty one
			r.Unreadable[".tickets/ itself"]++
		}
		return r
	}
	for _, e := range entries {
		if !e.IsDir() || !gcoIDRe.MatchString(e.Name()) {
			continue
		}
		r.Tickets++
		dir := filepath.Join(root, ".tickets", e.Name())
		for _, f := range []struct {
			name string
			fn   func([]string, *gcoReport)
		}{{"review-notes.md", gcoReview}, {"eval-report.md", gcoEval}} {
			lines, why := gcoRead(filepath.Join(dir, f.name))
			if why != "" {
				r.Unreadable[why]++
				continue
			}
			if lines != nil {
				f.fn(lines, &r)
			}
		}
	}
	return r
}

func gcoPct(a, b int) string {
	if b == 0 {
		return "-"
	}
	return fmt.Sprintf("%d%%", a*100/b)
}

func gcoText(r gcoReport, w io.Writer) {
	t := r.Total
	if r.RootError {
		fmt.Fprintln(w, "gate corpus: this project's .tickets/ exists but cannot be read")
		return
	}
	if r.Tickets == 0 {
		fmt.Fprintln(w, "gate corpus: no tickets in this project's .tickets/")
		return
	}
	fmt.Fprintf(w, "gate corpus, from the tickets' own reports (counts of fixed shapes only): %d tickets, %d review-notes.md, %d eval-report.md\n", r.Tickets, t.Reviews, t.Evals)
	if len(r.Unreadable) > 0 {
		var u []string
		for k, n := range r.Unreadable {
			u = append(u, fmt.Sprintf("%d %s", n, k))
		}
		sort.Strings(u)
		fmt.Fprintf(w, "unreadable: %s\n", strings.Join(u, ", "))
	}
	fmt.Fprintf(w, "\nreviewer: YES %d, NO %d, other %d\n", t.Verdicts["YES"], t.Verdicts["NO"], t.Verdicts["other"])
	fmt.Fprintf(w, "  triaged reviews (with a ## Triage section): %d; with an Act On line: %d (%s)\n", t.Triaged, t.WithActOn, gcoPct(t.WithActOn, t.Triaged))
	var bl []string
	for _, b := range gcoBuckets {
		bl = append(bl, fmt.Sprintf("%s %d", b, t.Lines[b]))
	}
	fmt.Fprintf(w, "  bucket lines (not none): %s\n", strings.Join(bl, ", "))
	var cl []string
	for _, c := range gcoConcerns {
		cl = append(cl, fmt.Sprintf("%s %d", c, t.Concerns[c]))
	}
	fmt.Fprintf(w, "  concern lines (not none, in a ## Findings section): %s\n", strings.Join(cl, ", "))
	fmt.Fprintf(w, "\nevaluator: pass %d, fail %d, partial %d, not-run %d, other %d\n", t.EvalVerdicts["pass"], t.EvalVerdicts["fail"], t.EvalVerdicts["partial"], t.EvalVerdicts["not-run"], t.EvalVerdicts["other"])
	fmt.Fprintf(w, "  criteria rows: pass %d, fail %d, partial %d, not-run %d, other %d\n", t.Criteria["pass"], t.Criteria["fail"], t.Criteria["partial"], t.Criteria["not-run"], t.Criteria["other"])
	table := func(title string, m map[string]*gcoSlice) {
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		fmt.Fprintf(w, "\n%s: reviews (triaged, with Act On, Act On lines) | evaluations (pass, fail+partial)\n", title)
		for _, k := range keys {
			s := m[k]
			fmt.Fprintf(w, "  %-9s %4d (%d, %d, %d) | %4d (%d, %d)\n", k, s.Reviews, s.Triaged, s.WithActOn, s.Lines["Act On"], s.Evals, s.EvalVerdicts["pass"], s.EvalVerdicts["fail"]+s.EvalVerdicts["partial"])
		}
	}
	table("by model", r.ByModel)
	table("by month", r.ByMonth)
}

func gateCorpusCLI(args []string, stdout, stderr io.Writer) int {
	asJSON := false
	for _, a := range args {
		if a == "--json" {
			asJSON = true
			continue
		}
		fmt.Fprintln(stderr, "usage: canon-go gate-corpus [--json]")
		return 2
	}
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(stderr, "gate-corpus: cannot find the project:", err)
		return 1
	}
	rep := gateCorpus(root)
	if rep.RootError {
		fmt.Fprintln(stderr, "gate-corpus: .tickets/ exists but cannot be read")
		return 1
	}
	if asJSON {
		b, err := json.Marshal(rep)
		if err != nil {
			fmt.Fprintln(stderr, "gate-corpus: cannot write the report:", err)
			return 1
		}
		fmt.Fprintln(stdout, string(b))
		return 0
	}
	gcoText(rep, stdout)
	return 0
}
