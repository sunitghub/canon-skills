// Package events is canon's event stream, schema v1 (t-f182): one JSON line per event in a dated file,
// $CANON_HOME/events/YYYY-MM-DD.jsonl (UTC). It is the only writer: the board calls Emit directly, and the shell tools
// (tkt, sprint) reach it through `sprint-check event`, because bash's `printf >>` tears lines longer than about 1 KB
// when several writers append at once (.tickets/t-f182/evidence/spike). Each event is one open, one O_APPEND write
// and one close, so no descriptor is ever held across midnight.
//
// Observer-only: emitting never blocks, delays or fails the change it describes. Callers emit after their own write
// succeeded and ignore the result; a failure is noted in events/emit-errors.log, best effort.
//
// v1 is additive-only from here on: t-0b89 (read API), t-4c09 (audit) and t-4381 read these fields.
package events

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"canon/internal/settings"
)

// Schema is the version every event carries.
const Schema = 1

type field struct {
	name string
	max  int // runes; a longer value is cut, never copied whole
}

// kinds is the v1 schema: each kind's data fields and their limits. Nothing outside this table is ever written.
var kinds = map[string][]field{
	"ticket.created":        {{"ticket", 64}, {"title", 200}, {"type", 16}, {"priority", 4}},
	"ticket.status_changed": {{"ticket", 64}, {"from", 32}, {"to", 32}},
	"ticket.closed":         {{"ticket", 64}},
	"sprint.started":        {{"ticket", 64}, {"gate_agents", 8}}, // t-ff14: ok | missing; absent when it could not tell
	"sprint.completed":      {{"ticket", 64}},
	// t-8854: close gates and Cockpit sessions
	"gate.started":      {{"ticket", 64}, {"role", 16}, {"attempt", 4}, {"docs", 12}},
	"gate.finished":     {{"ticket", 64}, {"role", 16}, {"verdict", 16}, {"model", 80}, {"tokens", 12}, {"minutes", 8}, {"tier", 16}, {"agent", 32}}, // t-ff14: agent = the transcript's agentType
	"gate.rejected":     {{"ticket", 64}, {"role", 16}, {"reason", 32}},
	"session.needs_you": {{"session", 64}, {"ticket", 64}, {"agent", 16}},
	"session.exited": {{"session", 64}, {"ticket", 64}, {"agent", 16}, {"reason", 16},
		{"models", 120}, {"peak_context_pct", 4}, {"tokens_new", 12}, {"turns", 6}},
	"session.saved": {{"session", 64}, {"ticket", 64}, {"agent", 16}, {"by", 16}},
	// t-4c09: audit kinds. Ids, numbers and names of non-secret settings only: a sealed day cannot be edited, and a
	// reader treats the log as untrusted input. No PR or issue title, no imported result text, no token or URL.
	"plan.approved":           {{"ticket", 64}, {"tier", 16}},
	"close.confirmed":         {{"ticket", 64}, {"tier", 16}},
	"github.sent":             {{"ticket", 64}, {"issue", 12}},
	"github.results_imported": {{"ticket", 64}, {"pr", 12}},
	"github.merged":           {{"ticket", 64}, {"pr", 12}},
	"github.synced":           {{"count", 8}},
	"setting.changed":         {{"name", 48}, {"old", 64}, {"new", 64}},
	"integrity.restored":      {{"item", 64}, {"count", 8}},
	"context.threshold":       {{"session", 64}, {"ticket", 64}, {"agent", 16}, {"pct", 4}},
	"log.pruned":              {{"from", 10}, {"to", 10}, {"files", 6}, {"last_seal", 64}},
	// t-5ef8: the sprint progress card. "Build" has no kind: it is the time after plan.approved and before the first
	// wrapup.gate_started. gate names are the Wrapup Gates table rows (code-simplifier, doc-audit, ...).
	"plan.written":         {{"ticket", 64}, {"tier", 16}},
	"wrapup.gate_started":  {{"ticket", 64}, {"gate", 32}},
	"wrapup.gate_finished": {{"ticket", 64}, {"gate", 32}, {"result", 16}},
	// t-57ab: the board's restricted terminal. "ticket" is the scratch id; no typed text, word or path is ever logged.
	"terminal.su_prompted": {{"session", 64}, {"ticket", 64}},
	"terminal.su_granted":  {{"session", 64}, {"ticket", 64}, {"minutes", 4}},
	"terminal.su_denied":   {{"session", 64}, {"ticket", 64}, {"reason", 16}},
	"terminal.su_expired":  {{"session", 64}, {"ticket", 64}, {"how", 16}},
	// t-0aa7: a tkt command that changes things, run in the Terminal without su. "sub" is the subcommand name only.
	"terminal.tkt": {{"session", 64}, {"ticket", 64}, {"sub", 32}},
}

