// machine.go — t-c542: which machines worked on a ticket. Facts come from internal/machine (the one reader); the board
// writes machine.seen at start, `canon-go machine` prints the one-line form for evidence headers, and
// /api/ticket-machines joins a ticket's events (each line's host) with each host's newest machine.seen, plus the OS line
// in the ticket's evidence headers, which is how a cloud session's machine arrives (tkt import-results, evidence/cloud/).
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
	"strings"
	"sync"
	"time"

	"canon/internal/events"
	"canon/internal/machine"
)

// machineCLI is `canon-go machine [--json]`: the one-line form (no hostname, t-a83a) or the facts as JSON without the host.
func machineCLI(args []string, stdout, stderr io.Writer) int {
	f := machine.Get()
	switch {
	case len(args) == 0:
		fmt.Fprintln(stdout, f.Line())
	case len(args) == 1 && args[0] == "--json":
		f.Host = ""
		b, _ := json.Marshal(f)
		fmt.Fprintln(stdout, strings.Replace(string(b), `"host":"",`, "", 1))
	default:
		fmt.Fprintln(stderr, "usage: canon-go machine [--json]")
		return 2
	}
	return 0
}

// factsData is the machine.seen data for f.
func factsData(f machine.Facts) map[string]string {
	return map[string]string{"host": f.Host, "os": f.OS, "os_name": f.OSName, "os_version": f.OSVersion, "kernel": f.Kernel,
		"arch": f.Arch, "cpus": f.CPUs, "ram_gb": f.RAMGB}
}

// noteMachineSeen writes machine.seen when this host's facts differ from its newest one, or it has none (a restart on an
// unchanged machine writes nothing). Observer-only, like every event.
func noteMachineSeen(home string) bool { return noteMachineSeenFor(home, machine.Get()) }

func noteMachineSeenFor(home string, f machine.Facts) bool {
	want := events.Fit("machine.seen", factsData(f))
	last, ok := events.Latest(home, "machine.seen", "", func(e events.Event) bool { return e.Data["host"] == f.Host })
	if ok && sameData(last.Data, want) {
		return false
	}
	events.Emit(home, "machine.seen", "board", "", want)
	return true
}

// factsOf reads machine.seen data back into Facts, so its Line is the same text evidence headers and Admin show.
func factsOf(d map[string]string) machine.Facts {
	return machine.Facts{Host: d["host"], OS: d["os"], OSName: d["os_name"], OSVersion: d["os_version"], Kernel: d["kernel"],
		Arch: d["arch"], CPUs: d["cpus"], RAMGB: d["ram_gb"]}
}

func sameData(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range b {
		if a[k] != v {
			return false
		}
	}
	return true
}

// ticketMachine is one row of the ticket's Machines node.
type ticketMachine struct {
	Where  string            `json:"where"`           // local | cloud
	Source string            `json:"source"`          // events | evidence
	Host   string            `json:"host,omitempty"`  // events only; evidence headers never name the host
	Facts  map[string]string `json:"facts,omitempty"` // the host's newest machine.seen; absent when none was written
	Line   string            `json:"line,omitempty"`  // the machine in one line: machine.Facts.Line, or an evidence header's text
	Count  int               `json:"count"`           // events, or evidence logs
	First  string            `json:"first,omitempty"` // RFC 3339
	Last   string            `json:"last,omitempty"`  // RFC 3339
}

// dayIndex is what one day file says, parsed once per (size, mtime).
type dayIndex struct {
	size  int64
	mtime time.Time
	runs  map[string]map[string]*ticketMachine // "<project>\x00<ticket>" -> host -> row
	seen  map[string]events.Event              // host -> newest machine.seen that day
}

var (
	dayIdxMu sync.Mutex
	dayIdx   = map[string]*dayIndex{}
)

func indexDay(path string) *dayIndex {
	st, err := os.Stat(path)
	if err != nil {
		return nil
	}
	dayIdxMu.Lock()
	defer dayIdxMu.Unlock()
	if d := dayIdx[path]; d != nil && d.size == st.Size() && d.mtime.Equal(st.ModTime()) {
		return d
	}
	d := &dayIndex{size: st.Size(), mtime: st.ModTime(), runs: map[string]map[string]*ticketMachine{}, seen: map[string]events.Event{}}
	events.EachIn(path, func(ev events.Event) {
		if ev.Kind == "machine.seen" {
			d.seen[ev.Data["host"]] = ev
			return
		}
		id := ev.Data["ticket"]
		if id == "" || ev.Host == "" {
			return
		}
		k := ev.Project + "\x00" + id
		if d.runs[k] == nil {
			d.runs[k] = map[string]*ticketMachine{}
		}
		at := ev.TS.Format(time.RFC3339)
		r := d.runs[k][ev.Host]
		if r == nil {
			r = &ticketMachine{Where: "local", Source: "events", Host: ev.Host, First: at}
			d.runs[k][ev.Host] = r
		}
		r.Count++
		r.Last = at
	})
	dayIdx[path] = d
	return d
}

