package board

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"canon/internal/events"
)

// canon-go gate-insights (t-9113 stage 1): are the close gates earning their cost? Counts and sums over the activity log, per project and
// per machine (a Mac and a VM are never added together). Read-only and local: nothing is written and nothing leaves the machine. Every
// line of the log is untrusted (anyone who can append to the folder can write one), so the report says "recorded", never "verified", and
// prints only ids, numbers and the words of a fixed list, capped (gcClean).

const giDefaultDays = 30

var giNow = time.Now // the CLI's clock; a test sets it so a seeded log stays inside the window

type giKey struct{ Project, Host string }

type giRun struct {
	Role    string  `json:"role"`
	Model   string  `json:"model"`
	Runs    int     `json:"runs"`
	Minutes float64 `json:"minutes"`
	Tokens  int64   `json:"tokens"`
}

type giGroup struct {
	Project string `json:"project"`
	Host    string `json:"host"`

	Runs []giRun `json:"runs"`

	EvalTickets   int `json:"evaluator_tickets"`    // tickets with a recorded evaluator verdict
	EvalFirstPass int `json:"evaluator_first_pass"` // of those, whose first verdict was pass
	EvalRetries   int `json:"evaluator_retries"`    // recorded evaluator verdicts beyond each ticket's first

	Reviewer giReviewer     `json:"reviewer"`
	Evidence giEvidence     `json:"evidence"`
	Rejected map[string]int `json:"rejected"`

	BudgetExceededFileDays int `json:"budget_exceeded_file_days"`
	BudgetExceededEvents   int `json:"budget_exceeded_events"`
}

type giReviewer struct {
	Yes           int `json:"yes"`
	No            int `json:"no"`
	Unknown       int `json:"no_verdict"`
	ActOnRecorded int `json:"act_on_runs_recorded"` // reviewer runs whose event carries act_on
	ActOn         int `json:"act_on_total"`
}

type giEvidence struct {
	Stamps  int `json:"stamps"`
	Reruns  int `json:"reruns"` // stamps of the same ticket and name beyond the first
	Failing int `json:"failing"`
	Seconds int `json:"seconds"`
}

type giReport struct {
	Days       int            `json:"days"`
	Window     string         `json:"window"`
	DaysRead   int            `json:"days_read"`
	DaysSealed map[string]int `json:"days_by_seal"` // Verify's word for each day read: intact, unsealed, broken, or not checked
	Events     int            `json:"events"`
	Groups     []giGroup      `json:"groups"`
}

type giWork struct {
	g          *giGroup
	runs       map[[2]string]*giRun
	evalSeq    map[string]int // ticket -> recorded evaluator verdicts so far
	stampSeq   map[[2]string]int
	budgetDays map[[2]string]bool
}

