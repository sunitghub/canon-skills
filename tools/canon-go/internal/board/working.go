package board

import (
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Working (t-187e): the card shows Working, not Resume, while an agent is on a ticket outside any Cockpit session.
// `.tickets/ACTIVE` names the ticket and `.tickets/ACTIVE.beat` (written by tools/work-beat) says whether an agent is still
// attached. Only a label: a wrong Working costs one dialog click, a wrong Resume is today's behaviour.
const (
	beatPidLimit   = 4 * time.Hour    // an agent process we can see is alive: trusted this long without another canon command
	beatQuietLimit = 10 * time.Minute // no process to check (another host, Windows, an agent not recognised): only the clock
)

type beat struct {
	ticket, host string
	ts           int64
	pid          int // 0 when none was recorded
}

// readBeat parses ACTIVE.beat; ok is false for anything unreadable, oversized or malformed.
func readBeat(path string) (beat, bool) {
	f, err := os.Open(path)
	if err != nil {
		return beat{}, false
	}
	defer f.Close()
	buf := make([]byte, 2048)
	n, _ := f.Read(buf)
	if n == 0 || n == len(buf) {
		return beat{}, false
	}
	var b beat
	for _, line := range strings.Split(string(buf[:n]), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "ticket":
			b.ticket = strings.TrimSpace(v)
		case "host":
			b.host = strings.TrimSpace(v)
		case "ts":
			b.ts, _ = strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		case "pid":
			if p, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && p > 1 {
				b.pid = p
			}
		}
	}
	return b, b.ticket != "" && b.ts > 0
}

// annotateWorking sets t["working"] = {age_s, host, here, pid} on the ticket ACTIVE names when it is in progress and its
// beat is fresh. alive is the process check (injected for tests); a corrupt or missing file annotates nothing.
func annotateWorking(tdir string, tickets []ticket, now time.Time, host string, alive func(int) bool) {
	raw, err := os.ReadFile(tdir + string(os.PathSeparator) + "ACTIVE")
	if err != nil {
		return
	}
	id := strings.TrimSpace(string(raw))
	b, ok := readBeat(tdir + string(os.PathSeparator) + "ACTIVE.beat")
	if !ok || b.ticket != id {
		return
	}
	age := now.Sub(time.Unix(b.ts, 0))
	if age < 0 {
		age = 0
	}
	here := b.host != "" && strings.EqualFold(b.host, host)
	fresh := age <= beatQuietLimit
	if here && b.pid > 0 && runtime.GOOS != "windows" {
		fresh = age <= beatPidLimit && alive(b.pid)
	}
	if !fresh {
		return
	}
	for _, t := range tickets {
		if t["id"] == id && t["status"] == "in_progress" {
			w := map[string]any{"age_s": int(age.Seconds()), "host": b.host, "here": here}
			if b.pid > 0 {
				w["pid"] = b.pid
			}
			t["working"] = w
		}
	}
}