// Sources are the programs that write events.
var sources = map[string]bool{"tkt": true, "sprint": true, "board": true, "gate-snapshot": true, "subagent-log": true, "daemon": true}

const projectMax = 1024

// Kinds lists the v1 kinds, sorted (docs and tests).
func Kinds() []string {
	out := make([]string, 0, len(kinds))
	for k := range kinds {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Home is canon's per-user folder: $CANON_HOME, else ~/.canon.
func Home() string {
	if h := os.Getenv("CANON_HOME"); h != "" {
		return h
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".canon")
	}
	return ""
}

// now is the event clock: CANON_EVENTS_CLOCK (RFC 3339, tests only) or the real time.
func now() time.Time {
	if c := os.Getenv("CANON_EVENTS_CLOCK"); c != "" {
		if t, err := time.Parse(time.RFC3339Nano, c); err == nil {
			return t.UTC()
		}
	}
	return time.Now().UTC()
}

// actors is who caused an event (t-15b5): a person at the board or CLI, an agent in a session, or canon itself (a timer, the reaper, a
// retention job). It is optional: absent from every line written before it existed and from an emitter that does not know it.
var actors = map[string]bool{"user": true, "agent": true, "system": true}

type line struct {
	Schema  int               `json:"schema"`
	ID      string            `json:"id"`
	TS      string            `json:"ts"`
	Kind    string            `json:"kind"`
	Source  string            `json:"source"`
	Actor   string            `json:"actor,omitempty"`
	Project string            `json:"project"`
	Data    map[string]string `json:"data"`
}

// Line builds one event line (no newline), refusing an unknown kind, source or field. Values are cut to their limit.
func Line(kind, source, project string, data map[string]string, at time.Time) ([]byte, error) {
	return LineActor(kind, source, "", project, data, at)
}

// LineActor is Line with the optional actor (t-15b5): "" leaves it out, anything but user, agent or system is refused.
func LineActor(kind, source, actor, project string, data map[string]string, at time.Time) ([]byte, error) {
	if actor != "" && !actors[actor] {
		return nil, fmt.Errorf("unknown event actor %q", actor)
	}
	fields, ok := kinds[kind]
	if !ok {
		return nil, fmt.Errorf("unknown event kind %q", kind)
	}
	if !sources[source] {
		return nil, fmt.Errorf("unknown event source %q", source)
	}
	allowed := map[string]int{}
	for _, f := range fields {
		allowed[f.name] = f.max
	}
	out := map[string]string{}
	for k, v := range data {
		max, ok := allowed[k]
		if !ok {
			return nil, fmt.Errorf("event %s has no field %q", kind, k)
		}
		out[k] = cut(v, max)
	}
	var id [8]byte
	if _, err := rand.Read(id[:]); err != nil {
		return nil, err
	}
	b, err := json.Marshal(line{Schema, hex.EncodeToString(id[:]), at.Format("2006-01-02T15:04:05.000Z"), kind, source, actor, cut(project, projectMax), out})
	if err != nil {
		return nil, err
	}
	return b, nil
}

// cut keeps at most max runes of valid UTF-8 (invalid bytes become U+FFFD, as json.Marshal would make them).
func cut(s string, max int) string {
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "�")
	}
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	r := []rune(s)
	return string(r[:max])
}

// Emit appends one event to home/events/<UTC day>.jsonl. The caller ignores the error (observer-only); Emit itself
// notes it in emit-errors.log.
func Emit(home, kind, source, project string, data map[string]string) error {
	return EmitActor(home, kind, source, "", project, data)
}

// EmitActor is Emit with the optional actor (t-15b5).
func EmitActor(home, kind, source, actor, project string, data map[string]string) error {
	err := emit(home, kind, source, actor, project, data)
	if err != nil {
		NoteFailure(home, err)
	}
	return err
}

func emit(home, kind, source, actor, project string, data map[string]string) error {
	if home == "" {
		return errors.New("no CANON_HOME and no home folder")
	}
	at := now()
	b, err := LineActor(kind, source, actor, project, data, at)
	if err != nil {
		return err
	}
	dir := filepath.Join(home, "events")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, at.Format("2006-01-02")+".jsonl")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	newDay := false
	if errors.Is(err, os.ErrNotExist) {
		f, err = os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE|os.O_EXCL, 0o600)
		newDay = err == nil
		if errors.Is(err, os.ErrExist) { // another writer made today's file first
			f, err = os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
		}
	}
	if err != nil {
		return err
	}
	_, werr := f.Write(append(b, '\n')) // one write: whole under concurrent appends
	cerr := f.Close()
	if newDay { // t-3137: seal closed days, gzip old ones, remove those past the retention setting
		if merr := Maintain(home, at, source); merr != nil && !errors.Is(merr, ErrBusy) {
			NoteFailure(home, merr)
		}
	}
	if werr != nil {
		return werr
	}
	return cerr
}

