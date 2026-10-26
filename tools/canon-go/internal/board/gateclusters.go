package board

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"canon/internal/events"
)

// sprint-check gate-clusters (t-b874): group repeated gate failures by cause so a recurring one is seen once.
// Free tier: this machine's files only. No network, no model call, nothing written. The logs are written by other agents,
// so they are untrusted input: only ids, the words in gcKeys/gcFailOutcomes and one capped example line are ever printed.

// gcKeys is the ONE place that names the fields and words this reader depends on, so the event envelope decision
// (t-15b5) is a one-line change here.
var gcKeys = struct {
	RunLog                                          string // path under the project
	RunTS, RunID, RunType, RunTicket, RunOutcome    string
	EvKind, EvRejected, EvTS, EvID, EvData          string
	EvTicket, EvRole, EvReason                      string
	ReviewNotes, EvalReport, VerdictHead, NoVerdict string
}{
	RunLog: ".claude/subagent-runs.jsonl",
	RunTS:  "ts", RunID: "agent_id", RunType: "agent_type", RunTicket: "ticket", RunOutcome: "outcome",
	EvKind: "kind", EvRejected: "gate.rejected", EvTS: "ts", EvID: "id", EvData: "data",
	EvTicket: "ticket", EvRole: "role", EvReason: "reason",
	ReviewNotes: "review-notes.md", EvalReport: "eval-report.md", VerdictHead: "## Verdict", NoVerdict: "NO",
}

// gcFailOutcomes are the run-log outcomes that count as a gate failure.
var gcFailOutcomes = map[string]bool{"fail": true, "partial": true, "not-run": true, "budget": true}

const (
	gcDefaultDays = 30
	gcMaxFiles    = 400
	gcMaxBytes    = 4 << 20 // per file; more is cut and shown as an error line
	gcMaxLine     = 64 << 10
	gcMaxShown    = 5
	gcExampleMax  = 120
	gcCauseMax    = 60
	gcReportMax   = 1 << 20
)

