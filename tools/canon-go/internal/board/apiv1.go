// apiv1.go — t-0b89 slice 1: the read-only /api/v1 surface (sessions, ticket metadata, a sprint snapshot) and `canon api schema`.
// Reads are token-free on loopback like /api/cockpit-sessions: the Host check in handle() runs first, GET is the only method that
// does anything, and no response carries a CORS header, so a web page cannot read it. What it serves is chosen from allowlists (a
// ticket's metadata fields, an event line that passed the events schema), never filtered from something richer: ticket bodies are
// not served (they wait for t-e2c4's token). Every id is matched before a path or a lookup is built from it.
package board

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"

	"canon/internal/common"
	"canon/internal/events"
)

const apiV1Schema = 1

// v1FieldMax caps a served ticket string: a title is a line of text, and a hostile file must not make a 20 MB reply.
const v1FieldMax = 200

var v1TicketIDRe = regexp.MustCompile(`^t-[a-z0-9]{4}$`)

// v1Ticket is a ticket's served fields, in this order; the one list the handler, the schema and the tests share.
var v1Ticket = []string{"id", "title", "status", "type", "priority", "created", "closed"}

// v1EventKeys are an event line's served keys (the stream's envelope, t-15b5; the machine's host name is not served).
var v1EventKeys = []string{"schema", "id", "ts", "kind", "source", "project", "actor", "data"}

// v1SprintKinds are the lifecycle kinds the sprint snapshot keeps the latest of. Folding them into steps is t-5ef8's.
var v1SprintKinds = []string{"sprint.started", "plan.approved", "gate.started", "gate.finished", "gate.rejected", "close.confirmed", "sprint.completed"}

// v1Responses are each route's top-level keys: the published response schema.
var v1Responses = map[string][]string{
	"/api/v1/sessions":            {"schema", "sessions"},
	"/api/v1/sessions/{id}":       {"schema", "session"},
	"/api/v1/sessions/{id}/state": {"schema", "id", "state"},
	"/api/v1/tickets":             {"schema", "tickets"},
	"/api/v1/tickets/{id}":        {"schema", "ticket"},
	"/api/v1/sprint/{ticket}":     {"schema", "ticket", "events"},
}

// v1DaemonHeader says whether the daemon answered: a down daemon gives an empty list, which is not "no sessions".
func v1DaemonHeader(w http.ResponseWriter, up bool) {
	w.Header().Set("X-Cockpit-Daemon", map[bool]string{true: "up", false: "down"}[up])
}

func v1Error(w http.ResponseWriter, code int, msg string) {
	body, _ := json.Marshal(map[string]any{"schema": apiV1Schema, "error": msg})
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	w.Write(body)
}

func v1Send(w http.ResponseWriter, v map[string]any) {
	v["schema"] = apiV1Schema
	sendJSON(w, v)
}

