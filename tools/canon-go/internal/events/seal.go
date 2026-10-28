package events

// Day seals, verify and retention (t-3137). Tamper-evident, not tamper-proof: a seal is a hash of a closed UTC day file, chained to the
// previous seal, so an edited, deleted or reordered day is found. Someone who can rewrite seals.jsonl and every line after the change
// defeats it, and a line forged into a day before it is sealed is sealed with the rest. Nothing here authenticates who wrote a line.
//
// seals.jsonl is append-only, one JSON object per line:
//
//	{"day":"2026-10-12","lines":41,"sha256":"<hex of the uncompressed day>","prev":"<hex of the previous line, "" first>"}
//	{"pruned_through":"2026-09-20","prev":"<hex of the previous line>"}   written by a prune that removed files
//
// The hash is over the UNCOMPRESSED bytes, so gzipping a sealed day does not change the result. Every file read here is one we do not
// control: regular files only (no symlink), size caps, and nothing read from them is printed except a validated day and a fixed word.

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"canon/internal/settings"
)

const (
	sealGrace    = time.Hour // a day is sealed once this long has passed since its end, so late writers near midnight are included
	gzipAfter    = 7         // days: sealed day files older than this are gzipped
	sealsMax     = 4 << 20
	sealLineMax  = 4 << 10
	lockStale    = 10 * time.Minute
	sealsName    = "seals.jsonl"
	lockName     = ".maintain.lock"
	resultIntact = "intact"
	resultBroken = "broken"
	resultMiss   = "missing"
	resultUnseal = "unsealed"
)

// dayMaxBytes: a day file, or one after gunzip, larger than this is refused. A variable so a test can lower it.
var dayMaxBytes int64 = 256 << 20

