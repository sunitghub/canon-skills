package board

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"canon/internal/events"
)

// /api/v1/events and /api/v1/events/stream (t-8d45, slice 2 of t-0b89): the activity log, read only. The file format, the cursor and every
// read of a day file belong to internal/events; this file is HTTP only: it turns a request into a cursor and a scope and writes what the
// reader returns, so there is no second parser and no path built from a request.

const (
	v1EventsDefaultLimit = 100
	v1EventsMaxLimit     = 500
	v1StreamMax          = 4 // streams at once: the route needs no token, and each stream holds a connection and a poll
)

// The stream's timings are variables so a test can lower them.
var (
	v1StreamPoll      = 500 * time.Millisecond // the day file is polled (no file-watching dependency)
	v1StreamKeepAlive = 15 * time.Second       // an idle stream writes a comment, so a dead client is found and a proxy does not close it
	v1StreamLifetime  = 15 * time.Minute       // a stream ends after this; the client resumes from its last id
	v1StreamWrite     = 10 * time.Second       // one write may take this long: a stalled client must not hold a slot
	v1StreamBatch     = 100                    // events read per poll
	v1StreamSlots     = make(v1Slots, v1StreamMax)
)

var v1LimitRe = regexp.MustCompile(`^[0-9]{1,9}$`) // digits only; the value, not the string length, is what is ranged below

// v1Streams publishes each stream route's frame, from the same values the handler uses (`canon-go api schema`).
var v1Streams = map[string]map[string]any{
	"/api/v1/events/stream": {
		"content_type": "text/event-stream",
		"frame":        "id: <cursor after the event>, data: <the event as in v1EventKeys, one JSON line>",
		"resume":       "the Last-Event-ID header, or ?cursor= (opaque: only what a snapshot or an id returned); neither starts at the end of the log",
		"keep_alive":   fmt.Sprintf(": keep-alive comment after every %d s without an event", int(v1StreamKeepAlive/time.Second)),
		"max_streams":  v1StreamMax,
		"lifetime_s":   int(v1StreamLifetime / time.Second),
	},
}

// v1EventsSnapshot is GET /api/v1/events[?limit=N]: the newest limit events of the project, oldest first, and the cursor to subscribe from.
func v1EventsSnapshot(w http.ResponseWriter, r *http.Request) {
	root, ok := effectiveRoot(r)
	if !ok {
		v1Error(w, http.StatusBadRequest, "unknown project")
		return
	}
	limit := v1EventsDefaultLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if !v1LimitRe.MatchString(raw) || err != nil || n < 1 || n > v1EventsMaxLimit {
			v1Error(w, http.StatusBadRequest, "bad limit")
			return
		}
		limit = n
	}
	if !v1ScanGate.acquire() {
		w.Header().Set("Retry-After", "1")
		v1Error(w, http.StatusServiceUnavailable, "busy: try again")
		return
	}
	defer v1ScanGate.release()
	inScope := v1Scope(resolvedOrAbs(root)) // events carry the resolved path (emitEvent)
	got, end, err := events.Newest(events.Home(), limit, func(ev events.Event) bool { return inScope(ev.Project) })
	if err != nil {
		v1Error(w, http.StatusInternalServerError, "cannot read the event log")
		return
	}
	list := make([]map[string]any, 0, len(got))
	for _, p := range got {
		list = append(list, v1EventOf(p.Event))
	}
	cursor := ""
	if end != (events.Cursor{}) {
		cursor = end.String()
	}
	v1Send(w, map[string]any{"events": list, "cursor": cursor})
}

// v1StartCursor is where a stream begins: the cursor the client sent (Last-Event-ID first, then ?cursor=), checked against the readable day
// files before anything is read, else the end of the log as it is now.
func v1StartCursor(r *http.Request) (events.Cursor, error) {
	raw := r.Header.Get("Last-Event-ID")
	if raw == "" {
		raw = r.URL.Query().Get("cursor")
	}
	if raw == "" {
		return events.End(events.Home())
	}
	c, err := events.ParseCursor(raw)
	if err == nil {
		err = events.CheckCursor(events.Home(), c)
	}
	return c, err
}

// v1EventsStream is GET /api/v1/events/stream: server-sent events from a cursor, each id the cursor after its event, so a client that drops and
// resumes from its last id gets every event it missed once.
func v1EventsStream(w http.ResponseWriter, r *http.Request) {
	root, ok := effectiveRoot(r)
	if !ok {
		v1Error(w, http.StatusBadRequest, "unknown project")
		return
	}
	cur, err := v1StartCursor(r)
	if errors.Is(err, events.ErrBadCursor) {
		v1Error(w, http.StatusBadRequest, err.Error())
		return
	}
	if err != nil {
		v1Error(w, http.StatusInternalServerError, "cannot read the event log")
		return
	}
	if !v1StreamSlots.acquire() {
		w.Header().Set("Retry-After", "5")
		v1Error(w, http.StatusServiceUnavailable, "too many streams: try again")
		return
	}
	defer v1StreamSlots.release()
	rc := http.NewResponseController(w)
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	send := func(frame string) bool {
		rc.SetWriteDeadline(time.Now().Add(v1StreamWrite))
		if _, err := fmt.Fprint(w, frame); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	if !send("retry: 3000\n\n") {
		return
	}
	inScope := v1Scope(resolvedOrAbs(root))
	tick := time.NewTicker(v1StreamPoll)
	defer tick.Stop()
	end := time.NewTimer(v1StreamLifetime)
	defer end.Stop()
	lastWrite := time.Now()
	for {
		got, next, err := events.ReadSince(events.Home(), cur, v1StreamBatch)
		if err != nil { // the day was removed or the log became unreadable: end the stream, the client resumes or snapshots
			return
		}
		for _, p := range got {
			if !inScope(p.Project) {
				continue
			}
			b, _ := json.Marshal(v1EventOf(p.Event))
			if !send("id: " + p.Next.String() + "\ndata: " + string(b) + "\n\n") {
				return
			}
			lastWrite = time.Now()
		}
		cur = next
		if len(got) == v1StreamBatch {
			continue // more is waiting: read it before sleeping
		}
		if time.Since(lastWrite) >= v1StreamKeepAlive {
			if !send(": keep-alive\n\n") {
				return
			}
			lastWrite = time.Now()
		}
		select {
		case <-r.Context().Done():
			return
		case <-end.C:
			return
		case <-tick.C:
		}
	}
}
