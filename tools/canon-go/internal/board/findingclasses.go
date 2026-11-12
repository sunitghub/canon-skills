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

// canon-go finding-classes (t-70f2): how often each finding class repeats across tickets, so a class that keeps happening is a counted
// recurrence and not a fresh finding every time. A gate ends a finding with `class: <slug>` (slugs: tools/finding-classes.tsv, the one owner,
// pinned to review.md by tests/doc-mirror-parity.sh): the reviewer inside its [severity · confidence · class: x] bracket, the evaluator as a
// trailing [class: x]. Counts come from finding lines under `## Findings` of review-notes.md and eval-report.md only (the triage buckets cite
// the same findings, so counting them would count twice). Read-only, local, no model call. Every report file is untrusted: only a table slug,
// a ticket id (matched by gcoIDRe) and a count are ever printed; a tag that is not in the table counts as `unknown` and its text is dropped.
// The ladder: a class in 2 of the last N tickets proposes a rule; in 3 proposes a mechanical check. A promoted rule that later tickets
// named again (promoted-report's own count) is listed in the report, never in the `sprint start` line (that would repeat forever).

var (
	fcTagRe    = regexp.MustCompile(`\[(?:[^\]]*· )?class: ([a-z][a-z0-9-]{0,40})\][ \t.\x60]*$`)
	fcItemRe   = regexp.MustCompile(`^[ \t]*(?:[0-9]+[.)]|[-*])[ \t]+(.*)$`)
	fcSlugRe   = regexp.MustCompile(`^[a-z][a-z0-9-]{0,40}$`)
	fcFindHead = regexp.MustCompile(`^##[ \t]+Findings[ \t]*$`)
)

type fcClass struct {
	Slug     string   `json:"class"`
	Tickets  []string `json:"tickets"`
	Findings int      `json:"findings"`
	Step     string   `json:"step,omitempty"` // "rule" or "check"
}

type fcPromoted struct {
	Slug  string `json:"class"`
	ID    string `json:"id,omitempty"`
	Later int    `json:"later_tickets_naming_the_class"`
}

type fcReport struct {
	Window   int          `json:"last"`
	Tickets  int          `json:"tickets_read"` // tickets in the window with a readable gate report
	Tagged   int          `json:"tagged_findings"`
	Untagged int          `json:"untagged_findings"`
	Unknown  int          `json:"unknown_class_findings"`
	Classes  []fcClass    `json:"classes"`
	Promoted []fcPromoted `json:"promoted_rules_recurred"`
}

// fcLoadTable reads tools/finding-classes.tsv: `slug<TAB>meaning<TAB>concern`, '#' comments and blank lines skipped.
func fcLoadTable(file string) (map[string]bool, error) {
	ls, why := gcoRead(file)
	if why != "" {
		return nil, fmt.Errorf("%s: %s", file, why)
	}
	slugs := map[string]bool{}
	for n, ln := range ls {
		if strings.TrimSpace(ln) == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		c := strings.Split(ln, "\t")
		if len(c) != 3 || !fcSlugRe.MatchString(c[0]) || slugs[c[0]] {
			return nil, fmt.Errorf("%s:%d: want slug<TAB>meaning<TAB>concern with a new lowercase slug", file, n+1)
		}
		slugs[c[0]] = true
	}
	if len(slugs) == 0 {
		return nil, fmt.Errorf("%s: no classes", file)
	}
	return slugs, nil
}

// fcFindings returns the class slug of each finding line under `## Findings` ("" when untagged). review selects the reviewer's concern lines;
// otherwise the evaluator's list items ("No findings." is no item).
func fcFindings(lines []string, review bool) []string {
	var out []string
	in := false
	for _, ln := range lines {
		if strings.HasPrefix(ln, "## ") || ln == "##" {
			in = fcFindHead.MatchString(ln)
			continue
		}
		if !in {
			continue
		}
		var body string
		if review {
			m := gcoConcernRe.FindStringSubmatch(ln)
			if m == nil || gcoNoneRe.MatchString(strings.TrimSpace(m[2])) {
				continue
			}
			body = ln
		} else {
			m := fcItemRe.FindStringSubmatch(ln)
			if m == nil {
				continue
			}
			body = m[1]
		}
		if t := fcTagRe.FindStringSubmatch(body); t != nil {
			out = append(out, t[1])
		} else {
			out = append(out, "")
		}
	}
	return out
}

type fcTicket struct{ id, created string }

// fcTickets lists the ticket folders newest first (created date, then id), as promoted-report reads them.
func fcTickets(root string) []fcTicket {
	dirs, err := os.ReadDir(filepath.Join(root, ".tickets"))
	if err != nil {
		return nil
	}
	var ts []fcTicket
	for _, d := range dirs {
		if !gcoIDRe.MatchString(d.Name()) || !d.IsDir() { // IsDir is false for a symlink, so a linked folder is never followed
			continue
		}
		created := ""
		if ls, why := gcoRead(filepath.Join(root, ".tickets", d.Name(), "ticket.md")); why == "" {
			for _, ln := range ls[:min(len(ls), 30)] {
				if m := prCreatedRe.FindStringSubmatch(ln); m != nil {
					created = m[1]
					break
				}
			}
		}
		ts = append(ts, fcTicket{d.Name(), created})
	}
	sort.Slice(ts, func(i, j int) bool {
		if ts[i].created != ts[j].created {
			return ts[i].created > ts[j].created
		}
		return ts[i].id > ts[j].id
	})
	return ts
}

