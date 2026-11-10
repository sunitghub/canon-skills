package board

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// canon-go promoted-report (t-1219 slice 1): for each promoted line tagged `(t-xxxx; class: slug[; id: P-007])`, the date the line last changed
// (git blame: a reworded line restarts its clock) and how many LATER tickets name its exact slug or any of its promoting ticket ids in their review-notes.md,
// eval-report.md or learnings.md. A count of 0 means the slug was never written in a report, not that the failure never came back: the report says so.
// Read-only, local, no model call. Every file is untrusted: only slugs and ids that match the tag's character set, dates and counts are printed.

var (
	prTagRe     = regexp.MustCompile(`\(((?:t-[a-z0-9]{4})(?:, t-[a-z0-9]{4}){0,9}); class: ([a-z0-9][a-z0-9-]{0,80})(?:; id: (P-[0-9]{1,5}))?\)`)
	prCreatedRe = regexp.MustCompile(`^created:[ \t]*([0-9]{4}-[0-9]{2}-[0-9]{2})`)
)

var prPlaces = []string{"standards", "skills", "tools/sprint-check-app/CLAUDE.md", "docs/releasing.md", "PROMOTED.md", "critique/canon-learnings.md"}
var prReports = []string{"review-notes.md", "eval-report.md", "learnings.md"}

type prEntry struct {
	File     string   `json:"file"`
	Slug     string   `json:"class"`
	Tickets  []string `json:"tickets"` // the promoting ticket or tickets, as the tag lists them
	ID       string   `json:"id,omitempty"`
	Date     string   `json:"promoted,omitempty"` // the line's last change; empty when git cannot say
	Mentions int      `json:"later_tickets_referencing_it"`
	BySlug   int      `json:"later_tickets_naming_the_class"` // drives the verdict; a promoting ticket id alone is a reference, not a recurrence
	Verdict  string   `json:"verdict"`
}

type prReport struct {
	Entries    []prEntry      `json:"entries"`
	Tickets    int            `json:"tickets_read"`
	Skipped    map[string]int `json:"skipped"`    // reason -> lines or tickets not counted
	Unreadable map[string]int `json:"unreadable"` // reason -> files
	Sizes      []prSize       `json:"sizes"`      // t-3620: what the promoted files and the always-on files cost to read

	tagged map[string][]prLine // file -> its promoted lines, once each however many tags they carry
	noted  map[string]string   // file -> why it could not be read
}

// prLine is one promoted line: its words and the day it last changed (empty when git cannot say).
type prLine struct {
	words int
	day   string
}

// prSize is one row of the size table. Words follow the cap meter's rule (capWords: ASCII whitespace, byte-wise), so a row agrees with `canon-go caps`.
type prSize struct {
	File          string `json:"file"`
	AlwaysOn      bool   `json:"always_on"`      // read in every session, so every line is paid every session
	Note          string `json:"note,omitempty"` // why a row has no numbers
	Lines         int    `json:"lines"`          // newline count, as wc -l
	Words         int    `json:"words"`
	Tokens        int    `json:"tokens_estimate"` // words x 1.3: an estimate, not a tokenizer's count
	PromotedLines int    `json:"promoted_lines"`
	PromotedWords int    `json:"promoted_words"`
	SinceWords    *int   `json:"since_words,omitempty"`   // with --since: words of promoted lines last changed on or after the day
	NoClassTags   bool   `json:"no_class_tags,omitempty"` // promoted lines without a class tag (a consumer's PROMOTED.md): recurrence is n/a, not 0
	CapUsed       *int64 `json:"cap_used,omitempty"`
	CapLimit      int64  `json:"cap_limit,omitempty"`
	CapUnit       string `json:"cap_unit,omitempty"`
}

// prAlwaysOn are the files a session reads whatever it does (canon's own standards file, the project's agent files and a consumer's PROMOTED.md).
var prAlwaysOn = []string{"standards/efficiency.md", "AGENTS.md", "CLAUDE.md", "PROMOTED.md"}