const errorsLogMax = 1 << 20

// NoteFailure appends one line to events/emit-errors.log, best effort; it stops growing at 1 MB.
func NoteFailure(home string, err error) {
	if home == "" {
		return
	}
	path := filepath.Join(home, "events", "emit-errors.log")
	if st, serr := os.Stat(path); serr == nil && st.Size() > errorsLogMax {
		return
	}
	f, ferr := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if ferr != nil {
		return
	}
	fmt.Fprintf(f, "%s %s\n", time.Now().UTC().Format(time.RFC3339), strings.ReplaceAll(err.Error(), "\n", " "))
	f.Close()
}

// Event is one line read back from the stream.
type Event struct {
	ID      string
	TS      time.Time
	Kind    string
	Source  string
	Project string
	Data    map[string]string
	Actor   string // t-15b5: "" when the line has none (every line written before it, or an emitter that does not know it)
}

// lineMax caps a line Latest will parse: a writer cuts every value, so a longer line was not written by Emit.
const lineMax = 64 << 10

// Latest is the newest event of kind for project (t-9641: Factory's "Last synced"), searching day files newest first
// within the retention setting (log.retention_days, 30 by default), or false. A day older than 7 days may be gzipped; it is read the same. Anyone who can append to the folder can write a line, so each one is checked against
// the v1 schema and skipped when it fails; only regular files named like a day file are read (no symlinks).
// valid, when not nil, is one more per-kind check on a line that passed the schema (t-f053): a line it rejects is skipped like
// any other invalid line, so it cannot hide an older valid one. A minimal reader until t-0b89's read API.
func Latest(home, kind, project string, valid func(Event) bool) (Event, bool) {
	if home == "" {
		return Event{}, false
	}
	dir := filepath.Join(home, "events")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return Event{}, false
	}
	var days []string
	for _, e := range entries {
		if m := dayAnyRe.FindStringSubmatch(e.Name()); m != nil && e.Type().IsRegular() {
			days = append(days, e.Name())
		}
	}
	// newest day first; a plain file sorts before its .gz twin, which is only left behind by a crashed gzip
	sort.Slice(days, func(i, j int) bool { return days[i] > days[j] })
	if keep := settings.RetentionDays(home) + 1; len(days) > keep {
		days = days[:keep]
	}
	for _, name := range days {
		if ev, ok := latestIn(filepath.Join(dir, name), kind, project, valid); ok {
			return ev, true
		}
	}
	return Event{}, false
}

// latestIn is the last valid matching line of one day file (append order). An over-long line is skipped whole.
func latestIn(path, kind, project string, valid func(Event) bool) (Event, bool) {
	f, err := openDay(path)
	if err != nil {
		return Event{}, false
	}
	defer f.Close()
	var found Event
	ok := false
	r := bufio.NewReaderSize(f, 4096)
	var buf []byte
	long := false
	for {
		chunk, err := r.ReadSlice('\n')
		if !long && len(buf)+len(chunk) <= lineMax {
			buf = append(buf, chunk...)
		} else {
			long, buf = true, buf[:0]
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if !long {
			if ev, good := parseLine(buf, kind, project); good && (valid == nil || valid(ev)) {
				found, ok = ev, true
			}
		}
		buf, long = buf[:0], false
		if err != nil {
			return found, ok
		}
	}
}

// parseLine checks one line against the v1 schema: known kind and source, only that kind's fields within their limits,
// a parseable ts, and the wanted kind and project.
func parseLine(b []byte, kind, project string) (Event, bool) {
	var l struct {
		Schema  json.RawMessage   `json:"schema"`
		ID      string            `json:"id"`
		TS      string            `json:"ts"`
		Kind    string            `json:"kind"`
		Source  string            `json:"source"`
		Actor   string            `json:"actor"`
		Project string            `json:"project"`
		Data    map[string]string `json:"data"`
	}
	if json.Unmarshal(b, &l) != nil || (l.Actor != "" && !actors[l.Actor]) || string(l.Schema) != "1" || l.Kind != kind || l.Project != project || !sources[l.Source] {
		return Event{}, false
	}
	fields, known := kinds[l.Kind]
	if !known || len(l.ID) != 16 {
		return Event{}, false
	}
	for k, v := range l.Data {
		allowed := false
		for _, f := range fields {
			if f.name == k && utf8.RuneCountInString(v) <= f.max {
				allowed = true
			}
		}
		if !allowed {
			return Event{}, false
		}
	}
	ts, err := time.Parse(time.RFC3339Nano, l.TS)
	if err != nil {
		return Event{}, false
	}
	return Event{l.ID, ts.UTC(), l.Kind, l.Source, l.Project, l.Data, l.Actor}, true
}