var (
	gcIDRe     = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)
	gcWordRe   = regexp.MustCompile(`^[a-z][a-z0-9_.-]{0,31}$`)
	gcTicketRe = regexp.MustCompile(`^t-[0-9a-f]{4,12}$`)
	gcDayRe    = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\.jsonl$`)
)

type gcRun struct {
	cause, ticket, id, example string
	at                         time.Time
}

// gcCluster is one cause. Tickets and Runs are complete (the text view shows the first gcMaxShown).
type gcCluster struct {
	Cause   string   `json:"cause"`
	Count   int      `json:"count"`
	Tickets []string `json:"tickets"`
	Runs    []string `json:"runs"`
	Example string   `json:"example"`
	Last    string   `json:"last"`
}

type gcReport struct {
	Days       int         `json:"days"`
	Clusters   []gcCluster `json:"clusters"`
	SeenOnce   []gcCluster `json:"seen_once"`
	Unreadable int         `json:"unreadable_lines"`
	Errors     []string    `json:"errors"`
}

// gcClean keeps printable text only (control characters dropped, one line) and cuts it to max runes.
func gcClean(s string, max int) string {
	var b strings.Builder
	n := 0
	for _, r := range s {
		if unicode.IsControl(r) || !unicode.IsPrint(r) {
			r = ' '
		}
		if n >= max {
			break
		}
		b.WriteRune(r)
		n++
	}
	return strings.TrimSpace(b.String())
}

func gcID(s string) string {
	if gcIDRe.MatchString(s) {
		return s
	}
	return ""
}

func gcWord(s string) string {
	if gcWordRe.MatchString(s) {
		return s
	}
	return "unknown"
}

// gcLines calls fn on each line of a regular file (not a symlink), reading at most gcMaxBytes. A line over gcMaxLine is
// counted unreadable, not parsed. The returned string is an error line, "" when the file was read whole.
func gcLines(path, label string, fn func([]byte), unreadable *int) string {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return label + ": missing"
		}
		return label + ": cannot read"
	}
	if !fi.Mode().IsRegular() {
		return label + ": not a regular file"
	}
	f, err := os.Open(path)
	if err != nil {
		return label + ": cannot read"
	}
	defer f.Close()
	r := bufio.NewReaderSize(io.LimitReader(f, gcMaxBytes), 4096)
	var buf []byte
	long := false
	for {
		chunk, err := r.ReadSlice('\n')
		if !long && len(buf)+len(chunk) <= gcMaxLine {
			buf = append(buf, chunk...)
		} else {
			long, buf = true, buf[:0]
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if long {
			*unreadable++
		} else if line := strings.TrimSpace(string(buf)); line != "" {
			fn([]byte(line))
		}
		buf, long = buf[:0], false
		if err != nil {
			break
		}
	}
	if fi.Size() > gcMaxBytes {
		return fmt.Sprintf("%s: larger than %d MiB, read the first %d MiB", label, gcMaxBytes>>20, gcMaxBytes>>20)
	}
	return ""
}

// gcReportTitle is the first failing criterion title in a ticket's eval-report.md ("" when none): the first table row
// whose cells hold a "fail" verdict.
func gcReportTitle(path string) string {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(io.LimitReader(f, gcReportMax))
	sc.Buffer(make([]byte, 0, 4096), gcMaxLine)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "|") {
			continue
		}
		var cells []string
		for _, c := range strings.Split(strings.Trim(line, "|"), "|") {
			cells = append(cells, strings.TrimSpace(strings.ReplaceAll(c, "*", "")))
		}
		failAt := -1
		for i, c := range cells {
			if strings.EqualFold(c, "fail") {
				failAt = i
				break
			}
		}
		if failAt < 0 {
			continue
		}
		for i, c := range cells {
			if i == failAt || c == "" {
				continue
			}
			if _, err := strconv.Atoi(c); err == nil {
				continue
			}
			return gcClean(c, gcCauseMax)
		}
	}
	return ""
}

// gcReviewerNo reports whether a ticket's review-notes.md carries verdict NO (first word under "## Verdict").
func gcReviewerNo(path string) bool {
	var on, no bool
	var un int
	gcLines(path, "", func(b []byte) {
		if no {
			return
		}
		t := strings.TrimSpace(string(b))
		if !on {
			on = strings.HasPrefix(t, gcKeys.VerdictHead)
			return
		}
		if first := strings.Fields(strings.ReplaceAll(t, "*", "")); len(first) > 0 {
			no = first[0] == gcKeys.NoVerdict
			on = false
		}
	}, &un)
	return no
}

func gateClusters(root, home string, days int, now time.Time) gcReport {
	rep := gcReport{Days: days, Clusters: []gcCluster{}, SeenOnce: []gcCluster{}, Errors: []string{}}
	cutoff := now.Add(-time.Duration(days) * 24 * time.Hour)
	var runs []gcRun
	tdir := filepath.Join(root, ".tickets")

	// 1. the run log: evaluator/reviewer runs with a failing outcome
	logLabel := "run log " + gcKeys.RunLog
	if e := gcLines(filepath.Join(root, filepath.FromSlash(gcKeys.RunLog)), logLabel, func(b []byte) {
		var m map[string]any
		if json.Unmarshal(b, &m) != nil {
			rep.Unreadable++
			return
		}
		str := func(k string) string { s, _ := m[k].(string); return s }
		outcome := str(gcKeys.RunOutcome)
		if !gcFailOutcomes[outcome] {
			return
		}
		at, err := time.Parse(time.RFC3339, str(gcKeys.RunTS))
		if err != nil || at.Before(cutoff) {
			return
		}
		role := strings.TrimPrefix(gcWord(str(gcKeys.RunType)), "canon-")
		cause := role + " " + outcome
		ticket := str(gcKeys.RunTicket)
		if !gcTicketRe.MatchString(ticket) {
			ticket = ""
		}
		example := cause
		if t := gcReportTitle(filepath.Join(tdir, ticket, gcKeys.EvalReport)); ticket != "" && t != "" && role == "evaluator" {
			cause += ": " + t
			example = cause
		}
		runs = append(runs, gcRun{cause, ticket, gcID(str(gcKeys.RunID)), gcClean(example+" "+ticket, gcExampleMax), at})
	}, &rep.Unreadable); e != "" {
		rep.Errors = append(rep.Errors, e)
	}

	// 2. the event day files: gate.rejected
	evDir := filepath.Join(home, "events")
	if home == "" {
		rep.Errors = append(rep.Errors, "events folder: no CANON_HOME and no home folder")
	} else if entries, err := os.ReadDir(evDir); err != nil {
		rep.Errors = append(rep.Errors, "events folder: missing")
	} else {
		var names []string
		for _, e := range entries {
			if gcDayRe.MatchString(e.Name()) {
				names = append(names, e.Name())
			}
		}
		sort.Sort(sort.Reverse(sort.StringSlice(names)))
		if len(names) > gcMaxFiles {
			names = names[:gcMaxFiles]
			rep.Errors = append(rep.Errors, fmt.Sprintf("events folder: more than %d day files, newest %d read", gcMaxFiles, gcMaxFiles))
		}
		for _, n := range names {
			if day, err := time.Parse("2006-01-02", strings.TrimSuffix(n, ".jsonl")); err == nil && day.Add(24*time.Hour).Before(cutoff) {
				continue
			}
			if e := gcLines(filepath.Join(evDir, n), "event file "+n, func(b []byte) {
				var m map[string]any
				if json.Unmarshal(b, &m) != nil {
					rep.Unreadable++
					return
				}
				if k, _ := m[gcKeys.EvKind].(string); k != gcKeys.EvRejected {
					return
				}
				ts, _ := m[gcKeys.EvTS].(string)
				at, err := time.Parse(time.RFC3339, ts)
				if err != nil || at.Before(cutoff) {
					return
				}
				d, _ := m[gcKeys.EvData].(map[string]any)
				str := func(k string) string { s, _ := d[k].(string); return s }
				ticket := str(gcKeys.EvTicket)
				if !gcTicketRe.MatchString(ticket) {
					ticket = ""
				}
				cause := "rejected " + gcWord(str(gcKeys.EvRole)) + " " + gcWord(str(gcKeys.EvReason))
				id, _ := m[gcKeys.EvID].(string)
				runs = append(runs, gcRun{cause, ticket, gcID(id), gcClean(cause+" "+ticket, gcExampleMax), at})
			}, &rep.Unreadable); e != "" {
				rep.Errors = append(rep.Errors, e)
			}
		}
	}

	// 3. reviewer NO in review-notes.md (the file's mtime is its date)
	if entries, err := os.ReadDir(tdir); err == nil {
		for _, e := range entries {
			if !gcTicketRe.MatchString(e.Name()) || !e.IsDir() {
				continue
			}
			p := filepath.Join(tdir, e.Name(), gcKeys.ReviewNotes)
			fi, err := os.Lstat(p)
			if err != nil || !fi.Mode().IsRegular() || fi.ModTime().Before(cutoff) {
				continue
			}
			if gcReviewerNo(p) {
				runs = append(runs, gcRun{"reviewer NO", e.Name(), "review:" + e.Name(), "reviewer NO " + e.Name(), fi.ModTime()})
			}
		}
	}

	// group by cause
	by := map[string]*gcCluster{}
	var order []string
	sort.SliceStable(runs, func(i, j int) bool { return runs[i].at.After(runs[j].at) }) // newest first: its example leads
	for _, r := range runs {
		c := by[r.cause]
		if c == nil {
			c = &gcCluster{Cause: r.cause, Example: r.example, Last: r.at.UTC().Format(time.RFC3339), Tickets: []string{}, Runs: []string{}}
			by[r.cause] = c
			order = append(order, r.cause)
		}
		c.Count++
		if r.id != "" {
			c.Runs = append(c.Runs, r.id)
		}
		if r.ticket != "" && !gcHas(c.Tickets, r.ticket) {
			c.Tickets = append(c.Tickets, r.ticket)
		}
	}
	for _, k := range order {
		if c := by[k]; c.Count >= 2 {
			rep.Clusters = append(rep.Clusters, *c)
		} else {
			rep.SeenOnce = append(rep.SeenOnce, *c)
		}
	}
	sortClusters := func(cs []gcCluster) {
		sort.SliceStable(cs, func(i, j int) bool {
			if cs[i].Count != cs[j].Count {
				return cs[i].Count > cs[j].Count
			}
			return cs[i].Last > cs[j].Last
		})
	}
	sortClusters(rep.Clusters)
	sortClusters(rep.SeenOnce)
	return rep
}

func gcHas(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

func gcCapped(s []string) string {
	if len(s) == 0 {
		return "-"
	}
	if len(s) <= gcMaxShown {
		return strings.Join(s, " ")
	}
	return fmt.Sprintf("%s +%d more", strings.Join(s[:gcMaxShown], " "), len(s)-gcMaxShown)
}

func gcText(r gcReport, w io.Writer) {
	for _, e := range r.Errors {
		fmt.Fprintln(w, "error:", e)
	}
	if r.Unreadable > 0 {
		fmt.Fprintf(w, "error: %d unreadable lines\n", r.Unreadable)
	}
	if len(r.Clusters) == 0 && len(r.SeenOnce) == 0 {
		fmt.Fprintf(w, "no gate failures in the last %d days\n", r.Days)
		return
	}
	one := func(c gcCluster) {
		fmt.Fprintf(w, "%d x %s\n  tickets: %s\n  runs: %s\n  e.g. %s\n", c.Count, c.Cause, gcCapped(c.Tickets), gcCapped(c.Runs), c.Example)
	}
	fmt.Fprintf(w, "gate failure clusters, last %d days\n", r.Days)
	if len(r.Clusters) == 0 {
		fmt.Fprintln(w, "no cause seen in 2 or more runs")
	}
	for _, c := range r.Clusters {
		one(c)
	}
	if len(r.SeenOnce) > 0 {
		fmt.Fprintln(w, "seen once (not a pattern):")
		for _, c := range r.SeenOnce {
			one(c)
		}
	}
}

func gateClustersCLI(args []string, stdout, stderr io.Writer) int {
	days, asJSON := gcDefaultDays, false
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			asJSON = true
		case a == "--days" && i+1 < len(args):
			n, err := strconv.Atoi(args[i+1])
			if err != nil || n < 1 || n > 3650 {
				fmt.Fprintln(stderr, "usage: sprint-check gate-clusters [--days N] [--json]")
				return 2
			}
			days = n
			i++
		default:
			fmt.Fprintln(stderr, "usage: sprint-check gate-clusters [--days N] [--json]")
			return 2
		}
	}
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(stderr, "sprint-check gate-clusters: cannot find the project:", err)
		return 1
	}
	rep := gateClusters(root, gcHome(), days, time.Now())
	if asJSON {
		b, _ := json.Marshal(rep)
		fmt.Fprintln(stdout, string(b))
		return 0
	}
	gcText(rep, stdout)
	return 0
}

func gcHome() string { return events.Home() }