// prPromotedCap is PROMOTED.md's advisory block cap (owner: skills/promote-learnings/SKILL.md). It is not in tools/caps.tsv on purpose: that table gates a close.
const prPromotedCap = 60

func prVerdict(n int) string {
	switch {
	case n >= 2:
		return "Failing again"
	case n == 1:
		return "Mentioned once"
	}
	return "Not mentioned"
}

// prFiles lists the markdown files under the fixed places, sorted, without following a symlink.
func prFiles(root string) []string {
	var out []string
	for _, p := range prPlaces {
		full := filepath.Join(root, p)
		fi, err := os.Lstat(full)
		if err != nil {
			continue
		}
		if fi.Mode().IsRegular() {
			out = append(out, p)
			continue
		}
		if !fi.IsDir() {
			continue
		}
		_ = filepath.WalkDir(full, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.Type()&fs.ModeSymlink != 0 {
				return nil
			}
			if d.Type().IsRegular() && strings.HasSuffix(path, ".md") {
				if rel, e := filepath.Rel(root, path); e == nil {
					out = append(out, filepath.ToSlash(rel))
				}
			}
			return nil
		})
	}
	sort.Strings(out)
	return out
}

// prBlameDates returns the last-change day of every line of a file (index = line number - 1), or nil when git cannot say.
func prBlameDates(root, rel string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	args := []string{"-C", root, "blame", "--line-porcelain"}
	if fi, err := os.Lstat(filepath.Join(root, ".git-blame-ignore-revs")); err == nil && fi.Mode().IsRegular() {
		args = append(args, "--ignore-revs-file", ".git-blame-ignore-revs") // a commit that only added ids must not reset a line's promotion date
	}
	cmd := exec.CommandContext(ctx, "git", append(args, "--", rel)...)
	cmd.Dir = root
	for _, e := range os.Environ() {
		if !strings.HasPrefix(e, "GIT_DIR=") && !strings.HasPrefix(e, "GIT_WORK_TREE=") {
			cmd.Env = append(cmd.Env, e)
		}
	}
	b, err := cmd.Output()
	if err != nil {
		return nil
	}
	var days []string
	cur := ""
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 0, 64<<10), 4<<20)
	for sc.Scan() {
		ln := sc.Text()
		switch {
		case strings.HasPrefix(ln, "author-time "):
			if n, e := strconv.ParseInt(strings.TrimPrefix(ln, "author-time "), 10, 64); e == nil {
				cur = time.Unix(n, 0).UTC().Format("2006-01-02")
			}
		case strings.HasPrefix(ln, "\t"):
			days = append(days, cur)
		}
	}
	return days
}

