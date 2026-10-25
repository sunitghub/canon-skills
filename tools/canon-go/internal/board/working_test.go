package board

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// TestAnnotateWorking protects GET /api/tickets' `working` field, which turns a card's Resume into Working (t-187e): only the
// ticket ACTIVE names, only in progress, only while the beat is fresh; a dead process, an old beat or a corrupt file annotates nothing.
func TestAnnotateWorking(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	age := func(d time.Duration) int64 { return now.Add(-d).Unix() }
	alive := func(p int) bool { return p == 4242 }
	beatText := func(id string, ts int64, host string, pid string) string {
		return fmt.Sprintf("ticket=%s\nts=%d\nhost=%s\npid=%s\n", id, ts, host, pid)
	}
	cases := []struct {
		name, active, beat, status string
		want                       bool
		skipOnWindows              bool
	}{
		{"fresh, live pid, here", "t-aa01", beatText("t-aa01", age(time.Minute), "me", "4242"), "in_progress", true, true},
		{"live pid, quiet 3h: a live agent outranks a quiet beat", "t-aa01", beatText("t-aa01", age(3*time.Hour), "me", "4242"), "in_progress", true, true},
		{"live pid but over 4h", "t-aa01", beatText("t-aa01", age(5*time.Hour), "me", "4242"), "in_progress", false, true},
		{"dead pid", "t-aa01", beatText("t-aa01", age(time.Minute), "me", "999"), "in_progress", false, true},
		{"no pid, fresh", "t-aa01", beatText("t-aa01", age(5*time.Minute), "me", ""), "in_progress", true, false},
		{"no pid, stale", "t-aa01", beatText("t-aa01", age(11*time.Minute), "me", ""), "in_progress", false, false},
		{"other host, fresh (pid not checked)", "t-aa01", beatText("t-aa01", age(2*time.Minute), "elsewhere", "999"), "in_progress", true, false},
		{"other host, stale", "t-aa01", beatText("t-aa01", age(20*time.Minute), "elsewhere", "4242"), "in_progress", false, false},
		{"beat for another ticket", "t-aa01", beatText("t-bb02", age(time.Minute), "me", ""), "in_progress", false, false},
		{"ticket not in progress", "t-aa01", beatText("t-aa01", age(time.Minute), "me", ""), "open", false, false},
		{"corrupt beat", "t-aa01", "\x00\x01 not a beat", "in_progress", false, false},
		{"empty beat", "t-aa01", "", "in_progress", false, false},
		{"oversized beat", "t-aa01", beatText("t-aa01", age(time.Minute), "me", "") + string(make([]byte, 4000)), "in_progress", false, false},
		{"no ts", "t-aa01", "ticket=t-aa01\nhost=me\n", "in_progress", false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.skipOnWindows && runtime.GOOS == "windows" {
				t.Skip("no process check on Windows")
			}
			dir := t.TempDir()
			os.WriteFile(filepath.Join(dir, "ACTIVE"), []byte(c.active+"\n"), 0o644)
			if c.beat != "" || c.name == "empty beat" {
				os.WriteFile(filepath.Join(dir, "ACTIVE.beat"), []byte(c.beat), 0o644)
			}
			tickets := []ticket{{"id": "t-aa01", "status": c.status}, {"id": "t-cc03", "status": "in_progress"}}
			annotateWorking(dir, tickets, now, "me", alive)
			_, got := tickets[0]["working"]
			if got != c.want {
				t.Errorf("working on t-aa01 = %v, want %v", got, c.want)
			}
			if _, other := tickets[1]["working"]; other {
				t.Error("a ticket ACTIVE does not name was marked working")
			}
		})
	}
	t.Run("no ACTIVE file", func(t *testing.T) {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "ACTIVE.beat"), []byte(beatText("t-aa01", age(time.Minute), "me", "")), 0o644)
		tickets := []ticket{{"id": "t-aa01", "status": "in_progress"}}
		annotateWorking(dir, tickets, now, "me", alive)
		if _, ok := tickets[0]["working"]; ok {
			t.Error("a beat without ACTIVE marked a ticket working")
		}
	})
	t.Run("fields", func(t *testing.T) {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "ACTIVE"), []byte("t-aa01\n"), 0o644)
		os.WriteFile(filepath.Join(dir, "ACTIVE.beat"), []byte(beatText("t-aa01", age(90*time.Second), "elsewhere", "")), 0o644)
		tickets := []ticket{{"id": "t-aa01", "status": "in_progress"}}
		annotateWorking(dir, tickets, now, "me", alive)
		w, _ := tickets[0]["working"].(map[string]any)
		if w["age_s"] != 90 || w["host"] != "elsewhere" || w["here"] != false {
			t.Errorf("working = %v", w)
		}
	})
}