func gateInsights(home string, days int, now time.Time) giReport {
	rep := giReport{Days: days, DaysSealed: map[string]int{}, Groups: []giGroup{}}
	cutoff := now.UTC().Add(-time.Duration(days) * 24 * time.Hour)
	rep.Window = cutoff.Format("2006-01-02") + " to " + now.UTC().Format("2006-01-02")
	verdicts, notChecked := map[string]string{}, false
	if res, _ := events.Verify(home, now); res != nil {
		for _, r := range res {
			verdicts[r.Day] = r.Result
			if r.Day == "seals.jsonl" { // the seals could not be read or another run holds the log: no day has a verdict
				notChecked = true
			}
		}
	}
	work := map[giKey]*giWork{}
	get := func(e events.Event) *giWork {
		k := giKey{gcClean(e.Project, 120), gcClean(e.Host, 64)}
		w := work[k]
		if w == nil {
			w = &giWork{g: &giGroup{Project: k.Project, Host: k.Host, Rejected: map[string]int{}}, runs: map[[2]string]*giRun{},
				evalSeq: map[string]int{}, stampSeq: map[[2]string]int{}, budgetDays: map[[2]string]bool{}}
			work[k] = w
		}
		return w
	}
	files := events.DayFiles(home)
	for i := len(files) - 1; i >= 0; i-- { // oldest day first, so a ticket's runs are in the order they happened
		day := dayOf(files[i])
		read := false
		_ = events.EachIn(files[i], func(e events.Event) {
			if e.TS.Before(cutoff) {
				return
			}
			read = true
			switch e.Kind {
			case "gate.finished", "evidence.stamped", "gate.rejected", "budget.exceeded":
			default:
				return // every other kind is none of this report's business: no empty group for it
			}
			rep.Events++
			w := get(e)
			t := gcClean(e.Data["ticket"], 64)
			switch e.Kind {
			case "gate.finished":
				role, model := gcClean(e.Data["role"], 16), gcClean(e.Data["model"], 80)
				r := w.runs[[2]string{role, model}]
				if r == nil {
					r = &giRun{Role: role, Model: model}
					w.runs[[2]string{role, model}] = r
				}
				r.Runs++
				if m, err := strconv.ParseFloat(e.Data["minutes"], 64); err == nil && m >= 0 {
					r.Minutes += m
				}
				if n, err := strconv.ParseInt(e.Data["tokens"], 10, 64); err == nil && n >= 0 {
					r.Tokens += n
				}
				v := e.Data["verdict"]
				switch role {
				case "evaluator":
					if v == "pass" || v == "fail" || v == "partial" || v == "not-run" {
						if w.evalSeq[t] == 0 {
							w.g.EvalTickets++
							if v == "pass" {
								w.g.EvalFirstPass++
							}
						} else {
							w.g.EvalRetries++
						}
						w.evalSeq[t]++
					}
				case "reviewer":
					switch v {
					case "YES":
						w.g.Reviewer.Yes++
					case "NO":
						w.g.Reviewer.No++
					default:
						w.g.Reviewer.Unknown++
					}
					if n, err := strconv.Atoi(e.Data["act_on"]); err == nil && n >= 0 {
						w.g.Reviewer.ActOnRecorded++
						w.g.Reviewer.ActOn += n
					}
				}
			case "evidence.stamped":
				name := gcClean(e.Data["name"], 32)
				w.g.Evidence.Stamps++
				if w.stampSeq[[2]string{t, name}] > 0 {
					w.g.Evidence.Reruns++
				}
				w.stampSeq[[2]string{t, name}]++
				if e.Data["exit"] != "0" {
					w.g.Evidence.Failing++
				}
				if s, err := strconv.Atoi(e.Data["seconds"]); err == nil && s >= 0 {
					w.g.Evidence.Seconds += s
				}
			case "gate.rejected":
				w.g.Rejected[gcClean(e.Data["role"], 16)+" "+gcClean(e.Data["reason"], 32)]++
			case "budget.exceeded": // check-evidence writes one per run for an over-cap file: count it once per file per day
				w.g.BudgetExceededEvents++
				k := [2]string{day, gcClean(e.Data["cap"], 48)}
				if !w.budgetDays[k] {
					w.budgetDays[k] = true
					w.g.BudgetExceededFileDays++
				}
			}
		})
		if read {
			rep.DaysRead++
			res := verdicts[day]
			if notChecked {
				res = "not checked"
			} else if res == "" {
				res = "unsealed"
			}
			rep.DaysSealed[res]++
		}
	}
	for _, w := range work {
		for _, r := range w.runs {
			w.g.Runs = append(w.g.Runs, *r)
		}
		sort.Slice(w.g.Runs, func(i, j int) bool {
			a, b := w.g.Runs[i], w.g.Runs[j]
			if a.Role != b.Role {
				return a.Role < b.Role
			}
			return a.Model < b.Model
		})
		rep.Groups = append(rep.Groups, *w.g)
	}
	sort.Slice(rep.Groups, func(i, j int) bool {
		a, b := rep.Groups[i], rep.Groups[j]
		if a.Project != b.Project {
			return a.Project < b.Project
		}
		return a.Host < b.Host
	})
	return rep
}