func promotedReport(root string) *prReport {
	r := &prReport{Entries: []prEntry{}, Skipped: map[string]int{}, Unreadable: map[string]int{}, tagged: map[string][]prLine{}, noted: map[string]string{}}
	for _, rel := range prFiles(root) {
		lines, why := gcoRead(filepath.Join(root, rel))
		if why != "" {
			r.Unreadable[why]++
			r.noted[rel] = why
			continue
		}
		var days []string
		blamed := false
		fence := false
		for i, ln := range lines {
			ms := prTagRe.FindAllStringSubmatch(ln, -1)
			if strings.HasPrefix(strings.TrimSpace(ln), "```") {
				fence = !fence
				if len(ms) > 0 {
					r.Skipped["tag on a code fence line"] += len(ms)
				}
				continue
			}
			if len(ms) == 0 {
				continue
			}
			if fence {
				r.Skipped["tag inside a code fence"] += len(ms)
				continue
			}
			if !blamed {
				days, blamed = prBlameDates(root, rel), true
			}
			day := ""
			if i < len(days) {
				day = days[i]
			}
			for _, m := range ms {
				if day == "" {
					r.Skipped["no git date for the line"]++
				}
				r.Entries = append(r.Entries, prEntry{File: rel, Slug: m[2], Tickets: strings.Split(m[1], ", "), ID: m[3], Date: day})
			}
			r.tagged[rel] = append(r.tagged[rel], prLine{words: int(capWords([]byte(ln))), day: day})
		}
	}

	type tk struct{ id, created, text string }
	var tickets []tk
	dirs, err := os.ReadDir(filepath.Join(root, ".tickets"))
	if err != nil && !os.IsNotExist(err) {
		r.Unreadable[".tickets/ itself"]++
	}
	for _, d := range dirs {
		if !strings.HasPrefix(d.Name(), "t-") || !d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			continue
		}
		dir := filepath.Join(root, ".tickets", d.Name())
		created := ""
		if ls, why := gcoRead(filepath.Join(dir, "ticket.md")); why == "" {
			for _, ln := range ls[:min(len(ls), 30)] {
				if m := prCreatedRe.FindStringSubmatch(ln); m != nil {
					created = m[1]
					break
				}
			}
		} else {
			r.Unreadable[why]++
		}
		if created == "" {
			r.Skipped["ticket without a created date"]++
			continue
		}
		var sb strings.Builder
		for _, f := range prReports {
			ls, why := gcoRead(filepath.Join(dir, f))
			if why != "" {
				r.Unreadable[why]++
				continue
			}
			sb.WriteString(strings.Join(ls, "\n"))
			sb.WriteByte('\n')
		}
		tickets = append(tickets, tk{d.Name(), created, sb.String()})
	}
	r.Tickets = len(tickets)
	for i := range r.Entries {
		e := &r.Entries[i]
		if e.Date == "" {
			e.Verdict = "No date"
			continue
		}
		for _, t := range tickets {
			if t.created <= e.Date || prHas(e.Tickets, t.id) {
				continue
			}
			slug := strings.Contains(t.text, e.Slug) || (e.ID != "" && prCitesID(t.text, e.ID)) // a reviewer or evaluator naming the id says the failure the line was meant to stop happened again
			hit := slug
			for _, id := range e.Tickets {
				hit = hit || strings.Contains(t.text, id)
			}
			if hit {
				e.Mentions++
			}
			if slug {
				e.BySlug++
			}
		}
		e.Verdict = prVerdict(e.BySlug) // a ticket id in a report is a reference, not a recurrence: only the class itself drives the verdict
	}
	sort.SliceStable(r.Entries, func(a, b int) bool {
		x, y := r.Entries[a], r.Entries[b]
		if x.Mentions != y.Mentions {
			return x.Mentions > y.Mentions
		}
		if x.File != y.File {
			return x.File < y.File
		}
		return x.Slug < y.Slug
	})
	r.addSizes(root)
	return r
}

// prCapRows reads canon's cap table (tools/caps.tsv of the install or checkout the binary runs from); nil when there is none.
func prCapRows() []capRow {
	root := cliCanonRoot()
	if root == "" {
		return nil
	}
	rows, err := loadCaps(filepath.Join(root, "tools", "caps.tsv"))
	if err != nil {
		return nil
	}
	return rows
}

