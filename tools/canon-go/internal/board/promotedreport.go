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
}

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
	r := &prReport{Entries: []prEntry{}, Skipped: map[string]int{}, Unreadable: map[string]int{}}
	for _, rel := range prFiles(root) {
		lines, why := gcoRead(filepath.Join(root, rel))
		if why != "" {
			r.Unreadable[why]++
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
	return r
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
	asJSON := false
	for _, a := range args {
		if a == "--json" {
			asJSON = true
			continue
		}
		fmt.Fprintln(stderr, "usage: canon-go promoted-report [--json]")
		return 2
	}
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(stderr, "promoted-report: cannot find the project:", err)
		return 1
	}
	rep := promotedReport(root)
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
