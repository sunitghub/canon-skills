package daemon

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	"canon/internal/events"
)

// t-a4f8: when a Terminal's full shell (su) ends, so the Agents list can count it down. The Terminal process already writes
// terminal.su_granted (session, minutes) and terminal.su_expired to the audit log; this reads them, so there is no new file or
// channel. The two newest day files cover a grant just before midnight UTC. The answer is cached on each file's size and mtime,
// so the 5 s sessions poll reads nothing unless the log grew.
var suCache struct {
	mu    sync.Mutex
	key   string
	until map[string]time.Time
}

// suUntilMax bounds the minutes a line may claim: the default is ten, and a line is untrusted input.
const suUntilMax = 24 * 60

// suUntil is session id -> the end of its current full shell, for the sessions whose latest granted has no later expired and whose
// end is still ahead of now. A Terminal that crashed leaves a granted line with no expired: its end passes and it drops out.
func suUntil(now time.Time) map[string]time.Time {
	days := events.DayFiles(events.Home())
	if len(days) > 2 {
		days = days[:2]
	}
	key := ""
	for _, p := range days {
		if fi, err := os.Stat(p); err == nil {
			key += fmt.Sprintf("%s|%d|%d;", p, fi.Size(), fi.ModTime().UnixNano())
		}
	}
	suCache.mu.Lock()
	defer suCache.mu.Unlock()
	if suCache.until == nil || suCache.key != key {
		m := map[string]time.Time{}
		for i := len(days) - 1; i >= 0; i-- { // oldest first: a later line wins
			_ = events.EachIn(days[i], func(ev events.Event) {
				sid := ev.Data["session"]
				switch ev.Kind {
				case "terminal.su_granted":
					if min, err := strconv.Atoi(ev.Data["minutes"]); err == nil && min > 0 && min <= suUntilMax && sid != "" {
						m[sid] = ev.TS.Add(time.Duration(min) * time.Minute)
					}
				case "terminal.su_expired":
					delete(m, sid)
				}
			})
		}
		suCache.key, suCache.until = key, m
	}
	out := map[string]time.Time{}
	for sid, t := range suCache.until {
		if t.After(now) {
			out[sid] = t
		}
	}
	return out
}