// addSizes fills the size table: the always-on files first, then every other file that holds a promoted line or could not be read. A file
// that is absent says so, and one that cannot be read says why: never a zero.
func (r *prReport) addSizes(root string) {
	files := append([]string{}, prAlwaysOn...)
	seen := map[string]bool{}
	for _, f := range files {
		seen[f] = true
	}
	var rest []string
	for f := range r.tagged {
		if !seen[f] {
			seen[f] = true
			rest = append(rest, f)
		}
	}
	for f := range r.noted {
		if !seen[f] {
			seen[f] = true
			rest = append(rest, f)
		}
	}
	sort.Strings(rest)
	caps := prCapRows()
	r.Sizes = []prSize{}
	for _, rel := range append(files, rest...) {
		sz := prSize{File: rel, AlwaysOn: prHas(prAlwaysOn, rel)}
		lines, why := gcoRead(filepath.Join(root, rel))
		switch {
		case why != "":
			sz.Note = why
		case lines == nil:
			sz.Note = "not in this project"
		default:
			body := strings.Join(lines, "\n")
			sz.Lines = len(lines) - 1
			sz.Words = int(capWords([]byte(body)))
			sz.Tokens = sz.Words * 13 / 10
			if rel == "PROMOTED.md" && len(r.tagged[rel]) == 0 {
				r.promotedBlock(root, rel, lines)
				sz.NoClassTags = len(r.tagged[rel]) > 0
				if used, err := capBlockLines([]byte(body), "canon:promoted"); err == nil {
					sz.CapUsed, sz.CapLimit, sz.CapUnit = &used, prPromotedCap, "block-lines"
				}
			}
			for _, l := range r.tagged[rel] {
				sz.PromotedLines++
				sz.PromotedWords += l.words
			}
			for _, c := range caps {
				if c.Path != rel || (c.Unit != "words" && c.Unit != "block-lines") {
					continue
				}
				var used int64
				if c.Unit == "words" {
					used = capWords([]byte(body))
				} else if u, err := capBlockLines([]byte(body), c.Marker); err == nil {
					used = u
				} else {
					continue
				}
				sz.CapUsed, sz.CapLimit, sz.CapUnit = &used, c.Limit, capUnits[c.Unit]
			}
		}
		r.Sizes = append(r.Sizes, sz)
	}
}

// promotedBlock reads a consumer's PROMOTED.md: its entries (`- ` lines between the managed markers) are the promoted lines, though they carry no class tag.
func (r *prReport) promotedBlock(root, rel string, lines []string) {
	var days []string
	in := false
	for i, ln := range lines {
		switch {
		case strings.Contains(ln, "<!-- canon:promoted:BEGIN -->"):
			in = true
		case strings.Contains(ln, "<!-- canon:promoted:END -->"):
			return
		case in && strings.HasPrefix(strings.TrimSpace(ln), "- "):
			if days == nil {
				days = prBlameDates(root, rel)
			}
			day := ""
			if i < len(days) {
				day = days[i]
			}
			r.tagged[rel] = append(r.tagged[rel], prLine{words: int(capWords([]byte(ln))), day: day})
		}
	}
}

// applySince fills each row's since_words: the words of its promoted lines last changed on or after day (YYYY-MM-DD).
func (r *prReport) applySince(day string) {
	for i := range r.Sizes {
		if r.Sizes[i].Note != "" {
			continue
		}
		n := 0
		for _, l := range r.tagged[r.Sizes[i].File] {
			if l.day != "" && l.day >= day {
				n += l.words
			}
		}
		r.Sizes[i].SinceWords = &n
	}
}

func prText(r *prReport, w io.Writer) {
	fmt.Fprintf(w, "promoted lines, from their (t-…; class: …) tags: %d lines, %d tickets read for a later mention of the class or the promoting ticket\n", len(r.Entries), r.Tickets)
	if len(r.Skipped)+len(r.Unreadable) > 0 {
		var parts []string
		for _, k := range prKeys(r.Skipped) {
			parts = append(parts, fmt.Sprintf("%d not counted: %s", r.Skipped[k], k))
		}
		for _, k := range prKeys(r.Unreadable) {
			parts = append(parts, fmt.Sprintf("%d unreadable: %s", r.Unreadable[k], k))
		}
		fmt.Fprintf(w, "%s\n", strings.Join(parts, "; "))
	}
	fmt.Fprintln(w, "A later ticket counts when its review, eval or learnings text names the class itself or cites its P-id (class N, which drives the verdict) or only a promoting ticket id (ref M: it was mentioned, which is not a recurrence). 0 means never written down, not never recurred.")
	fmt.Fprintln(w)
	for _, e := range r.Entries {
		id := e.ID
		if id == "" {
			id = "-"
		}
		date := e.Date
		if date == "" {
			date = "no date"
		}
		fmt.Fprintf(w, "  %-14s class %-3d ref %-3d %-6s %s (%s, %s)  %s\n", e.Verdict, e.BySlug, e.Mentions, id, e.Slug, strings.Join(e.Tickets, " "), date, prSafeName(e.File))
	}
	prSizeText(r, w)
}

