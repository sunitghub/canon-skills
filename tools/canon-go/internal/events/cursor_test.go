package events

import (
	"compress/gzip"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// evLine is one valid v1 line: id n, in project proj.
func evLine(n int, proj string) string {
	return fmt.Sprintf(`{"schema":1,"id":"%016x","ts":"2026-11-10T09:00:00.000Z","kind":"ticket.closed","source":"tkt","project":"%s","data":{"ticket":"t-aaaa"}}`+"\n", n, proj)
}

func ids(ps []Positioned) string {
	var out []string
	for _, p := range ps {
		out = append(out, strings.TrimLeft(p.ID, "0"))
	}
	return strings.Join(out, ",")
}

func writeGz(t *testing.T, path, body string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	z := gzip.NewWriter(f)
	z.Write([]byte(body))
	z.Close()
	f.Close()
}

// Prod path: every client of /api/v1/events hands a cursor back (t-8d45): only `YYYY-MM-DD:offset` of a real day and a short offset is accepted.
func TestParseCursorAcceptsOnlyADayAndAnOffset(t *testing.T) {
	for _, s := range []string{"2026-11-10:0", "2026-11-10:123456", "2026-02-28:999999999999999"} {
		c, err := ParseCursor(s)
		if err != nil || c.String() != s {
			t.Errorf("%q: %+v %v", s, c, err)
		}
	}
	for _, s := range []string{"", "../../x:0", "2026-11-10", "2026-11-10:", "2026-11-10:-1", "2026-11-10:abc", "2026-13-45:0", "2026-02-30:0",
		"2026-11-10:1234567890123456", "2026-11-10:0 ", "2026-11-10:0\n", " 2026-11-10:0", "2026-11-10:0:0", "2026-11-10/..:0", "26-11-10:0"} {
		if _, err := ParseCursor(s); !errors.Is(err, ErrBadCursor) {
			t.Errorf("%q was accepted: %v", s, err)
		}
	}
}

// Prod path: the 400 a hostile cursor gets (t-8d45): a day that is not a readable plain file, or an offset past its end, is refused before any read.
func TestCheckCursorRefusesWhatIsNotAReadablePlainDay(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p") + evLine(2, "/p")})
	size := int64(len(evLine(1, "/p") + evLine(2, "/p")))
	writeGz(t, filepath.Join(dir, "2026-11-01.jsonl.gz"), evLine(3, "/p"))
	if err := os.Mkdir(filepath.Join(dir, "2026-11-08.jsonl"), 0o700); err != nil { // a folder named like a day
		t.Fatal(err)
	}
	for _, c := range []Cursor{{"2026-11-10", 0}, {"2026-11-10", size}} {
		if err := CheckCursor(home, c); err != nil {
			t.Errorf("%v refused: %v", c, err)
		}
	}
	for name, c := range map[string]Cursor{"past the end": {"2026-11-10", size + 1}, "unknown day": {"2026-11-09", 0}, "a gzipped day": {"2026-11-01", 0},
		"a folder": {"2026-11-08", 0}, "a day past retention": {"2025-01-01", 0}, "empty": {}} {
		err := CheckCursor(home, c)
		if !errors.Is(err, ErrBadCursor) {
			t.Errorf("%s: %v", name, err)
		} else if strings.Contains(err.Error(), c.Day) && c.Day != "" {
			t.Errorf("%s: the reason echoes the input: %v", name, err)
		}
	}
}

// Prod path: resuming a stream (t-8d45), the criterion "every missed event, no duplicate": two events and a bad line, a half-written line, then its end.
// Hand count: limit 2 gives events 1 and 2; resuming gives 4 only (3 is junk, skipped, the cursor moves past it) and never the half line 5;
// once line 5 is finished, resuming from the cursor after 4 gives 5.
func TestReadSinceNoDuplicatesNoGapsAndNoHalfLine(t *testing.T) {
	half := evLine(5, "/p")
	body := evLine(1, "/p") + evLine(2, "/p") + "not json\n" + evLine(4, "/p") + half[:40]
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": body})
	day := filepath.Join(dir, "2026-11-10.jsonl")
	first, next, err := ReadSince(home, Cursor{"2026-11-10", 0}, 2)
	if err != nil || ids(first) != "1,2" || next != first[1].Next {
		t.Fatalf("first page: %s next %v err %v", ids(first), next, err)
	}
	second, next2, err := ReadSince(home, next, 10)
	if err != nil || ids(second) != "4" {
		t.Fatalf("second page: %s err %v", ids(second), err)
	}
	if want := int64(len(evLine(1, "/p")+evLine(2, "/p")+"not json\n") + len(evLine(4, "/p"))); next2.Offset != want {
		t.Errorf("the cursor after the last complete line is %d, want %d (the half line is not consumed)", next2.Offset, want)
	}
	again, next3, err := ReadSince(home, next2, 10)
	if err != nil || len(again) != 0 || next3 != next2 {
		t.Fatalf("nothing new: %s %v %v", ids(again), next3, err)
	}
	f, _ := os.OpenFile(day, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(half[40:])
	f.Close()
	last, _, err := ReadSince(home, next2, 10)
	if err != nil || ids(last) != "5" {
		t.Fatalf("after the half line was finished: %s err %v", ids(last), err)
	}
}

// Prod path: a stream across midnight (t-8d45): the cursor moves to the next day's file at offset 0 and an older gzipped day is read too.
func TestReadSinceRollsToLaterDaysAndReadsAGzippedOne(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-11-09.jsonl": evLine(2, "/p"), "2026-11-10.jsonl": evLine(3, "/p") + evLine(4, "/p")})
	writeGz(t, filepath.Join(dir, "2026-11-08.jsonl.gz"), evLine(1, "/p"))
	all, next, err := ReadSince(home, Cursor{}, 10)
	if err != nil || ids(all) != "1,2,3,4" || next.Day != "2026-11-10" {
		t.Fatalf("zero cursor: %s next %v err %v", ids(all), next, err)
	}
	if all[1].Next.Day != "2026-11-09" || all[2].Next.Day != "2026-11-10" {
		t.Errorf("each event carries its own day's cursor: %v %v", all[1].Next, all[2].Next)
	}
	endOf9 := int64(len(evLine(2, "/p")))
	rolled, _, err := ReadSince(home, Cursor{"2026-11-09", endOf9}, 10)
	if err != nil || ids(rolled) != "3,4" {
		t.Fatalf("from the end of one day: %s err %v", ids(rolled), err)
	}
	mid, _, err := ReadSince(home, all[2].Next, 10)
	if err != nil || ids(mid) != "4" {
		t.Fatalf("from inside the last day: %s err %v", ids(mid), err)
	}
}

// Prod path: a subscriber that starts before any event exists (t-8d45): no day file is no error, and the first one to appear is read from its start.
func TestReadSinceWithNoLogYetThenOneAppears(t *testing.T) {
	home := t.TempDir()
	evs, next, err := ReadSince(home, Cursor{}, 10)
	if err != nil || len(evs) != 0 || next != (Cursor{}) {
		t.Fatalf("no log: %v %v %v", evs, next, err)
	}
	if end, err := End(home); err != nil || end != (Cursor{}) {
		t.Fatalf("End with no log: %v %v", end, err)
	}
	if err := os.MkdirAll(filepath.Join(home, "events"), 0o700); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(home, "events", "2026-11-10.jsonl"), []byte(evLine(7, "/p")), 0o600)
	evs, _, err = ReadSince(home, next, 10)
	if err != nil || ids(evs) != "7" {
		t.Fatalf("the first event after the log appeared: %s %v", ids(evs), err)
	}
	if end, _ := End(home); end != (Cursor{"2026-11-10", int64(len(evLine(7, "/p")))}) {
		t.Errorf("End = %v", end)
	}
}

// Prod path: the snapshot of /api/v1/events (t-8d45): the newest limit events that pass the project filter, oldest first, and the cursor at the
// stream's end so a subscriber misses nothing between the two. Hand count: events 1..6 across three days, 2 and 5 in another project.
func TestNewestKeepsTheLastMatchingAndReturnsTheEnd(t *testing.T) {
	home, dir := logWith(t, map[string]string{
		"2026-11-08.jsonl": evLine(1, "/p") + evLine(2, "/other"),
		"2026-11-09.jsonl": evLine(3, "/p") + evLine(4, "/p"),
		"2026-11-10.jsonl": evLine(5, "/other") + evLine(6, "/p") + "not json\n",
	})
	keep := func(ev Event) bool { return ev.Project == "/p" }
	got, end, err := Newest(home, 3, keep)
	if err != nil || ids(got) != "3,4,6" {
		t.Fatalf("newest 3: %s err %v", ids(got), err)
	}
	info, _ := os.Stat(filepath.Join(dir, "2026-11-10.jsonl"))
	if end != (Cursor{"2026-11-10", info.Size()}) {
		t.Errorf("end = %v, want the end of the newest day (%d)", end, info.Size())
	}
	got, _, _ = Newest(home, 100, keep)
	if ids(got) != "1,3,4,6" {
		t.Errorf("more than there is: %s", ids(got))
	}
	got, _, _ = Newest(home, 1, keep)
	if ids(got) != "6" {
		t.Errorf("newest 1: %s", ids(got))
	}
	// the snapshot's cursor and the stream meet: nothing is served twice and nothing is lost
	f, _ := os.OpenFile(filepath.Join(dir, "2026-11-10.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(evLine(7, "/p"))
	f.Close()
	more, _, err := ReadSince(home, end, 10)
	if err != nil || ids(more) != "7" {
		t.Errorf("after the snapshot: %s %v", ids(more), err)
	}
}

// Prod path: a stream that starts when the newest day is only archived (break-it, t-8d45): End must hand out a cursor the stream accepts, the start of
// the next day, and the first file that appears is read from its start even when days were skipped.
func TestEndOnAnArchivedNewestDayIsTheStartOfTheNextDay(t *testing.T) {
	home, dir := logWith(t, nil)
	writeGz(t, filepath.Join(dir, "2026-11-01.jsonl.gz"), evLine(1, "/p"))
	end, err := End(home)
	if err != nil || end != (Cursor{"2026-11-02", 0}) {
		t.Fatalf("End = %v %v", end, err)
	}
	if err := CheckCursor(home, end); err != nil {
		t.Errorf("the stream refuses the cursor End handed out: %v", err)
	}
	if _, snapEnd, _ := Newest(home, 10, func(Event) bool { return true }); snapEnd != end {
		t.Errorf("the snapshot's cursor %v differs from End %v", snapEnd, end)
	}
	if evs, next, err := ReadSince(home, end, 10); err != nil || len(evs) != 0 || next != end {
		t.Fatalf("nothing yet: %v %v %v", evs, next, err)
	}
	os.WriteFile(filepath.Join(dir, "2026-11-04.jsonl"), []byte(evLine(2, "/p")), 0o600) // two days were skipped
	if evs, _, err := ReadSince(home, end, 10); err != nil || ids(evs) != "2" {
		t.Errorf("the first file after the end: %s %v", ids(evs), err)
	}
}

// Prod path: the one cursor beyond the newest day that a client may send is End's (t-8d45): the next day at offset 0, nothing else.
func TestCheckCursorAcceptsOnlyTheDayAfterTheNewestAtZero(t *testing.T) {
	home, _ := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p")})
	if err := CheckCursor(home, Cursor{"2026-11-11", 0}); err != nil {
		t.Errorf("the next day at 0: %v", err)
	}
	for _, c := range []Cursor{{"2026-11-11", 1}, {"2026-11-12", 0}, {"2999-01-01", 0}, {"2026-11-09", 0}} {
		if err := CheckCursor(home, c); !errors.Is(err, ErrBadCursor) {
			t.Errorf("%v: %v", c, err)
		}
	}
}

// Prod path: a stream that is reading a day when it is archived keeps going (break-it, t-8d45): the offset is read through the gzipped copy.
func TestReadSinceContinuesInsideADayThatWasArchived(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p") + evLine(2, "/p")})
	first, _, err := ReadSince(home, Cursor{"2026-11-10", 0}, 1)
	if err != nil || ids(first) != "1" {
		t.Fatal(ids(first), err)
	}
	os.Remove(filepath.Join(dir, "2026-11-10.jsonl"))
	writeGz(t, filepath.Join(dir, "2026-11-10.jsonl.gz"), evLine(1, "/p")+evLine(2, "/p"))
	rest, _, err := ReadSince(home, first[0].Next, 10)
	if err != nil || ids(rest) != "2" {
		t.Errorf("after the day was archived: %s %v", ids(rest), err)
	}
	if err := CheckCursor(home, first[0].Next); !errors.Is(err, ErrBadCursor) {
		t.Errorf("a client's cursor into an archived day is still refused: %v", err)
	}
}

// Prod path: a plain day file replaced by a shorter one must not leave a stream waiting for bytes that will never come (t-8d45).
func TestReadSinceRefusesAnOffsetBeyondAReplacedFile(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p") + evLine(2, "/p")})
	first, _, _ := ReadSince(home, Cursor{"2026-11-10", 0}, 2)
	os.WriteFile(filepath.Join(dir, "2026-11-10.jsonl"), []byte(evLine(9, "/p")), 0o600)
	if _, _, err := ReadSince(home, first[1].Next, 10); !errors.Is(err, ErrBadCursor) {
		t.Errorf("a shorter file: %v", err)
	}
}

// Prod path: the id a client is given is the exact byte after its event (reviewer, t-8d45): one byte short would resume on the previous newline,
// one past would skip a character of the next line. Hand count: three equal lines, so the ids sit at 1, 2 and 3 line lengths, across a day change.
func TestPositionedCursorsCarryTheExactOffset(t *testing.T) {
	n := int64(len(evLine(1, "/p")))
	home, _ := logWith(t, map[string]string{"2026-11-09.jsonl": evLine(1, "/p") + evLine(2, "/p") + evLine(3, "/p"), "2026-11-10.jsonl": evLine(4, "/p")})
	got, end, err := ReadSince(home, Cursor{"2026-11-09", 0}, 10)
	if err != nil || len(got) != 4 {
		t.Fatal(ids(got), err)
	}
	for i, want := range []Cursor{{"2026-11-09", n}, {"2026-11-09", 2 * n}, {"2026-11-09", 3 * n}, {"2026-11-10", n}} {
		if got[i].Next != want {
			t.Errorf("event %d: cursor %v, want %v", i+1, got[i].Next, want)
		}
	}
	if end != (Cursor{"2026-11-10", n}) {
		t.Errorf("the cursor to ask next: %v", end)
	}
	if got, _, _ := Newest(home, 4, func(Event) bool { return true }); got[0].Next != (Cursor{"2026-11-09", n}) || got[3].Next != (Cursor{"2026-11-10", n}) {
		t.Errorf("Newest carries the same cursors: %v %v", got[0].Next, got[3].Next)
	}
}

// Prod path: every refusal of a cursor says `bad cursor` (t-8d45, mutation sweep): the board returns that text as the 400's error.
func TestEveryCursorRefusalIsNamedBadCursor(t *testing.T) {
	home, _ := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p")})
	_, perr := ParseCursor("x")
	for what, err := range map[string]error{"parse": perr, "unknown day": CheckCursor(home, Cursor{"2026-11-01", 0}), "offset": CheckCursor(home, Cursor{"2026-11-10", 99999})} {
		if !errors.Is(err, ErrBadCursor) || !strings.HasPrefix(err.Error(), "bad cursor") {
			t.Errorf("%s: %v", what, err)
		}
	}
}

// Prod path: a day that has both a plain file and a gzipped twin (a crashed gzip) is one day (t-8d45): its events are read once, from the plain file.
func TestADayWithAGzipTwinIsReadOnce(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p") + evLine(2, "/p")})
	writeGz(t, filepath.Join(dir, "2026-11-10.jsonl.gz"), evLine(1, "/p")+evLine(2, "/p"))
	if d := daysAscending(home); len(d) != 1 || filepath.Base(d[0].Path) != "2026-11-10.jsonl" {
		t.Fatalf("days: %v", d)
	}
	got, _, err := ReadSince(home, Cursor{}, 10)
	if err != nil || ids(got) != "1,2" {
		t.Errorf("read through a twin: %s %v", ids(got), err)
	}
	if err := CheckCursor(home, Cursor{"2026-11-10", 0}); err != nil {
		t.Errorf("a cursor into a day with a plain file: %v", err)
	}
}

// Prod path: the checks behind a refused cursor (t-8d45, mutation sweep) on hand-made day entries, which DayFiles would never list but a race can
// produce: a file gone by the time it is measured, a folder, a link, and an offset one past the end are each refused by resolve and by startAt, a
// gzipped day by resolve only (startAt reads through it), and an offset at the end is fine.
func TestResolveAndStartAtRefuseWhatIsNotAReadablePlainFile(t *testing.T) {
	dir := t.TempDir()
	plain := filepath.Join(dir, "plain.jsonl")
	os.WriteFile(plain, []byte("12345"), 0o600)
	link := filepath.Join(dir, "link.jsonl")
	if os.Symlink(plain, link) != nil {
		link = ""
	}
	os.Mkdir(filepath.Join(dir, "folder.jsonl"), 0o700)
	gz := filepath.Join(dir, "g.jsonl.gz")
	writeGz(t, gz, "12345")
	bad := map[string]string{"missing": filepath.Join(dir, "gone.jsonl"), "folder": filepath.Join(dir, "folder.jsonl")}
	if link != "" {
		bad["link"] = link
	}
	for name, path := range bad {
		days := []dayFile{{"2026-11-10", path}}
		if _, err := resolve(days, Cursor{"2026-11-10", 0}); !errors.Is(err, ErrBadCursor) {
			t.Errorf("resolve %s: %v", name, err)
		}
		if _, err := startAt(days, Cursor{"2026-11-10", 0}); !errors.Is(err, ErrBadCursor) {
			t.Errorf("startAt %s: %v", name, err)
		}
	}
	days := []dayFile{{"2026-11-10", plain}}
	for _, off := range []int64{0, 5} {
		if i, err := resolve(days, Cursor{"2026-11-10", off}); err != nil || i != 0 {
			t.Errorf("resolve at %d: %d %v", off, i, err)
		}
		if i, err := startAt(days, Cursor{"2026-11-10", off}); err != nil || i != 0 {
			t.Errorf("startAt at %d: %d %v", off, i, err)
		}
	}
	if _, err := resolve(days, Cursor{"2026-11-10", 6}); !errors.Is(err, ErrBadCursor) {
		t.Errorf("resolve past the end: %v", err)
	}
	if _, err := startAt(days, Cursor{"2026-11-10", 6}); !errors.Is(err, ErrBadCursor) {
		t.Errorf("startAt past the end: %v", err)
	}
	gzd := []dayFile{{"2026-11-10", gz}}
	if _, err := resolve(gzd, Cursor{"2026-11-10", 0}); !errors.Is(err, ErrBadCursor) {
		t.Errorf("resolve into a gzipped day: %v", err)
	}
	if i, err := startAt(gzd, Cursor{"2026-11-10", 3}); err != nil || i != 0 {
		t.Errorf("startAt into a gzipped day: %d %v", i, err)
	}
	if i, err := startAt(days, Cursor{"2026-11-11", 0}); err != nil || i != 1 {
		t.Errorf("startAt after every day is len(days): %d %v", i, err)
	}
}

// Prod path: a cursor against an empty log, and against a newest day with a junk name (t-8d45): refused, never a panic and never an invented day.
func TestCheckCursorOnAnEmptyLogAndAJunkDayName(t *testing.T) {
	empty := t.TempDir()
	for _, c := range []Cursor{{"2026-11-10", 0}, {}, {"0001-01-01", 0}} {
		if err := CheckCursor(empty, c); !errors.Is(err, ErrBadCursor) {
			t.Errorf("%v on an empty log: %v", c, err)
		}
	}
	home, _ := logWith(t, map[string]string{"2026-99-99.jsonl": evLine(1, "/p")}) // matches the day pattern, is not a date
	if err := CheckCursor(home, Cursor{"0001-01-02", 0}); !errors.Is(err, ErrBadCursor) {
		t.Errorf("a day invented from a junk name: %v", err)
	}
}

// Prod path: Newest and ReadSince on a log with more than one line per day (t-8d45, mutation sweep): a zero limit hands out nothing, an exact page
// stops without opening an older day, a longer day is trimmed to its last events, and End is the end of every line.
func TestNewestAndReadSinceHonourTheLimitAndEnd(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p") + evLine(2, "/p") + evLine(3, "/p")})
	if got, _, err := ReadSince(home, Cursor{"2026-11-10", 0}, 0); err != nil || len(got) != 0 {
		t.Errorf("limit 0: %s %v", ids(got), err)
	}
	if got, _, _ := Newest(home, 2, func(Event) bool { return true }); ids(got) != "2,3" {
		t.Errorf("a day longer than the limit is trimmed to its last events: %s", ids(got))
	}
	n := int64(len(evLine(1, "/p")))
	if end, err := End(home); err != nil || end != (Cursor{"2026-11-10", 3 * n}) {
		t.Errorf("End covers every line: %v %v", end, err)
	}
	// an older day that cannot be read is never opened when the newest day already fills the page
	os.WriteFile(filepath.Join(dir, "2026-11-09.jsonl.gz"), []byte("not gzip"), 0o600)
	if got, _, err := Newest(home, 3, func(Event) bool { return true }); err != nil || ids(got) != "1,2,3" {
		t.Errorf("an exact page must not read the older day: %s %v", ids(got), err)
	}
	if _, _, err := Newest(home, 4, func(Event) bool { return true }); err == nil {
		t.Error("a page that needs the corrupt older day must say so, not hand out a short page")
	}
}

// Prod path: a day that cannot be read to its end is an error, never a shorter log (t-8d45): a corrupt gzipped day, whether it is read from its
// start, from an offset inside it, or reached while reading on.
func TestACorruptDayIsAnErrorNotAShortLog(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(3, "/p")})
	good := filepath.Join(dir, "good.gz")
	writeGz(t, good, strings.Repeat(evLine(1, "/p"), 50))
	b, _ := os.ReadFile(good)
	os.Remove(good)
	os.WriteFile(filepath.Join(dir, "2026-11-09.jsonl.gz"), b[:len(b)-12], 0o600) // a truncated stream
	if err := EachIn(filepath.Join(dir, "2026-11-09.jsonl.gz"), func(Event) {}); err == nil {
		t.Error("EachIn: a truncated gz read as complete")
	}
	if _, _, err := ReadSince(home, Cursor{}, 1000); err == nil {
		t.Error("ReadSince through a truncated day gave no error")
	}
	if _, err := scanDay(filepath.Join(dir, "2026-11-09.jsonl.gz"), 40, func(Event, int64, bool) bool { return true }); err == nil {
		t.Error("an offset inside a truncated gz gave no error")
	}
}

// Prod path: openDayAt (t-8d45): a file that is not there is an error at any offset, and an offset beyond a gzipped day's length is an empty read,
// not an error (a stream whose day was archived while it caught up).
func TestOpenDayAt(t *testing.T) {
	dir := t.TempDir()
	if rc, err := openDayAt(filepath.Join(dir, "none.jsonl"), 7); err == nil {
		rc.Close()
		t.Error("a missing day opened")
	}
	gz := filepath.Join(dir, "d.jsonl.gz")
	writeGz(t, gz, evLine(1, "/p"))
	end, err := scanDay(gz, 100000, func(Event, int64, bool) bool { return true })
	if err != nil || end != 100000 {
		t.Errorf("an offset past the end of a gzipped day: end %d err %v", end, err)
	}
}