var (
	dayAnyRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\.jsonl(\.gz)?$`)
	dayOnly  = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	hexRe    = regexp.MustCompile(`^[0-9a-f]{64}$`)

	errNotRegular = errors.New("not a regular file")
	errTooBig     = errors.New("too large")
	errChanged    = errors.New("changed while opening")
)

// DayResult is one line of Verify. Day is a validated YYYY-MM-DD, or "seals.jsonl" (with Result broken) for a fault in the seal file.
type DayResult struct {
	Day, Result, Why string
}

func hashHex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// openRegular opens path only when it is a regular file (never a symlink) no larger than max.
func openRegular(path string, max int64) (*os.File, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, errNotRegular
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	fi2, err := f.Stat()
	if err != nil || !os.SameFile(fi, fi2) {
		f.Close()
		return nil, errChanged
	}
	if fi2.Size() > max {
		f.Close()
		return nil, errTooBig
	}
	return f, nil
}

type readCloser struct {
	io.Reader
	closers []io.Closer
}

func (r readCloser) Close() error {
	var err error
	for _, c := range r.closers {
		if e := c.Close(); e != nil && err == nil {
			err = e
		}
	}
	return err
}

// openDay opens a day file for reading its uncompressed bytes. A .gz is gunzipped through a reader that stops one byte past the cap,
// so a decompression bomb cannot be read whole: hashDay and latestIn see the extra byte and refuse.
func openDay(path string) (io.ReadCloser, error) {
	f, err := openRegular(path, dayMaxBytes)
	if err != nil {
		return nil, err
	}
	if !strings.HasSuffix(path, ".gz") {
		return f, nil
	}
	z, err := gzip.NewReader(f)
	if err != nil {
		f.Close()
		return nil, err
	}
	return readCloser{io.LimitReader(z, dayMaxBytes+1), []io.Closer{z, f}}, nil
}

// hashDay is the SHA-256 and line count of a day file's uncompressed bytes.
func hashDay(path string) (sum string, lines int, err error) {
	r, err := openDay(path)
	if err != nil {
		return "", 0, err
	}
	defer r.Close()
	h := sha256.New()
	var total int64
	var last byte
	buf := make([]byte, 64<<10)
	for {
		n, rerr := r.Read(buf)
		if n > 0 {
			total += int64(n)
			if total > dayMaxBytes {
				return "", 0, errTooBig
			}
			h.Write(buf[:n])
			lines += bytes.Count(buf[:n], []byte{'\n'})
			last = buf[n-1]
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return "", 0, rerr
		}
	}
	if total > 0 && last != '\n' {
		lines++
	}
	return hex.EncodeToString(h.Sum(nil)), lines, nil
}

// record is one parsed seals.jsonl line.
type record struct {
	raw     []byte
	hash    string // SHA-256 of raw
	anchor  bool
	day     string // a seal's day, or an anchor's pruned_through
	lines   int
	sha     string
	prev    string
	fault   string // non-empty: the line is not a well-formed record
	lineNum int
}

// parseSeals reads seals.jsonl (absent is empty). A line that is not a record is kept with a fault, so Verify can name it.
func parseSeals(dir string) ([]record, error) {
	f, err := openRegular(filepath.Join(dir, sealsName), sealsMax)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var recs []record
	r := bufio.NewReader(io.LimitReader(f, sealsMax+1))
	for n := 1; ; n++ {
		b, rerr := r.ReadBytes('\n')
		b = bytes.TrimSuffix(b, []byte{'\n'})
		if len(b) > 0 || rerr == nil {
			recs = append(recs, parseRecord(b, n))
		}
		if rerr != nil {
			break
		}
	}
	return recs, nil
}

func parseRecord(b []byte, n int) record {
	rec := record{raw: b, hash: hashHex(b), lineNum: n}
	if len(b) > sealLineMax {
		rec.fault = "line too long"
		rec.raw, rec.hash = nil, hashHex(nil)
		return rec
	}
	var v struct {
		Day           *string `json:"day"`
		Lines         *int    `json:"lines"`
		SHA           string  `json:"sha256"`
		PrunedThrough *string `json:"pruned_through"`
		Prev          *string `json:"prev"`
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&v); err != nil || v.Prev == nil || (*v.Prev != "" && !hexRe.MatchString(*v.Prev)) {
		rec.fault = "not a seal"
		return rec
	}
	rec.prev = *v.Prev
	switch {
	case v.PrunedThrough != nil && v.Day == nil && v.Lines == nil && v.SHA == "" && dayOnly.MatchString(*v.PrunedThrough):
		rec.anchor, rec.day = true, *v.PrunedThrough
	case v.Day != nil && v.Lines != nil && *v.Lines >= 0 && hexRe.MatchString(v.SHA) && dayOnly.MatchString(*v.Day) && v.PrunedThrough == nil:
		rec.day, rec.lines, rec.sha = *v.Day, *v.Lines, v.SHA
	default:
		rec.fault = "not a seal"
	}
	return rec
}

// dayFiles maps each day to the file that holds it (the plain file when both exist), refusing nothing: a non-regular name is
// still listed, so Verify reports it instead of overlooking it.
func dayFiles(dir string) (map[string]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, e := range entries {
		m := dayAnyRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		if _, err := time.Parse("2006-01-02", m[1]); err != nil {
			continue
		}
		if cur, ok := out[m[1]]; ok && !strings.HasSuffix(cur, ".gz") {
			continue
		}
		out[m[1]] = filepath.Join(dir, e.Name())
	}
	return out, nil
}

func eventsDir(home string) (string, error) {
	if home == "" {
		return "", errors.New("no CANON_HOME and no home folder")
	}
	dir := filepath.Join(home, "events")
	fi, err := os.Lstat(dir)
	if err != nil {
		return "", err
	}
	if !fi.IsDir() {
		return "", errors.New("events is not a folder (a symlink is refused)")
	}
	return dir, nil
}

// closed reports whether day (UTC) ended at least sealGrace before at.
func closed(day string, at time.Time) bool {
	d, err := time.Parse("2006-01-02", day)
	return err == nil && !at.Before(d.AddDate(0, 0, 1).Add(sealGrace))
}

// Verify checks every day file and seal in home's events folder as of at. A day is intact (its file hashes to its seal, the chain
// holds), broken, missing (sealed, file gone, not pruned), or unsealed (a file with no seal: today's, a day inside the grace period,
// or one a sealer has not reached). Days removed by a prune are not listed. The second result is false when any day is broken or missing.
func Verify(home string, at time.Time) ([]DayResult, bool) {
	dir, err := eventsDir(home)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, true
		}
		return []DayResult{{"seals.jsonl", resultBroken, err.Error()}}, false
	}
	var out []DayResult
	fail := func(day, why string) { out = append(out, DayResult{day, resultBroken, why}) }
	recs, err := parseSeals(dir)
	if err != nil {
		why := "cannot be read"
		switch {
		case errors.Is(err, errTooBig):
			why = "is larger than 4 MB"
		case errors.Is(err, errNotRegular):
			why = "is not a regular file"
		}
		return []DayResult{{"seals.jsonl", resultBroken, why}}, false
	}
	files, err := dayFiles(dir)
	if err != nil {
		return []DayResult{{"seals.jsonl", resultBroken, "events folder cannot be read"}}, false
	}

	through := ""
	for _, r := range recs {
		if r.fault == "" && r.anchor && r.day > through {
			through = r.day
		}
	}
	prevHash, lastDay := "", ""
	var prevRaw []byte
	sealed := map[string]bool{}
	for _, r := range recs {
		if r.fault != "" {
			fail("seals.jsonl", fmt.Sprintf("line %d is %s", r.lineNum, r.fault))
			prevHash = r.hash
			continue
		}
		if prevRaw != nil && bytes.Equal(prevRaw, r.raw) { // two sealers wrote the same day at once: the second is ignored
			continue
		}
		prevRaw = r.raw
		if r.prev != prevHash {
			fail(r.day, "seal chain does not match the line before it")
		}
		prevHash = r.hash
		if r.anchor {
			continue
		}
		if r.day <= lastDay {
			fail(r.day, "seal is out of order or repeated")
			continue
		}
		lastDay = r.day
		sealed[r.day] = true
		path, have := files[r.day]
		switch {
		case !have && r.day <= through:
			// removed by retention: the anchor says so
		case !have:
			out = append(out, DayResult{r.day, resultMiss, "sealed but its file is gone"})
		default:
			sum, lines, herr := hashDay(path)
			switch {
			case herr != nil:
				fail(r.day, "file cannot be read: "+herrWord(herr))
			case sum != r.sha || lines != r.lines:
				fail(r.day, "does not match its seal")
			default:
				out = append(out, DayResult{r.day, resultIntact, ""})
			}
		}
	}
	var days []string
	for d := range files {
		days = append(days, d)
	}
	sort.Strings(days)
	for _, d := range days {
		switch {
		case through != "" && d <= through:
			fail(d, "present although the log was pruned through "+through)
		case !sealed[d] && closed(d, at):
			out = append(out, DayResult{d, resultUnseal, "closed, not sealed yet"})
		case !sealed[d]:
			out = append(out, DayResult{d, resultUnseal, "still open"})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Day < out[j].Day })
	ok := true
	for _, r := range out {
		if r.Result == resultBroken || r.Result == resultMiss {
			ok = false
		}
	}
	return out, ok
}

func herrWord(err error) string {
	switch {
	case errors.Is(err, errTooBig):
		return "too large"
	case errors.Is(err, errNotRegular):
		return "not a regular file"
	case errors.Is(err, errChanged):
		return "changed while read"
	}
	return "unreadable"
}

// lock takes events/.maintain.lock (O_EXCL). A lock older than lockStale is a crashed run's and is taken over.
func lock(dir string) (release func(), ok bool) {
	p := filepath.Join(dir, lockName)
	for i := 0; i < 2; i++ {
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err == nil {
			f.Close()
			return func() { os.Remove(p) }, true
		}
		fi, serr := os.Lstat(p)
		if serr != nil || time.Since(fi.ModTime()) < lockStale {
			return nil, false
		}
		os.Remove(p)
	}
	return nil, false
}

// ErrBusy means another run is sealing or pruning; the caller may try again.
var ErrBusy = errors.New("another run is sealing or pruning the log")

// Maintain seals every closed day not yet sealed, gzips sealed days older than 7 days, and removes days older than the retention
// setting, writing a pruned_through record and a log.pruned event when it removed any. It is idempotent and best effort for callers
// that emit: they ignore its error. source is the program running it (the log.pruned event's source).
func Maintain(home string, at time.Time, source string) error {
	dir, err := eventsDir(home)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	release, ok := lock(dir)
	if !ok {
		return ErrBusy
	}
	defer release()
	var errs []error
	if err := sealClosed(dir, at); err != nil {
		errs = append(errs, err)
	}
	if err := gzipSealed(dir, at); err != nil {
		errs = append(errs, err)
	}
	if err := prune(home, dir, at, source); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// Seal runs only the sealing step (canon log seal).
func Seal(home string, at time.Time) (int, error) {
	dir, err := eventsDir(home)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, err
	}
	release, ok := lock(dir)
	if !ok {
		return 0, ErrBusy
	}
	defer release()
	before, _ := parseSeals(dir)
	err = sealClosed(dir, at)
	after, _ := parseSeals(dir)
	return len(after) - len(before), err
}

// chainTail is the hash of the last record and the newest sealed day, or "" and "" for an empty chain.
func chainTail(recs []record) (hash, day string) {
	for _, r := range recs {
		hash = r.hash
		if r.fault == "" && !r.anchor && r.day > day {
			day = r.day
		}
	}
	return hash, day
}

func appendRecord(dir string, line []byte) error {
	f, err := os.OpenFile(filepath.Join(dir, sealsName), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	_, werr := f.Write(append(line, '\n'))
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	return werr
}

// sealClosed seals, oldest first, each closed day after the newest sealed one. A day older than that stays unsealed (a sealed log
// is append-only in day order).
func sealClosed(dir string, at time.Time) error {
	recs, err := parseSeals(dir)
	if err != nil {
		return err
	}
	tail, lastDay := chainTail(recs)
	files, err := dayFiles(dir)
	if err != nil {
		return err
	}
	var days []string
	for d := range files {
		if d > lastDay && closed(d, at) {
			days = append(days, d)
		}
	}
	sort.Strings(days)
	for _, d := range days {
		sum, lines, err := hashDay(files[d])
		if err != nil {
			return fmt.Errorf("%s: %s", d, herrWord(err))
		}
		line, _ := json.Marshal(struct {
			Day    string `json:"day"`
			Lines  int    `json:"lines"`
			SHA256 string `json:"sha256"`
			Prev   string `json:"prev"`
		}{d, lines, sum, tail})
		if err := appendRecord(dir, line); err != nil {
			return err
		}
		tail = hashHex(line)
	}
	return nil
}

// gzipSealed compresses each sealed plain day file older than gzipAfter days. The .gz is written beside it, read back to the sealed
// hash, renamed into place, and only then is the original removed; a day whose file no longer matches its seal is left alone for Verify.
func gzipSealed(dir string, at time.Time) error {
	recs, err := parseSeals(dir)
	if err != nil {
		return err
	}
	seals := map[string]record{}
	for _, r := range recs {
		if r.fault == "" && !r.anchor {
			seals[r.day] = r
		}
	}
	cutoff := at.AddDate(0, 0, -gzipAfter).Format("2006-01-02")
	files, err := dayFiles(dir)
	if err != nil {
		return err
	}
	var errs []error
	for d, path := range files {
		s, sealed := seals[d]
		if !sealed || d >= cutoff || strings.HasSuffix(path, ".gz") {
			continue
		}
		if err := gzipOne(path, s.sha); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", d, err))
		}
	}
	return errors.Join(errs...)
}

func gzipOne(path, wantSum string) error {
	in, err := openRegular(path, dayMaxBytes)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := strings.TrimSuffix(path, ".jsonl") + ".tmp.gz" // not a day-file name; ends .gz so hashDay gunzips it
	os.Remove(tmp)                                        // a leftover, or a planted link: removed itself, never written through
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	zw := gzip.NewWriter(out)
	_, cerr := io.Copy(zw, in)
	in.Close() // before the original is removed (Windows will not remove an open file)
	if e := zw.Close(); cerr == nil {
		cerr = e
	}
	if e := out.Close(); cerr == nil {
		cerr = e
	}
	if cerr != nil {
		os.Remove(tmp)
		return cerr
	}
	if sum, _, err := hashDay(tmp); err != nil || sum != wantSum {
		os.Remove(tmp)
		if err == nil {
			err = errors.New("does not match its seal; left as is")
		}
		return err
	}
	if err := os.Rename(tmp, path+".gz"); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Remove(path)
}

// prune removes day files older than the retention setting. Before it removes anything it appends a pruned_through record, so Verify
// can tell a removed day from a deleted one, and afterwards it writes the log.pruned event. Only exact day-file names are touched,
// and os.Remove removes a link itself, never its target.
func prune(home, dir string, at time.Time, source string) error {
	oldest := at.AddDate(0, 0, -settings.RetentionDays(home)).Format("2006-01-02")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var doomed []string
	from, to := "", ""
	for _, e := range entries {
		m := dayAnyRe.FindStringSubmatch(e.Name())
		if m == nil || e.IsDir() {
			continue
		}
		if _, err := time.Parse("2006-01-02", m[1]); err != nil || m[1] >= oldest {
			continue
		}
		doomed = append(doomed, e.Name())
		if from == "" || m[1] < from {
			from = m[1]
		}
		if m[1] > to {
			to = m[1]
		}
	}
	if len(doomed) == 0 {
		return nil
	}
	recs, err := parseSeals(dir)
	if err != nil {
		return err
	}
	tail, _ := chainTail(recs)
	line, _ := json.Marshal(struct {
		PrunedThrough string `json:"pruned_through"`
		Prev          string `json:"prev"`
	}{to, tail})
	if err := appendRecord(dir, line); err != nil {
		return err
	}
	var errs []error
	removed := 0
	for _, name := range doomed {
		if err := os.Remove(filepath.Join(dir, name)); err != nil {
			errs = append(errs, err)
			continue
		}
		removed++
	}
	if err := EmitActor(home, "log.pruned", source, "system", "", map[string]string{
		"from": from, "to": to, "files": fmt.Sprint(removed), "last_seal": tail,
	}); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}