// dayOf is the YYYY-MM-DD of a day file's name (plain or gzipped).
func dayOf(path string) string {
	b := filepath.Base(path)
	if len(b) >= 10 {
		return b[:10]
	}
	return b
}

func giText(r giReport, w io.Writer) {
	fmt.Fprintf(w, "gate insights, last %d days (%s): as recorded in the activity log\n", r.Days, r.Window)
	if r.Events == 0 {
		fmt.Fprintln(w, "no events in this window")
		return
	}
	var seal []string
	for _, k := range []string{"intact", "unsealed", "broken", "not checked"} {
		if n := r.DaysSealed[k]; n > 0 {
			seal = append(seal, fmt.Sprintf("%d %s", n, k))
		}
	}
	fmt.Fprintf(w, "days read: %d (%s); events: %d\n", r.DaysRead, strings.Join(seal, ", "), r.Events)
	for _, g := range r.Groups {
		host := g.Host
		if host == "" {
			host = "(no host recorded)"
		}
		fmt.Fprintf(w, "\n%s on %s\n", g.Project, host)
		for _, x := range g.Runs {
			fmt.Fprintf(w, "  %-9s %-24s %3d runs  %6.1f min  %9d tokens\n", x.Role, x.Model, x.Runs, x.Minutes, x.Tokens)
		}
		if g.EvalTickets > 0 {
			fmt.Fprintf(w, "  evaluator first pass: %d of %d tickets (%d%%); retries: %d\n", g.EvalFirstPass, g.EvalTickets, g.EvalFirstPass*100/g.EvalTickets, g.EvalRetries)
		}
		if n := g.Reviewer.Yes + g.Reviewer.No + g.Reviewer.Unknown; n > 0 {
			act := "act_on: not recorded"
			if g.Reviewer.ActOnRecorded > 0 {
				act = fmt.Sprintf("act_on items: %d (recorded on %d of %d runs)", g.Reviewer.ActOn, g.Reviewer.ActOnRecorded, n)
			}
			fmt.Fprintf(w, "  reviewer: YES %d, NO %d, no verdict %d; %s\n", g.Reviewer.Yes, g.Reviewer.No, g.Reviewer.Unknown, act)
		}
		if g.Evidence.Stamps > 0 {
			fmt.Fprintf(w, "  evidence stamps: %d (%d reruns, %d failing), %d s\n", g.Evidence.Stamps, g.Evidence.Reruns, g.Evidence.Failing, g.Evidence.Seconds)
		}
		var rej []string
		for k := range g.Rejected {
			rej = append(rej, k)
		}
		sort.Strings(rej)
		for _, k := range rej {
			fmt.Fprintf(w, "  rejected %s: %d\n", k, g.Rejected[k])
		}
		if g.BudgetExceededEvents > 0 {
			fmt.Fprintf(w, "  budget exceeded: %d file-days (%d events)\n", g.BudgetExceededFileDays, g.BudgetExceededEvents)
		}
	}
}

func gateInsightsCLI(args []string, stdout, stderr io.Writer) int {
	days, asJSON := giDefaultDays, false
	usage := "usage: canon-go gate-insights [--days N] [--json]"
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			asJSON = true
		case a == "--days" && i+1 < len(args):
			n, err := strconv.Atoi(args[i+1])
			if err != nil || n < 1 || n > 3650 {
				fmt.Fprintln(stderr, usage)
				return 2
			}
			days = n
			i++
		default:
			fmt.Fprintln(stderr, usage)
			return 2
		}
	}
	home := events.Home()
	if _, err := os.Stat(home); err != nil && !os.IsNotExist(err) {
		fmt.Fprintln(stderr, "gate-insights: cannot read the canon home:", err)
		return 1
	}
	rep := gateInsights(home, days, giNow())
	if asJSON {
		b, _ := json.Marshal(rep)
		fmt.Fprintln(stdout, string(b))
		return 0
	}
	giText(rep, stdout)
	return 0
}