// handleAPIv1 serves /api/v1/*. handle() has already passed the Host check. OPTIONS answers 204 with Allow and nothing else:
// no Access-Control-Allow-* header on any response, errors included.
func handleAPIv1(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Allow", "GET, OPTIONS")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodOptions:
		w.WriteHeader(http.StatusNoContent)
		return
	case http.MethodGet:
	default:
		v1Error(w, http.StatusMethodNotAllowed, "read only: GET")
		return
	}
	seg := strings.Split(strings.Trim(strings.TrimPrefix(strings.TrimRight(r.URL.Path, "/"), "/api/v1"), "/"), "/")
	switch {
	case len(seg) == 1 && seg[0] == "sessions":
		sessions, up := cockpitSessionsAnswer()
		v1DaemonHeader(w, up)
		v1Send(w, map[string]any{"sessions": sessions})
	case len(seg) >= 2 && len(seg) <= 3 && seg[0] == "sessions" && (len(seg) == 2 || seg[2] == "state"):
		if !common.SessionIDRe.MatchString(seg[1]) {
			v1Error(w, http.StatusBadRequest, "bad session id")
			return
		}
		sessions, up := cockpitSessionsAnswer()
		v1DaemonHeader(w, up)
		sessions = cockpitSessionsFor(sessions, seg[1], "")
		if len(seg) == 3 {
			state := "exited"
			if len(sessions) > 0 {
				if state, _ = sessions[0]["state"].(string); state == "" {
					state = "running"
				}
			}
			v1Send(w, map[string]any{"id": seg[1], "state": state})
			return
		}
		if len(sessions) == 0 {
			v1Error(w, http.StatusNotFound, "no such session")
			return
		}
		v1Send(w, map[string]any{"session": sessions[0]})
	case len(seg) == 1 && seg[0] == "tickets", len(seg) == 2 && seg[0] == "tickets":
		root, ok := effectiveRoot(r)
		if !ok {
			v1Error(w, http.StatusBadRequest, "unknown project")
			return
		}
		if len(seg) == 2 && !v1TicketIDRe.MatchString(seg[1]) {
			v1Error(w, http.StatusBadRequest, "bad ticket id")
			return
		}
		list := []map[string]any{}
		for _, t := range loadTickets(root) {
			if !v1TicketIDRe.MatchString(fmt.Sprint(t["id"])) { // the id is front-matter text: only a real ticket id is served
				continue
			}
			if len(seg) == 2 && fmt.Sprint(t["id"]) != seg[1] {
				continue
			}
			if len(seg) == 1 && fmt.Sprint(t["status"]) == "archived" {
				continue
			}
			list = append(list, v1TicketOf(t))
		}
		if len(seg) == 1 {
			v1Send(w, map[string]any{"tickets": list})
		} else if len(list) == 0 {
			v1Error(w, http.StatusNotFound, "no such ticket")
		} else {
			v1Send(w, map[string]any{"ticket": list[0]})
		}
	case len(seg) == 2 && seg[0] == "sprint":
		root, ok := effectiveRoot(r)
		if !ok {
			v1Error(w, http.StatusBadRequest, "unknown project")
			return
		}
		if !v1TicketIDRe.MatchString(seg[1]) {
			v1Error(w, http.StatusBadRequest, "bad ticket id")
			return
		}
		evs, ok := v1Sprint(events.Home(), root, seg[1])
		if !ok {
			w.Header().Set("Retry-After", "1")
			v1Error(w, http.StatusServiceUnavailable, "busy: try again")
			return
		}
		v1Send(w, map[string]any{"ticket": seg[1], "events": evs})
	default:
		v1Error(w, http.StatusNotFound, "no such route")
	}
}

// v1TicketOf copies only the served fields. A ticket map also holds its body and doc text; none of it can reach a response from here.
func v1TicketOf(t ticket) map[string]any {
	out := map[string]any{}
	for _, k := range v1Ticket {
		if v, ok := t[k]; ok {
			if str, isStr := v.(string); isStr && utf8.RuneCountInString(str) > v1FieldMax {
				v = string([]rune(str)[:v1FieldMax])
			}
			out[k] = v
		}
	}
	return out
}

// v1SprintGate bounds the day-file scans running at once: a scan reads up to the retained days, and the route needs no token.
var v1SprintGate = make(chan struct{}, 2)

var (
	v1SprintMu    sync.Mutex
	v1SprintCache = map[string][]map[string]any{} // root|ticket|day-file signature -> the answer; a changed file is a new key
)

// v1Signature names the day files as they are now (name, size, mtime), so an unchanged log is not scanned twice.
func v1Signature(files []string) string {
	var b strings.Builder
	for _, f := range files {
		if fi, err := os.Stat(f); err == nil {
			fmt.Fprintf(&b, "%s:%d:%d;", filepath.Base(f), fi.Size(), fi.ModTime().UnixNano())
		}
	}
	return b.String()
}