// prSizeText prints the size table (t-3620): what each promoted file and each always-on file costs to read.
func prSizeText(r *prReport, w io.Writer) {
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Size: lines, words (the cap meter's count) and tokens (words x 1.3, an estimate). always-on files are read in every session, so every line there is paid every session.")
	for _, z := range r.Sizes {
		kind := "on demand"
		if z.AlwaysOn {
			kind = "always-on"
		}
		if z.Note != "" {
			fmt.Fprintf(w, "  %-9s %s: %s\n", kind, prSafeName(z.File), z.Note)
			continue
		}
		line := fmt.Sprintf("  %-9s %-52s %5d lines %6d words ~%6d tokens  promoted %d lines, %d words", kind, prSafeName(z.File), z.Lines, z.Words, z.Tokens, z.PromotedLines, z.PromotedWords)
		if z.SinceWords != nil {
			line += fmt.Sprintf(", +%d since", *z.SinceWords)
		}
		if z.CapUsed != nil {
			line += fmt.Sprintf("; cap %d of %d %s", *z.CapUsed, z.CapLimit, z.CapUnit)
		}
		if z.NoClassTags {
			line += "; no class tags, recurrence n/a"
		}
		fmt.Fprintln(w, line)
	}
}

// prSafeName keeps a repo-controlled file name from forging a line or sending an escape code in the text view (JSON escapes it already).
func prSafeName(f string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return '?'
		}
		return r
	}, f)
}

// prCitesID reports whether text names the id as a whole token: P-001 is not found in P-0010 or XP-001.
func prCitesID(text, id string) bool {
	for i := 0; ; {
		j := strings.Index(text[i:], id)
		if j < 0 {
			return false
		}
		start, end := i+j, i+j+len(id)
		if (start == 0 || !prAlnum(text[start-1])) && (end >= len(text) || !prAlnum(text[end])) {
			return true
		}
		i = start + 1
	}
}

func prAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
}

func prHas(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

func prKeys(m map[string]int) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

func promotedReportCLI(args []string, stdout, stderr io.Writer) int {
	const usage = "usage: canon-go promoted-report [--json] [--since YYYY-MM-DD]"
	asJSON, since := false, ""
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			asJSON = true
		case a == "--since" && i+1 < len(args):
			i++
			since = args[i]
		case strings.HasPrefix(a, "--since="):
			since = strings.TrimPrefix(a, "--since=")
		default:
			fmt.Fprintln(stderr, usage)
			return 2
		}
	}
	if since != "" {
		if _, err := time.Parse("2006-01-02", since); err != nil {
			fmt.Fprintln(stderr, usage)
			return 2
		}
	}
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(stderr, "promoted-report: cannot find the project:", err)
		return 1
	}
	rep := promotedReport(root)
	if since != "" {
		rep.applySince(since)
	}
	if rep.Unreadable[".tickets/ itself"] > 0 {
		fmt.Fprintln(stderr, "promoted-report: .tickets/ exists but cannot be read")
		return 1
	}
	if asJSON {
		b, err := json.Marshal(rep)
		if err != nil {
			fmt.Fprintln(stderr, "promoted-report:", err)
			return 1
		}
		fmt.Fprintln(stdout, string(b))
		return 0
	}
	prText(rep, stdout)
	return 0
}