// belongsTo: an event's project is this root, one of its live worktrees, or a folder in the board's worktree folder
// (<root>-worktrees/, createWorktree), so a worktree removed after its sprint still counts.
func belongsTo(project, root string, live map[string]bool) bool {
	if project == root || live[project] {
		return true
	}
	return filepath.Dir(project) == filepath.Join(filepath.Dir(root), filepath.Base(root)+"-worktrees")
}

// machinesTicketRe is a ticket id the route accepts: t- and up to 62 lowercase letters, digits or dashes (events cut ticket at 64),
// so it can never name a path outside the ticket folder.
var machinesTicketRe = regexp.MustCompile(`^t-[a-z0-9][a-z0-9-]{0,61}$`)

// evidenceHeaderRe reads the third line evidence.sh stamp writes: "# on <machine>; bash <version>".
var evidenceHeaderRe = regexp.MustCompile(`^# on (.+); bash [0-9.]+\s*$`)

// evidenceMachines reads the machine line of every log under the ticket's evidence folder (history/ included), grouped by
// line; a log under evidence/cloud/ came from a cloud session. Only *.log files, at most 3 lines each.
func evidenceMachines(dir string) []ticketMachine {
	by := map[string]*ticketMachine{}
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".log") || !d.Type().IsRegular() {
			return nil
		}
		f, err := os.Open(p)
		if err != nil {
			return nil
		}
		defer f.Close()
		sc := bufio.NewScanner(io.LimitReader(f, 8192))
		var line string
		for i := 0; i < 3 && sc.Scan(); i++ {
			line = sc.Text()
		}
		m := evidenceHeaderRe.FindStringSubmatch(line)
		if m == nil {
			return nil
		}
		where := "local"
		if rel, _ := filepath.Rel(dir, p); strings.HasPrefix(filepath.ToSlash(rel), "cloud/") {
			where = "cloud"
		}
		k := where + "\x00" + m[1]
		r := by[k]
		if r == nil {
			r = &ticketMachine{Where: where, Source: "evidence", Line: m[1]}
			by[k] = r
		}
		r.Count++
		if fi, err := d.Info(); err == nil {
			at := fi.ModTime().UTC().Format(time.RFC3339)
			if r.First == "" || at < r.First {
				r.First = at
			}
			if at > r.Last {
				r.Last = at
			}
		}
		return nil
	})
	out := make([]ticketMachine, 0, len(by))
	for _, r := range by {
		out = append(out, *r)
	}
	return out
}

// ticketMachines is the Machines node: one row per host from the ticket's events in this project (with its newest
// machine.seen), then every cloud machine from the evidence headers, then the local evidence machines only when no event
// named a host (a ticket worked before hosts were recorded). Newest last-seen first within each group.
func ticketMachines(home, root, evidenceDir, id string) []ticketMachine {
	live := map[string]bool{}
	for _, e := range registeredWorktrees(root) {
		live[resolvedOrAbs(fmt.Sprint(e["path"]))] = true
	}
	hosts := map[string]*ticketMachine{}
	seen := map[string]events.Event{}
	days := events.DayFiles(home)
	read := map[string]bool{}             // a day with a .gz twin (a crashed gzip) is listed twice, same lines: read it once
	for i := len(days) - 1; i >= 0; i-- { // oldest first, so a newer machine.seen replaces an older one
		day := strings.TrimSuffix(filepath.Base(days[i]), ".gz")
		if read[day] {
			continue
		}
		read[day] = true
		d := indexDay(days[i])
		if d == nil {
			continue
		}
		for h, ev := range d.seen {
			seen[h] = ev
		}
		for k, rows := range d.runs {
			project, tid, _ := strings.Cut(k, "\x00")
			if tid != id || !belongsTo(project, root, live) {
				continue
			}
			for h, r := range rows {
				cur := hosts[h]
				if cur == nil {
					c := *r
					hosts[h] = &c
					continue
				}
				cur.Count += r.Count
				if r.First < cur.First {
					cur.First = r.First
				}
				if r.Last > cur.Last {
					cur.Last = r.Last
				}
			}
		}
	}
	var out []ticketMachine
	for h, r := range hosts {
		if ev, ok := seen[h]; ok {
			r.Facts, r.Line = ev.Data, factsOf(ev.Data).Line()
		}
		out = append(out, *r)
	}
	byLast := func(s []ticketMachine) { sort.Slice(s, func(i, j int) bool { return s[i].Last > s[j].Last }) }
	byLast(out)
	ev := evidenceMachines(evidenceDir)
	byLast(ev)
	for _, r := range ev {
		if r.Where == "cloud" || len(hosts) == 0 {
			out = append(out, r)
		}
	}
	if out == nil {
		out = []ticketMachine{}
	}
	return out
}