func findingClasses(root string, slugs map[string]bool, last int) *fcReport {
	r := &fcReport{Window: last, Classes: []fcClass{}, Promoted: []fcPromoted{}}
	byClass := map[string]*fcClass{}
	for _, t := range fcTickets(root) {
		if r.Tickets >= last {
			break
		}
		seen, read := map[string]bool{}, false
		for _, f := range []struct {
			name   string
			review bool
		}{{"review-notes.md", true}, {"eval-report.md", false}} {
			ls, why := gcoRead(filepath.Join(root, ".tickets", t.id, f.name))
			if why != "" || ls == nil {
				continue
			}
			read = true
			for _, slug := range fcFindings(ls, f.review) {
				switch {
				case slug == "":
					r.Untagged++
				case !slugs[slug]:
					r.Unknown++
				default:
					r.Tagged++
					c := byClass[slug]
					if c == nil {
						c = &fcClass{Slug: slug, Tickets: []string{}}
						byClass[slug] = c
					}
					c.Findings++
					if !seen[slug] {
						seen[slug] = true
						c.Tickets = append(c.Tickets, t.id)
					}
				}
			}
		}
		if read {
			r.Tickets++
		}
	}
	for _, c := range byClass {
		switch n := len(c.Tickets); {
		case n >= 3:
			c.Step = "check"
		case n == 2:
			c.Step = "rule"
		}
		r.Classes = append(r.Classes, *c)
	}
	sort.Slice(r.Classes, func(i, j int) bool {
		if a, b := len(r.Classes[i].Tickets), len(r.Classes[j].Tickets); a != b {
			return a > b
		}
		return r.Classes[i].Slug < r.Classes[j].Slug
	})
	return r
}

// fcPromotedRecurred lists the promoted rules a later ticket named again, from promoted-report's own count. It reads git blame for every
// tagged file, so `--start` (which runs at every sprint start and never prints it) does not call it.
func fcPromotedRecurred(root string) []fcPromoted {
	out := []fcPromoted{}
	for _, e := range promotedReport(root).Entries {
		if e.BySlug > 0 {
			out = append(out, fcPromoted{e.Slug, e.ID, e.BySlug})
		}
	}
	return out
}

var fcStepText = map[string]string{
	"rule":  "propose a rule",
	"check": "propose a mechanical check (a ticket stub, never auto-filed)",
}

func (c fcClass) line() string {
	return fmt.Sprintf("%s in %d tickets (%s): %s", c.Slug, len(c.Tickets), strings.Join(c.Tickets, " "), fcStepText[c.Step])
}

func findingClassesCLI(args []string, stdout, stderr io.Writer) int {
	const usage = "usage: canon-go finding-classes [--last N] [--json] [--start] [--table <file>]"
	last, asJSON, start, table := 10, false, false, ""
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			asJSON = true
		case a == "--start":
			start = true
		case a == "--table" && i+1 < len(args):
			i++
			table = args[i]
		case a == "--last" && i+1 < len(args):
			i++
			if _, err := fmt.Sscanf(args[i], "%d", &last); err != nil || last < 1 || last > 200 || fmt.Sprint(last) != args[i] {
				fmt.Fprintln(stderr, usage)
				return 2
			}
		default:
			fmt.Fprintln(stderr, usage)
			return 2
		}
	}
	if table == "" {
		root := cliCanonRoot()
		if root == "" {
			fmt.Fprintln(stderr, "finding-classes: no canon install found; pass --table <file>")
			return 2
		}
		table = filepath.Join(root, "tools", "finding-classes.tsv")
	}
	slugs, err := fcLoadTable(table)
	if err != nil {
		fmt.Fprintln(stderr, "finding-classes:", err)
		return 2
	}
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(stderr, "finding-classes: cannot find the project:", err)
		return 1
	}
	rep := findingClasses(root, slugs, last)
	if !start {
		rep.Promoted = fcPromotedRecurred(root)
	}
	switch {
	case start:
		for _, c := range rep.Classes {
			if c.Step != "" {
				fmt.Fprintln(stdout, "Recurring finding class: "+c.line()+". Details: canon-go finding-classes")
			}
		}
	case asJSON:
		b, err := json.Marshal(rep)
		if err != nil {
			fmt.Fprintln(stderr, "finding-classes:", err)
			return 1
		}
		fmt.Fprintln(stdout, string(b))
	default:
		fmt.Fprintf(stdout, "finding classes: %d tickets with a gate report (newest %d); %d tagged findings, %d untagged, %d with a class not in the table\n", rep.Tickets, rep.Window, rep.Tagged, rep.Untagged, rep.Unknown)
		for _, c := range rep.Classes {
			line := fmt.Sprintf("%-22s %d tickets, %d findings: %s", c.Slug, len(c.Tickets), c.Findings, strings.Join(c.Tickets, " "))
			if c.Step != "" {
				line += "  -> " + fcStepText[c.Step]
			}
			fmt.Fprintln(stdout, line)
		}
		if len(rep.Classes) == 0 {
			fmt.Fprintln(stdout, "no tagged findings yet: a gate ends a finding with `class: <slug>` (tools/finding-classes.tsv)")
		}
		for _, p := range rep.Promoted {
			id := p.ID
			if id == "" {
				id = "no id"
			}
			fmt.Fprintf(stdout, "promoted rule %s (%s) was named again by %d later tickets  -> %s\n", p.Slug, id, p.Later, fcStepText["check"])
		}
	}
	return 0
}
