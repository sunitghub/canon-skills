package events

// What Admin > Logging shows and does with the activity log (t-1bd5): its size, a preview of what a shorter Keep for would remove, an
// export, and Delete. Every read goes through the same safe opener as Verify (regular files only, size caps).

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// exportMax caps an export: the day files together, uncompressed. A variable so a test can lower it.
var exportMax int64 = 256 << 20

// ErrExportTooBig means the log is larger than an export may be.
var ErrExportTooBig = errors.New("the activity log is larger than an export may be (256 MB)")

var tmpGzRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\.tmp\.gz$`)

// Info is the log's size as the Logging page shows it. Days counts a day once even when a plain file and a .gz twin both exist.
type Info struct {
	Days, Files    int
	Bytes          int64
	Oldest, Newest string
}

// dayEntries lists the day files (plain and gzipped) of dir, oldest day first, with a plain file before its .gz twin.
func dayEntries(dir string) ([]os.DirEntry, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []os.DirEntry
	for _, e := range entries {
		m := dayAnyRe.FindStringSubmatch(e.Name())
		if m == nil || e.IsDir() {
			continue
		}
		if _, err := time.Parse("2006-01-02", m[1]); err != nil {
			continue
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name() < out[j].Name() })
	return out, nil
}

// Stat reports the log's size. Only regular files count (a link is not a day); no log yet is a zero Info and no error.
func Stat(home string) (Info, error) {
	var in Info
	dir, err := eventsDir(home)
	if errors.Is(err, os.ErrNotExist) {
		return in, nil
	}
	if err != nil {
		return in, err
	}
	entries, err := dayEntries(dir)
	if err != nil {
		return in, err
	}
	days := map[string]bool{}
	for _, e := range entries {
		fi, err := e.Info()
		if err != nil || !fi.Mode().IsRegular() {
			continue
		}
		day := e.Name()[:10]
		in.Files++
		in.Bytes += fi.Size()
		days[day] = true
		if in.Oldest == "" || day < in.Oldest {
			in.Oldest = day
		}
		if day > in.Newest {
			in.Newest = day
		}
	}
	in.Days = len(days)
	return in, nil
}

// WouldRemove is how many days and files a Keep for of keep days would remove as of at: the same cutoff prune uses.
func WouldRemove(home string, keep int, at time.Time) (days, files int) {
	dir, err := eventsDir(home)
	if err != nil {
		return 0, 0
	}
	entries, err := dayEntries(dir)
	if err != nil {
		return 0, 0
	}
	oldest := at.AddDate(0, 0, -keep).Format("2006-01-02")
	seen := map[string]bool{}
	for _, e := range entries {
		if day := e.Name()[:10]; day < oldest {
			files++
			seen[day] = true
		}
	}
	return len(seen), files
}

// exportPaths is the day files an export reads, oldest first: one per day (the plain file when a .gz twin exists), regular files only.
func exportPaths(home string) ([]string, error) {
	dir, err := eventsDir(home)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	entries, err := dayEntries(dir)
	if err != nil {
		return nil, err
	}
	var paths []string
	seen := map[string]bool{}
	for _, e := range entries {
		day := e.Name()[:10]
		if seen[day] || !e.Type().IsRegular() {
			continue
		}
		seen[day] = true
		paths = append(paths, filepath.Join(dir, e.Name()))
	}
	return paths, nil
}

// ExportCheck reads every day once without writing and refuses a log that is unreadable or larger than exportMax, so a download can be
// refused with a clean error before its first byte.
func ExportCheck(home string) error {
	paths, err := exportPaths(home)
	if err != nil {
		return err
	}
	var total int64
	for _, p := range paths {
		n, err := copyDay(io.Discard, p)
		if err != nil {
			return fmt.Errorf("%s: %s", filepath.Base(p)[:10], herrWord(err))
		}
		if total += n + 1; total > exportMax {
			return ErrExportTooBig
		}
	}
	return nil
}

// ExportStream writes every day, oldest first, as one JSON-lines stream: a gzipped day is gunzipped, a link or other non-regular file is
// left out, and seals.jsonl is not part of it. Call ExportCheck first.
func ExportStream(w io.Writer, home string) error {
	paths, err := exportPaths(home)
	if err != nil {
		return err
	}
	for _, p := range paths {
		if _, err := copyDay(w, p); err != nil {
			return fmt.Errorf("%s: %s", filepath.Base(p)[:10], herrWord(err))
		}
	}
	return nil
}

// Export is ExportCheck, then ExportStream.
func Export(w io.Writer, home string) error {
	if err := ExportCheck(home); err != nil {
		return err
	}
	return ExportStream(w, home)
}

// copyDay copies one day's uncompressed bytes to w, adding a final newline when the file lacks one, and returns the byte count.
func copyDay(w io.Writer, path string) (int64, error) {
	r, err := openDay(path)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	cw := &lastByteWriter{w: w}
	n, err := io.Copy(cw, io.LimitReader(r, dayMaxBytes+1))
	if err != nil {
		return n, err
	}
	if n > dayMaxBytes {
		return n, errTooBig
	}
	if n > 0 && cw.last != '\n' {
		if _, err := w.Write([]byte{'\n'}); err != nil {
			return n, err
		}
	}
	return n, nil
}

type lastByteWriter struct {
	w    io.Writer
	last byte
}

func (l *lastByteWriter) Write(b []byte) (int, error) {
	n, err := l.w.Write(b)
	if n > 0 {
		l.last = b[n-1]
	}
	return n, err
}

// Cleared is what Clear removed: files and days, the oldest and newest day, and the names it could not remove.
type Cleared struct {
	Files    int
	From, To string
	Failed   []string
}

// Clear deletes the activity log: day files (plain and gzipped), leftover compressed temp files, seals.jsonl and emit-errors.log, each by
// exact name. os.Remove takes a link itself and never follows it, and a name that merely looks like one of these is not touched. A file
// that cannot be removed (on Windows, one another program holds open) is listed in Failed, never counted. Another run sealing or pruning
// at the same time makes it return ErrBusy.
func Clear(home string) (Cleared, error) {
	var c Cleared
	dir, err := eventsDir(home)
	if errors.Is(err, os.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	release, ok := lock(dir)
	if !ok {
		return c, ErrBusy
	}
	defer release()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return c, err
	}
	for _, e := range entries {
		name := e.Name()
		m := dayAnyRe.FindStringSubmatch(name)
		isDay := m != nil
		if isDay {
			if _, err := time.Parse("2006-01-02", m[1]); err != nil {
				isDay = false
			}
		}
		if !(isDay || name == sealsName || name == "emit-errors.log" || tmpGzRe.MatchString(name)) || e.IsDir() {
			continue
		}
		if err := os.Remove(filepath.Join(dir, name)); err != nil {
			c.Failed = append(c.Failed, name)
			continue
		}
		c.Files++
		if isDay {
			if c.From == "" || m[1] < c.From {
				c.From = m[1]
			}
			if m[1] > c.To {
				c.To = m[1]
			}
		}
	}
	sort.Strings(c.Failed)
	if len(c.Failed) > 0 {
		return c, fmt.Errorf("%d file(s) could not be removed: %s", len(c.Failed), strings.Join(c.Failed, ", "))
	}
	return c, nil
}