// v1Sprint is the latest valid event of each lifecycle kind for one ticket of one project, in log order. Lines that fail the events
// schema are skipped by the reader; the values are text from the log, served as data. ok is false when two scans are already running.
func v1Sprint(home, root, ticketID string) (out []map[string]any, ok bool) {
	root = resolvedOrAbs(root) // events carry the resolved path (emitEvent)
	files := events.DayFiles(home)
	key := root + "|" + ticketID + "|" + v1Signature(files)
	v1SprintMu.Lock()
	cached, hit := v1SprintCache[key]
	v1SprintMu.Unlock()
	if hit {
		return cached, true
	}
	select {
	case v1SprintGate <- struct{}{}:
		defer func() { <-v1SprintGate }()
	default:
		return nil, false
	}
	out = v1SprintScan(files, root, ticketID)
	v1SprintMu.Lock()
	if len(v1SprintCache) >= 128 {
		v1SprintCache = map[string][]map[string]any{}
	}
	v1SprintCache[key] = out
	v1SprintMu.Unlock()
	return out, true
}

func v1SprintScan(files []string, root, ticketID string) []map[string]any {
	live := map[string]bool{}
	for _, e := range registeredWorktrees(root) {
		live[resolvedOrAbs(fmt.Sprint(e["path"]))] = true
	}
	want := map[string]bool{}
	for _, k := range v1SprintKinds {
		want[k] = true
	}
	var days []string // newest first
	byDay := map[string][]string{}
	for _, path := range files {
		day := strings.TrimSuffix(filepath.Base(path), ".gz")
		if _, seen := byDay[day]; !seen {
			days = append(days, day)
		}
		byDay[day] = append(byDay[day], path) // a day with a .gz twin lists the .gz first
	}
	latest := map[string]events.Event{}
	order := map[string]string{} // kind -> "<day>/<line no>": log order across days
	for _, day := range days {   // a kind found in a later day needs no older one
		var inDay map[string]events.Event
		var pos map[string]string
		for _, path := range byDay[day] { // the twin holds the same lines; when the .gz cannot be read to its end, the plain file is the day
			inDay, pos = map[string]events.Event{}, map[string]string{}
			n := 0
			err := events.EachIn(path, func(ev events.Event) {
				n++
				if want[ev.Kind] && ev.Data["ticket"] == ticketID && belongsTo(ev.Project, root, live) {
					inDay[ev.Kind] = ev
					pos[ev.Kind] = fmt.Sprintf("%s/%09d", day, n)
				}
			})
			if err == nil {
				break
			}
		}
		for k, ev := range inDay {
			if _, have := latest[k]; !have {
				latest[k], order[k] = ev, pos[k]
			}
		}
		if len(latest) == len(want) {
			break
		}
	}
	kinds := make([]string, 0, len(latest))
	for k := range latest {
		kinds = append(kinds, k)
	}
	sort.Slice(kinds, func(i, j int) bool { return order[kinds[i]] < order[kinds[j]] })
	out := []map[string]any{}
	for _, k := range kinds {
		ev := latest[k]
		m := map[string]any{"schema": events.Schema, "id": ev.ID, "ts": ev.TS.Format("2006-01-02T15:04:05.000Z"), "kind": ev.Kind, "source": ev.Source, "project": ev.Project, "data": ev.Data}
		if ev.Actor != "" {
			m["actor"] = ev.Actor
		}
		out = append(out, m)
	}
	return out
}

// apiSchema is `canon api schema`: every event kind with its fields (from the events kinds table), the served ticket and event keys,
// and each route's response keys, from the same variables the handlers use.
func apiSchema() map[string]any {
	kinds := map[string]any{}
	for _, k := range events.Kinds() {
		kinds[k] = events.Fields(k)
	}
	return map[string]any{"schema": apiV1Schema, "events": map[string]any{"schema": events.Schema, "envelope": v1EventKeys, "kinds": kinds},
		"ticket": v1Ticket, "responses": v1Responses}
}

func apiCLI(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 || args[0] != "schema" || (len(args) == 2 && args[1] != "--json") || len(args) > 2 {
		fmt.Fprintln(stderr, "usage: canon-go api schema [--json]")
		return 2
	}
	b, _ := json.MarshalIndent(apiSchema(), "", "  ")
	fmt.Fprintln(stdout, string(b))
	return 0
}
