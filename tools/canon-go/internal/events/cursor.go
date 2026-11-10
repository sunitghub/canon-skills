package events

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// A Cursor is a place in the event stream (t-8d45): a day and a byte offset into that day's uncompressed stream. It is opaque to a client,
// which only hands back what it was given, and it is client input here: ParseCursor checks its syntax and Resolve checks it against the
// day files the reader may read, so a request string is never joined into a path.
type Cursor struct {
	Day    string
	Offset int64
}

// ErrBadCursor is every refusal of a cursor. Its message is fixed text: the input is never echoed.
var ErrBadCursor = errors.New("bad cursor")

var cursorRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2}):(\d{1,15})$`)

func (c Cursor) String() string { return c.Day + ":" + strconv.FormatInt(c.Offset, 10) }

// ParseCursor accepts only `YYYY-MM-DD:offset`, a real calendar day and an offset of at most 15 digits.
func ParseCursor(s string) (Cursor, error) {
	m := cursorRe.FindStringSubmatch(s)
	if m == nil {
		return Cursor{}, ErrBadCursor
	}
	if _, err := time.Parse("2006-01-02", m[1]); err != nil {
		return Cursor{}, ErrBadCursor
	}
	off, err := strconv.ParseInt(m[2], 10, 64)
	if err != nil {
		return Cursor{}, ErrBadCursor
	}
	return Cursor{m[1], off}, nil
}

// Positioned is an event with the cursor just after it: what a client sends back to resume without a duplicate or a gap.
type Positioned struct {
	Event
	Next Cursor
}

type dayFile struct{ Day, Path string }

// daysAscending lists the readable days, oldest first, one file per day: the plain file when a day has both it and a .gz twin, because a
// cursor's offset is into the plain stream and today's file is still growing.
func daysAscending(home string) []dayFile {
	files := DayFiles(home) // newest first, within retention, regular files only
	var out []dayFile
	seen := map[string]bool{}
	for i := len(files) - 1; i >= 0; i-- {
		day := dayAnyRe.FindStringSubmatch(filepath.Base(files[i]))[1]
		if !seen[day] {
			seen[day] = true
			out = append(out, dayFile{day, files[i]})
		}
	}
	return out
}

// resolve finds the cursor's day among the readable days and checks the offset against that file's size, before anything is opened for
// reading. A gzipped day cannot be checked without decompressing it, so it is refused: the client takes a snapshot again.
func resolve(days []dayFile, c Cursor) (int, error) {
	for i, d := range days {
		if d.Day != c.Day {
			continue
		}
		if strings.HasSuffix(d.Path, ".gz") {
			return 0, fmt.Errorf("%w: that day is archived, take a snapshot", ErrBadCursor)
		}
		fi, err := os.Lstat(d.Path)
		if err != nil || !fi.Mode().IsRegular() || c.Offset > fi.Size() {
			return 0, fmt.Errorf("%w: offset out of range", ErrBadCursor)
		}
		return i, nil
	}
	if len(days) > 0 && c.Offset == 0 && c.Day == nextDay(days[len(days)-1].Day) { // the cursor End gives when the newest day is archived: nothing to read yet
		return len(days), nil
	}
	return 0, fmt.Errorf("%w: unknown day", ErrBadCursor)
}

// nextDay is the day after day (YYYY-MM-DD), which no file may exist for yet.
func nextDay(day string) string {
	t, err := time.Parse("2006-01-02", day)
	if err != nil {
		return day
	}
	return t.AddDate(0, 0, 1).Format("2006-01-02")
}

// endCursor is the place after everything in day d, whose complete lines end at offset end. An archived (gzipped) day cannot be resumed inside,
// so the end of the log is the start of the day after it: the first file that appears is read from its start.
func endCursor(d dayFile, end int64) Cursor {
	if strings.HasSuffix(d.Path, ".gz") {
		return Cursor{nextDay(d.Day), 0}
	}
	return Cursor{d.Day, end}
}

// startAt finds where a read begins: the first readable day at or after the cursor's day, or len(days) when every day is older (wait for a later
// one). It is for a cursor this package produced, so a day that was archived or removed since is not an error: a stream keeps going. A plain
// file the offset lies beyond is refused (the file was replaced), never read from the wrong place.
func startAt(days []dayFile, c Cursor) (int, error) {
	for i, d := range days {
		if d.Day < c.Day {
			continue
		}
		if d.Day == c.Day && !strings.HasSuffix(d.Path, ".gz") {
			if fi, err := os.Lstat(d.Path); err != nil || !fi.Mode().IsRegular() || c.Offset > fi.Size() {
				return 0, fmt.Errorf("%w: offset out of range", ErrBadCursor)
			}
		}
		return i, nil
	}
	return len(days), nil
}

// CheckCursor reports whether c names a place in a readable day file (ErrBadCursor with a fixed reason when not). It opens nothing.
func CheckCursor(home string, c Cursor) error {
	_, err := resolve(daysAscending(home), c)
	return err
}

// ReadSince returns up to limit valid events after from, oldest first, each with the cursor after it, and the cursor to ask next. A cursor that
// came from a client must pass CheckCursor first; this reads on from one the package produced, through a day that has since been archived. It reads
// only complete lines, so an event a writer is still appending is neither skipped nor served early, and it moves on to later days. A line that
// fails the schema is skipped but the cursor still moves past it.
func ReadSince(home string, from Cursor, limit int) ([]Positioned, Cursor, error) {
	days := daysAscending(home)
	i := 0
	if from != (Cursor{}) { // the zero cursor is internal ("the start of the first day that appears"): ParseCursor never returns it
		var err error
		if i, err = startAt(days, from); err != nil {
			return nil, from, err
		}
	}
	var out []Positioned
	cur := from
	for ; i < len(days) && len(out) < limit; i++ {
		d := days[i]
		off := int64(0)
		if d.Day == from.Day { // only the cursor's own day starts part way in
			off = from.Offset
		}
		end, err := scanDay(d.Path, off, func(ev Event, e int64, terminated bool) bool {
			if terminated {
				out = append(out, Positioned{ev, Cursor{d.Day, e}})
			}
			return len(out) < limit
		})
		if err != nil {
			return out, cur, err
		}
		cur = Cursor{d.Day, end}
		if len(out) >= limit { // stopped inside the day: resume right after the last event handed out
			return out, out[len(out)-1].Next, nil
		}
	}
	return out, cur, nil
}

// Newest returns the newest limit valid events for which keep is true, oldest first, and the cursor at the end of the stream as it is
// now (the place a subscriber starts from, so the snapshot and the stream meet with no gap). Days are scanned newest first and the scan stops
// once the limit is met.
func Newest(home string, limit int, keep func(Event) bool) ([]Positioned, Cursor, error) {
	days := daysAscending(home)
	var tail []Positioned // newest day first, each day's events oldest first
	var end Cursor
	for i := len(days) - 1; i >= 0; i-- {
		d := days[i]
		var day []Positioned
		dayEnd, err := scanDay(d.Path, 0, func(ev Event, e int64, terminated bool) bool {
			if terminated && keep(ev) {
				day = append(day, Positioned{ev, Cursor{d.Day, e}})
			}
			return true
		})
		if err != nil {
			return nil, Cursor{}, err
		}
		if i == len(days)-1 {
			end = endCursor(d, dayEnd)
		}
		tail = append(day, tail...)
		if len(tail) >= limit {
			break
		}
	}
	if len(tail) > limit {
		tail = tail[len(tail)-limit:]
	}
	return tail, end, nil
}

// End is the cursor at the end of the stream as it is now: after the last complete line of the newest day. It is the zero Cursor when there
// is no day file yet (ReadSince reads from the first day that appears). Only the newest day is scanned.
func End(home string) (Cursor, error) {
	days := daysAscending(home)
	if len(days) == 0 {
		return Cursor{}, nil
	}
	d := days[len(days)-1]
	end, err := scanDay(d.Path, 0, func(Event, int64, bool) bool { return true })
	return endCursor(d, end), err
}
