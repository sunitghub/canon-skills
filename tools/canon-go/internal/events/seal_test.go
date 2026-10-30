package events

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"canon/internal/settings"
)

func at(s string) time.Time {
	ts, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return ts.UTC()
}

// logWith makes a CANON_HOME whose events folder holds the given day files (name -> content).
func logWith(t *testing.T, files map[string]string) (home, dir string) {
	t.Helper()
	home = t.TempDir()
	dir = filepath.Join(home, "events")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return home, dir
}

func sealLines(t *testing.T, dir string) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, sealsName))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
}

func sum(b string) string { h := sha256.Sum256([]byte(b)); return hex.EncodeToString(h[:]) }

func find(rs []DayResult, day string) (DayResult, bool) {
	for _, r := range rs {
		if r.Day == day {
			return r, true
		}
	}
	return DayResult{}, false
}

var threeDays = map[string]string{
	"2026-10-01.jsonl": "{\"a\":1}\n{\"a\":2}\n",
	"2026-10-02.jsonl": "{\"b\":1}\n",
	"2026-10-03.jsonl": "{\"c\":1}\n{\"c\":2}\n{\"c\":3}\n",
}

// copyDir clones the events folder so a tamper test never touches the log under test.
func copyDir(t *testing.T, src string) (home, dir string) {
	t.Helper()
	home = t.TempDir()
	dir = filepath.Join(home, "events")
	os.MkdirAll(dir, 0o700)
	es, _ := os.ReadDir(src)
	for _, e := range es {
		b, err := os.ReadFile(filepath.Join(src, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(dir, e.Name()), b, 0o600)
	}
	return home, dir
}

// Protects the audit log's seals: a closed day is sealed after the grace period, never today, chained to the previous seal, and a second
// run adds nothing.
func TestSealChainGraceAndIdempotence(t *testing.T) {
	home, dir := logWith(t, threeDays)
	if n, err := Seal(home, at("2026-10-03T00:30:00Z")); err != nil || n != 1 { // 10-02 ended 30 minutes ago: inside the grace period
		t.Fatalf("sealed %d, err %v; want only 10-01", n, err)
	}
	if n, err := Seal(home, at("2026-10-03T01:00:00Z")); err != nil || n != 1 {
		t.Fatalf("after the grace period sealed %d, err %v; want 10-02", n, err)
	}
	if n, _ := Seal(home, at("2026-10-03T23:59:00Z")); n != 0 { // 10-03 is today: never sealed
		t.Fatalf("sealed today's file")
	}
	lines := sealLines(t, dir)
	if len(lines) != 2 {
		t.Fatalf("seal lines = %v", lines)
	}
	var s1, s2 struct {
		Day, SHA256, Prev string
		Lines             int
	}
	json.Unmarshal([]byte(lines[0]), &s1)
	json.Unmarshal([]byte(lines[1]), &s2)
	if s1.Day != "2026-10-01" || s1.Lines != 2 || s1.SHA256 != sum(threeDays["2026-10-01.jsonl"]) || s1.Prev != "" {
		t.Errorf("first seal = %+v", s1)
	}
	if s2.Day != "2026-10-02" || s2.Prev != sum(lines[0]) {
		t.Errorf("second seal must chain to the hash of the first line: %+v", s2)
	}
	if n, _ := Seal(home, at("2026-10-03T23:59:00Z")); n != 0 || len(sealLines(t, dir)) != 2 {
		t.Errorf("a second run changed the seals")
	}
}

// Protects `canon log verify`: each way of changing a sealed log is found and named, the untouched log is intact, and verify did run.
func TestVerifyFindsEveryTamper(t *testing.T) {
	home, dir := logWith(t, threeDays)
	if _, err := Seal(home, at("2026-10-05T00:00:00Z")); err != nil {
		t.Fatal(err)
	}
	clock := at("2026-10-05T12:00:00Z")
	base, ok := Verify(home, clock)
	intact := 0
	for _, r := range base {
		if r.Result == resultIntact {
			intact++
		}
	}
	if !ok || intact != 3 {
		t.Fatalf("untouched log: ok=%v results=%v; verify must have checked 3 days", ok, base)
	}
	cases := []struct {
		name, day, want string
		mutate          func(dir string)
	}{
		{"one byte changed in a sealed day", "2026-10-02", resultBroken, func(d string) {
			os.WriteFile(filepath.Join(d, "2026-10-02.jsonl"), []byte("{\"b\":2}\n"), 0o600)
		}},
		{"a seal line edited", "2026-10-02", resultBroken, func(d string) {
			l := sealLines(t, d)
			l[1] = strings.Replace(l[1], `"lines":1`, `"lines":9`, 1)
			os.WriteFile(filepath.Join(d, sealsName), []byte(strings.Join(l, "\n")+"\n"), 0o600)
		}},
		{"a seal line deleted", "2026-10-03", resultBroken, func(d string) { // the line after it no longer chains
			l := sealLines(t, d)
			os.WriteFile(filepath.Join(d, sealsName), []byte(l[0]+"\n"+l[2]+"\n"), 0o600)
		}},
		{"two seal lines swapped", "2026-10-02", resultBroken, func(d string) {
			l := sealLines(t, d)
			os.WriteFile(filepath.Join(d, sealsName), []byte(l[0]+"\n"+l[2]+"\n"+l[1]+"\n"), 0o600)
		}},
		{"a day file deleted", "2026-10-02", resultMiss, func(d string) { os.Remove(filepath.Join(d, "2026-10-02.jsonl")) }},
		{"junk appended to the seal file", "seals.jsonl", resultBroken, func(d string) {
			f, _ := os.OpenFile(filepath.Join(d, sealsName), os.O_APPEND|os.O_WRONLY, 0)
			f.WriteString("not json\n")
			f.Close()
		}},
		{"a closed day added with no seal", "2026-10-04", resultUnseal, func(d string) {
			os.WriteFile(filepath.Join(d, "2026-10-04.jsonl"), []byte("{}\n"), 0o600)
		}},
	}
	for _, c := range cases {
		h, d := copyDir(t, dir)
		c.mutate(d)
		rs, ok := Verify(h, clock)
		r, found := find(rs, c.day)
		if !found || r.Result != c.want {
			t.Errorf("%s: want %s at %s, got %v", c.name, c.want, c.day, rs)
		}
		if c.want != resultUnseal && ok {
			t.Errorf("%s: verify said ok", c.name)
		}
		if c.want == resultUnseal && !ok {
			t.Errorf("%s: an unsealed day alone must not fail verify", c.name)
		}
	}
	// a swapped pair must not hide behind the chain alone: every swap names a day
	if rs, ok := Verify(home, clock); !ok || len(rs) != 3 {
		t.Errorf("the original log changed during the tamper cases: %v", rs)
	}
}

// Protects verify's wording of today's file and of a closed day not sealed yet.
func TestVerifyUnsealedWording(t *testing.T) {
	home, _ := logWith(t, map[string]string{"2026-10-04.jsonl": "{}\n", "2026-10-05.jsonl": "{}\n"})
	rs, ok := Verify(home, at("2026-10-05T12:00:00Z"))
	a, _ := find(rs, "2026-10-04")
	b, _ := find(rs, "2026-10-05")
	if !ok || a.Result != resultUnseal || b.Result != resultUnseal || b.Why != "still open" || a.Why != "closed, not sealed yet" {
		t.Errorf("results = %v", rs)
	}
}

// Protects retention's gzip step: a gzipped sealed day verifies the same, an unsealed or recent one is left plain, and a day that no
// longer matches its seal is never replaced by a compressed copy of the wrong bytes.
func TestGzipKeepsVerifyAndSkipsWhatItMust(t *testing.T) {
	home, dir := logWith(t, map[string]string{
		"2026-10-01.jsonl": "{\"a\":1}\n", // sealed, older than 7 days: gzipped
		"2026-10-09.jsonl": "{\"b\":1}\n", // sealed, recent: stays plain
		"2026-10-02.jsonl": "{\"c\":1}\n", // sealed then edited: stays plain
	})
	if _, err := Seal(home, at("2026-10-10T00:00:00Z")); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "2026-10-02.jsonl"), []byte("{\"c\":2}\n"), 0o600)
	os.WriteFile(filepath.Join(dir, "2026-10-03.jsonl"), []byte("{\"d\":1}\n"), 0o600) // after the seal: unsealed
	clock := at("2026-10-10T12:00:00Z")
	if err := Maintain(home, clock, "tkt"); err == nil || !strings.Contains(err.Error(), "2026-10-02") {
		t.Fatalf("maintain must report the day that no longer matches its seal, got %v", err)
	}
	has := func(n string) bool { _, err := os.Stat(filepath.Join(dir, n)); return err == nil }
	if !has("2026-10-01.jsonl.gz") || has("2026-10-01.jsonl") || has("2026-10-01.tmp.gz") {
		t.Error("the sealed old day should be gzipped and the original removed")
	}
	if !has("2026-10-09.jsonl") || has("2026-10-09.jsonl.gz") {
		t.Error("a day inside 7 days must stay plain")
	}
	if !has("2026-10-02.jsonl") || has("2026-10-02.jsonl.gz") {
		t.Error("a day that no longer matches its seal must stay as it is")
	}
	if !has("2026-10-03.jsonl") || has("2026-10-03.jsonl.gz") {
		t.Error("an unsealed day must never be gzipped")
	}
	if runtime.GOOS != "windows" {
		if fi, _ := os.Stat(filepath.Join(dir, "2026-10-01.jsonl.gz")); fi.Mode().Perm() != 0o600 {
			t.Errorf(".gz mode = %o", fi.Mode().Perm())
		}
	}
	rs, _ := Verify(home, clock)
	if r, _ := find(rs, "2026-10-01"); r.Result != resultIntact {
		t.Errorf("a gzipped sealed day = %v", r)
	}
	if r, _ := find(rs, "2026-10-02"); r.Result != resultBroken {
		t.Errorf("the edited day = %v", r)
	}
}

func setRetention(t *testing.T, home string, days int) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"log": map[string]any{"retention_days": days}})
	if err := os.WriteFile(filepath.Join(home, "settings.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// Protects the retention setting: a day exactly N days old is kept, one more day is removed (plain and gzipped), a pruned_through record
// and a log.pruned event are written, verify stays intact from the oldest kept day, and a newer day deleted by hand is still missing.
func TestRetentionBoundariesAnchorAndEvent(t *testing.T) {
	for _, n := range []int{30, 90, 365} {
		now := at("2027-06-01T12:00:00Z")
		t.Setenv("CANON_EVENTS_CLOCK", now.Format(time.RFC3339)) // the log.pruned event lands on this day, not the real one
		keep := now.AddDate(0, 0, -n).Format("2006-01-02")
		drop := now.AddDate(0, 0, -n-1).Format("2006-01-02")
		dropGz := now.AddDate(0, 0, -n-2).Format("2006-01-02")
		recent := now.AddDate(0, 0, -2).Format("2006-01-02")
		home, dir := logWith(t, map[string]string{keep + ".jsonl": "{\"k\":1}\n", drop + ".jsonl": "{\"d\":1}\n", recent + ".jsonl": "{\"r\":1}\n"})
		var gz bytes.Buffer
		zw := gzip.NewWriter(&gz)
		zw.Write([]byte("{\"g\":1}\n"))
		zw.Close()
		os.WriteFile(filepath.Join(dir, dropGz+".jsonl.gz"), gz.Bytes(), 0o600)
		setRetention(t, home, n)
		if err := Maintain(home, now, "tkt"); err != nil {
			t.Fatalf("%d: %v", n, err)
		}
		has := func(name string) bool { _, err := os.Stat(filepath.Join(dir, name)); return err == nil }
		if !has(keep+".jsonl") && !has(keep+".jsonl.gz") {
			t.Errorf("%d days: the day exactly %d days old was removed", n, n)
		}
		if has(drop+".jsonl") || has(drop+".jsonl.gz") || has(dropGz+".jsonl.gz") {
			t.Errorf("%d days: older days remain", n)
		}
		lines := sealLines(t, dir)
		var anchor struct {
			PrunedThrough string `json:"pruned_through"`
			Prev          string `json:"prev"`
		}
		if err := json.Unmarshal([]byte(lines[len(lines)-1]), &anchor); err != nil || anchor.PrunedThrough != drop {
			t.Errorf("%d days: last seal line = %q, want pruned_through %s", n, lines[len(lines)-1], drop)
		}
		if rs, ok := Verify(home, now); !ok {
			t.Errorf("%d days: verify after a prune: %v", n, rs)
		}
		ev, found := Latest(home, "log.pruned", "", nil)
		if !found || ev.Data["to"] != drop || ev.Data["from"] != dropGz || ev.Data["files"] != "2" || ev.Data["last_seal"] != anchor.Prev || ev.Actor != "system" {
			t.Errorf("%d days: log.pruned = %+v found=%v", n, ev, found)
		}
		before := len(sealLines(t, dir))
		Maintain(home, now, "tkt")
		if len(sealLines(t, dir)) != before {
			t.Errorf("%d days: a prune that removed nothing wrote a record", n)
		}
		os.Remove(filepath.Join(dir, keep+".jsonl"))
		os.Remove(filepath.Join(dir, keep+".jsonl.gz"))
		if rs, ok := Verify(home, now); ok {
			t.Errorf("%d days: a day deleted by hand after a prune must be missing: %v", n, rs)
		}
	}
}

// Protects the lie an anchor could tell: pruned_through over a day that still has a file is broken, so a hand-appended anchor cannot hide
// a deleted middle day.
func TestAnchorCannotHideAMiddleDay(t *testing.T) {
	home, dir := logWith(t, threeDays)
	Seal(home, at("2026-10-05T00:00:00Z"))
	os.Remove(filepath.Join(dir, "2026-10-02.jsonl"))
	l := sealLines(t, dir)
	anchor, _ := json.Marshal(map[string]string{"pruned_through": "2026-10-02", "prev": sum(l[len(l)-1])})
	f, _ := os.OpenFile(filepath.Join(dir, sealsName), os.O_APPEND|os.O_WRONLY, 0)
	f.Write(append(anchor, '\n'))
	f.Close()
	rs, ok := Verify(home, at("2026-10-05T12:00:00Z"))
	broken := false
	for _, r := range rs {
		broken = broken || (r.Day == "2026-10-01" && r.Result == resultBroken)
	}
	if ok || !broken {
		t.Errorf("an anchor over a kept earlier day must be broken: %v", rs)
	}
}

// Protects the setting's fail-safe: a bad or missing file, or a value outside 30/90/365, means 30, never a different number.
func TestBadRetentionSettingMeansThirty(t *testing.T) {
	for name, body := range map[string]string{
		"missing":   "",
		"malformed": "{not json",
		"seven":     `{"log":{"retention_days":7}}`,
		"string":    `{"log":{"retention_days":"365"}}`,
		"zero":      `{"log":{"retention_days":0}}`,
		"negative":  `{"log":{"retention_days":-90}}`,
		"flat":      `{"log.retention_days":90}`,
	} {
		home := t.TempDir()
		if body != "" {
			os.WriteFile(filepath.Join(home, "settings.json"), []byte(body), 0o600)
		}
		if got := settings.RetentionDays(home); got != 30 {
			t.Errorf("%s: retention = %d, want 30", name, got)
		}
	}
	home := t.TempDir()
	setRetention(t, home, 365)
	if got := settings.RetentionDays(home); got != 365 {
		t.Errorf("365 = %d", got)
	}
}

// Protects the files verify and maintenance read but do not control: a symlink, an oversized file, a decompression bomb and a forged
// day are refused by name, a symlink target is never touched, and no file content reaches the output.
func TestHostileInputs(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	old := dayMaxBytes
	dayMaxBytes = 1 << 10
	defer func() { dayMaxBytes = old }()

	// a day file that is a symlink to a file outside the folder
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "{}\n"})
	Seal(home, at("2026-10-05T00:00:00Z"))
	outside := filepath.Join(t.TempDir(), "secret.txt")
	os.WriteFile(outside, []byte("do not read\n"), 0o600)
	os.Remove(filepath.Join(dir, "2026-10-01.jsonl"))
	os.Symlink(outside, filepath.Join(dir, "2026-10-01.jsonl"))
	rs, ok := Verify(home, at("2026-10-05T12:00:00Z"))
	if r, _ := find(rs, "2026-10-01"); ok || r.Result != resultBroken || strings.Contains(r.Why, "do not read") {
		t.Errorf("symlinked day: %v", rs)
	}
	setRetention(t, home, 30)
	Maintain(home, at("2027-01-01T00:00:00Z"), "tkt") // prunes the link itself
	if b, err := os.ReadFile(outside); err != nil || string(b) != "do not read\n" {
		t.Errorf("a prune followed the link to its target: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(dir, "2026-10-01.jsonl")); err == nil {
		t.Errorf("the link itself should have been removed")
	}

	// a planted link where the compressed copy is written: removed, never written through
	h1, d1 := logWith(t, map[string]string{"2026-10-01.jsonl": "{}\n"})
	Seal(h1, at("2026-10-05T00:00:00Z"))
	victim := filepath.Join(t.TempDir(), "victim.txt")
	os.WriteFile(victim, []byte("keep me\n"), 0o600)
	os.Symlink(victim, filepath.Join(d1, "2026-10-01.tmp.gz"))
	if err := Maintain(h1, at("2026-10-20T00:00:00Z"), "tkt"); err != nil {
		t.Errorf("maintain with a planted link: %v", err)
	}
	if b, _ := os.ReadFile(victim); string(b) != "keep me\n" {
		t.Errorf("gzip wrote through a planted link: %q", b)
	}

	// events/ itself a symlink: nothing is done to its target
	h2 := t.TempDir()
	target := t.TempDir()
	os.WriteFile(filepath.Join(target, "2020-01-01.jsonl"), []byte("{}\n"), 0o600)
	os.Symlink(target, filepath.Join(h2, "events"))
	if err := Maintain(h2, at("2027-01-01T00:00:00Z"), "tkt"); err == nil {
		t.Errorf("maintenance through a linked events folder must refuse")
	}
	if _, err := os.Stat(filepath.Join(target, "2020-01-01.jsonl")); err != nil {
		t.Errorf("a linked events folder's target was pruned")
	}
	if rs, ok := Verify(h2, at("2027-01-01T00:00:00Z")); ok || len(rs) != 1 {
		t.Errorf("verify through a linked events folder: %v", rs)
	}

	// an oversized day, and a gzip that expands past the cap (small on disk)
	h3, d3 := logWith(t, map[string]string{"2026-10-01.jsonl": strings.Repeat("x", 2<<10)})
	if rs, ok := Verify(h3, at("2026-10-05T00:00:00Z")); !ok || len(rs) != 1 || rs[0].Result != resultUnseal {
		t.Errorf("an oversized unsealed day is only unsealed in verify: %v", rs)
	}
	if err := Maintain(h3, at("2026-10-05T00:00:00Z"), "tkt"); err == nil {
		t.Errorf("sealing an oversized day must report it")
	}
	if _, err := os.Stat(filepath.Join(d3, sealsName)); err == nil {
		t.Errorf("an oversized day was sealed")
	}
	var bomb bytes.Buffer
	zw := gzip.NewWriter(&bomb)
	zw.Write(bytes.Repeat([]byte("0"), 4<<10))
	zw.Close()
	h4, d4 := logWith(t, nil)
	os.WriteFile(filepath.Join(d4, "2026-10-01.jsonl.gz"), bomb.Bytes(), 0o600)
	if _, _, err := hashDay(filepath.Join(d4, "2026-10-01.jsonl.gz")); err == nil {
		t.Errorf("a gzip that expands past the cap was hashed whole")
	}
	_ = h4

	// a seal file over 4 MB, a line over 4 KB, and a forged day carrying a terminal escape
	h5, d5 := logWith(t, nil)
	os.WriteFile(filepath.Join(d5, sealsName), bytes.Repeat([]byte("x"), sealsMax+10), 0o600)
	if rs, ok := Verify(h5, at("2026-10-05T00:00:00Z")); ok || len(rs) != 1 || rs[0].Day != "seals.jsonl" {
		t.Errorf("a 4 MB+ seal file: %v", rs)
	}
	h6, d6 := logWith(t, nil)
	long := `{"day":"2026-10-01","lines":1,"sha256":"` + strings.Repeat("a", 64) + `","prev":"` + strings.Repeat("a", 5000) + `"}` + "\n"
	forged := "{\"day\":\"\\u001b[31mred\",\"lines\":1,\"sha256\":\"" + strings.Repeat("a", 64) + "\",\"prev\":\"\"}\n"
	os.WriteFile(filepath.Join(d6, sealsName), []byte(long+forged), 0o600)
	rs, ok = Verify(h6, at("2026-10-05T00:00:00Z"))
	if ok || len(rs) != 2 {
		t.Fatalf("long and forged lines: %v", rs)
	}
	for _, r := range rs {
		if strings.ContainsRune(r.Day+r.Result+r.Why, 0x1b) || r.Day != "seals.jsonl" {
			t.Errorf("file content reached the output: %q", r)
		}
	}
}

// Protects concurrent maintenance (the first event of a day, the daemon's hourly run and `canon log seal` can overlap): the log stays intact.
func TestConcurrentMaintainStaysIntact(t *testing.T) {
	home, dir := logWith(t, threeDays)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			Maintain(home, at("2026-10-05T00:00:00Z"), "tkt")
		}()
	}
	wg.Wait()
	if rs, ok := Verify(home, at("2026-10-05T12:00:00Z")); !ok {
		t.Errorf("verify after concurrent runs: %v", rs)
	}
	if n := len(sealLines(t, dir)); n != 3 {
		t.Errorf("seal lines = %d, want 3", n)
	}
}

// Protects the lock: a fresh lock means another run is working (busy), a stale one is a crashed run's and is taken over.
func TestLockBusyAndStale(t *testing.T) {
	home, dir := logWith(t, threeDays)
	lockPath := filepath.Join(dir, lockName)
	os.WriteFile(lockPath, nil, 0o600)
	if err := Maintain(home, at("2026-10-05T00:00:00Z"), "tkt"); err != ErrBusy {
		t.Errorf("fresh lock: %v", err)
	}
	old := time.Now().Add(-time.Hour)
	os.Chtimes(lockPath, old, old)
	if err := Maintain(home, at("2026-10-05T00:00:00Z"), "tkt"); err != nil {
		t.Errorf("stale lock: %v", err)
	}
	if _, err := os.Stat(lockPath); err == nil {
		t.Errorf("the lock was left behind")
	}
}

// Protects Factory's "Last synced" and the progress card, which read the log through Latest: a day gzipped by retention is read the same.
func TestLatestReadsAGzippedDay(t *testing.T) {
	line := `{"schema":1,"id":"aaaaaaaaaaaaaaaa","ts":"2026-10-01T09:00:00.000Z","kind":"github.synced","source":"tkt","project":"/p","data":{"count":"4"}}` + "\n"
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": line})
	Seal(home, at("2026-10-03T00:00:00Z"))
	t.Setenv("CANON_EVENTS_CLOCK", "2026-10-12T00:00:00Z")
	if err := Maintain(home, now(), "tkt"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-10-01.jsonl.gz")); err != nil {
		t.Fatalf("the day was not gzipped: %v", err)
	}
	ev, ok := Latest(home, "github.synced", "/p", nil)
	if !ok || ev.Data["count"] != "4" {
		t.Errorf("Latest through a .gz = %+v %v", ev, ok)
	}
}

// Protects verify's words: the CLI and the Admin page (t-1bd5) match on them, so they are pinned as literals.
func TestVerifyWords(t *testing.T) {
	if resultIntact != "intact" || resultBroken != "broken" || resultMiss != "missing" || resultUnseal != "unsealed" {
		t.Errorf("result words changed: %q %q %q %q", resultIntact, resultBroken, resultMiss, resultUnseal)
	}
}

// Protects the reason each failure gives: the line a person reads after the day.
func TestVerifyGivesTheReason(t *testing.T) {
	home, dir := logWith(t, threeDays)
	Seal(home, at("2026-10-05T00:00:00Z"))
	clock := at("2026-10-05T12:00:00Z")
	why := func(h, day string) string {
		rs, _ := Verify(h, clock)
		for _, r := range rs {
			if r.Day == day && r.Result != resultIntact {
				return r.Why
			}
		}
		return ""
	}
	h, d := copyDir(t, dir)
	os.WriteFile(filepath.Join(d, "2026-10-02.jsonl"), []byte("x\n"), 0o600)
	if w := why(h, "2026-10-02"); w != "does not match its seal" {
		t.Errorf("changed day: %q", w)
	}
	h, d = copyDir(t, dir)
	os.Remove(filepath.Join(d, "2026-10-02.jsonl"))
	if w := why(h, "2026-10-02"); w != "sealed but its file is gone" {
		t.Errorf("missing day: %q", w)
	}
	h, d = copyDir(t, dir)
	l := sealLines(t, d)
	os.WriteFile(filepath.Join(d, sealsName), []byte(l[0]+"\n"+l[2]+"\n"+l[1]+"\n"), 0o600)
	if w := why(h, "2026-10-02"); w != "seal is out of order or repeated" && w != "does not follow the seal before it" {
		t.Errorf("swapped seals: %q", w)
	}
	// a repeated seal for a day that already has one, chained correctly, is out of order
	h, d = copyDir(t, dir)
	l = sealLines(t, d)
	var s struct {
		Day, SHA256 string
		Lines       int
	}
	json.Unmarshal([]byte(l[2]), &s)
	again, _ := json.Marshal(map[string]any{"day": s.Day, "lines": s.Lines, "sha256": s.SHA256, "prev": sum(l[2] + "x")})
	again, _ = json.Marshal(map[string]any{"day": s.Day, "lines": s.Lines + 1, "sha256": s.SHA256, "prev": sum(l[2])})
	f, _ := os.OpenFile(filepath.Join(d, sealsName), os.O_APPEND|os.O_WRONLY, 0)
	f.Write(append(again, '\n'))
	f.Close()
	if w := why(h, "2026-10-03"); w != "seal is out of order or repeated" {
		t.Errorf("repeated day: %q", w)
	}
	if rs, ok := Verify(h, clock); ok {
		t.Errorf("a repeated day passed: %v", rs)
	}
	// a symlinked day names the cause; an oversized sealed day says so
	if runtime.GOOS != "windows" {
		h, d = copyDir(t, dir)
		os.Remove(filepath.Join(d, "2026-10-02.jsonl"))
		os.Symlink(filepath.Join(d, "2026-10-01.jsonl"), filepath.Join(d, "2026-10-02.jsonl"))
		if w := why(h, "2026-10-02"); w != "file cannot be read: not a regular file" {
			t.Errorf("symlinked day: %q", w)
		}
	}
	old := dayMaxBytes
	dayMaxBytes = 4
	defer func() { dayMaxBytes = old }()
	h, _ = copyDir(t, dir)
	if w := why(h, "2026-10-03"); w != "file cannot be read: too large" {
		t.Errorf("oversized day: %q", w)
	}
}

// Protects the seal file's strictness: a line that is not exactly a seal or an anchor is broken and named, never half-trusted.
func TestMalformedSealLinesAreBroken(t *testing.T) {
	a64 := strings.Repeat("a", 64)
	for name, line := range map[string]string{
		"no prev":           `{"day":"2026-10-01","lines":1,"sha256":"` + a64 + `"}`,
		"prev not hex":      `{"day":"2026-10-01","lines":1,"sha256":"` + a64 + `","prev":"zz"}`,
		"prev 65 chars":     `{"day":"2026-10-01","lines":1,"sha256":"` + a64 + `","prev":"` + a64 + `a"}`,
		"sha not hex":       `{"day":"2026-10-01","lines":1,"sha256":"` + strings.Repeat("g", 64) + `","prev":""}`,
		"sha 65 chars":      `{"day":"2026-10-01","lines":1,"sha256":"` + a64 + `a","prev":""}`,
		"sha with a prefix": `{"day":"2026-10-01","lines":1,"sha256":"x` + a64 + `","prev":""}`,
		"day with a suffix": `{"day":"2026-10-01x","lines":1,"sha256":"` + a64 + `","prev":""}`,
		"day with a prefix": `{"day":"x2026-10-01","lines":1,"sha256":"` + a64 + `","prev":""}`,
		"negative lines":    `{"day":"2026-10-01","lines":-1,"sha256":"` + a64 + `","prev":""}`,
		"no lines":          `{"day":"2026-10-01","sha256":"` + a64 + `","prev":""}`,
		"no day":            `{"lines":1,"sha256":"` + a64 + `","prev":""}`,
		"unknown field":     `{"day":"2026-10-01","lines":1,"sha256":"` + a64 + `","prev":"","extra":1}`,
		"anchor and day":    `{"pruned_through":"2026-10-01","day":"2026-10-01","prev":""}`,
		"anchor and lines":  `{"pruned_through":"2026-10-01","lines":1,"prev":""}`,
		"anchor and sha":    `{"pruned_through":"2026-10-01","sha256":"` + a64 + `","prev":""}`,
		"anchor bad day":    `{"pruned_through":"2026-10-01x","prev":""}`,
		"seal and anchor":   `{"day":"2026-10-01","lines":1,"sha256":"` + a64 + `","pruned_through":"2026-10-01","prev":""}`,
		"empty object":      `{}`,
		"not an object":     `[1]`,
		"trailing text":     `{"pruned_through":"2026-10-01","prev":""} x`,
	} {
		home, dir := logWith(t, nil)
		os.WriteFile(filepath.Join(dir, sealsName), []byte(line+"\n"), 0o600)
		rs, ok := Verify(home, at("2026-10-05T00:00:00Z"))
		if ok || len(rs) == 0 || rs[0].Day != "seals.jsonl" || rs[0].Result != resultBroken {
			t.Errorf("%s: %v ok=%v", name, rs, ok)
		}
	}
	// the well-formed shapes pass the same parser, so the table above is not rejecting everything
	home, dir := logWith(t, nil)
	good := `{"pruned_through":"2026-10-01","prev":""}`
	os.WriteFile(filepath.Join(dir, sealsName), []byte(good+"\n"), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T00:00:00Z")); !ok {
		t.Errorf("a well-formed anchor alone: %v", rs)
	}
	// the longest line allowed passes the length check; one byte more is a fault
	pad := func(n int) string {
		base := `{"pruned_through":"2026-10-01","prev":"","p":""}`
		return base
	}
	_ = pad
	line := `{"pruned_through":"2026-10-01","prev":""}` + strings.Repeat(" ", sealLineMax-len(good))
	os.WriteFile(filepath.Join(dir, sealsName), []byte(line+"\n"), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T00:00:00Z")); !ok {
		t.Errorf("a line of exactly %d bytes: %v", sealLineMax, rs)
	}
	os.WriteFile(filepath.Join(dir, sealsName), []byte(line+" \n"), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T00:00:00Z")); ok {
		t.Errorf("a line of %d bytes passed: %v", sealLineMax+1, rs)
	}
}

// Protects two sealers at once (the first event of a day and the daemon): an identical repeated seal line is ignored, a different one is not.
func TestIdenticalDuplicateSealIsTolerated(t *testing.T) {
	home, dir := logWith(t, threeDays)
	Seal(home, at("2026-10-05T00:00:00Z"))
	l := sealLines(t, dir)
	os.WriteFile(filepath.Join(dir, sealsName), []byte(l[0]+"\n"+l[0]+"\n"+l[1]+"\n"+l[2]+"\n"), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T12:00:00Z")); !ok {
		t.Errorf("an identical repeated seal: %v", rs)
	}
	os.WriteFile(filepath.Join(dir, sealsName), []byte(l[0]+"\n"+l[1]+"\n"+l[0]+"\n"+l[2]+"\n"), 0o600) // not adjacent
	if rs, ok := Verify(home, at("2026-10-05T12:00:00Z")); ok {
		t.Errorf("a repeated seal that is not the line before: %v", rs)
	}
}

// Protects the order of the output and which file a day reads from.
func TestVerifyOrderAndPlainBeatsGzip(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "{\"a\":1}\n", "2026-10-03.jsonl": "{\"c\":1}\n"})
	Seal(home, at("2026-10-05T00:00:00Z"))
	os.WriteFile(filepath.Join(dir, "2026-09-20.jsonl"), []byte("{}\n"), 0o600) // closed, older than every seal: stays unsealed, listed first
	os.WriteFile(filepath.Join(dir, "2026-13-45.jsonl"), []byte("{}\n"), 0o600) // not a date: ignored
	rs, ok := Verify(home, at("2026-10-05T12:00:00Z"))
	var days []string
	for _, r := range rs {
		days = append(days, r.Day)
	}
	if !ok || strings.Join(days, " ") != "2026-09-20 2026-10-01 2026-10-03" {
		t.Errorf("results %v ok=%v", rs, ok)
	}
	// both forms of one day (a crashed gzip): the plain file is the one checked
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write([]byte("something else\n"))
	zw.Close()
	os.WriteFile(filepath.Join(dir, "2026-10-01.jsonl.gz"), gz.Bytes(), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T12:00:00Z")); !ok {
		t.Errorf("plain file ignored for its gzip twin: %v", rs)
	}
}

// Protects the counts: a file with no final newline still counts its last line, and an empty one has none.
func TestHashDayLinesAndExactCap(t *testing.T) {
	_, dir := logWith(t, map[string]string{"a.jsonl": "{}\n{}", "b.jsonl": "", "c.jsonl": "{}\n"})
	for name, want := range map[string]int{"a.jsonl": 2, "b.jsonl": 0, "c.jsonl": 1} {
		if _, n, err := hashDay(filepath.Join(dir, name)); err != nil || n != want {
			t.Errorf("%s: %d lines, %v; want %d", name, n, err, want)
		}
	}
	old := dayMaxBytes
	dayMaxBytes = 8
	defer func() { dayMaxBytes = old }()
	os.WriteFile(filepath.Join(dir, "d.jsonl"), []byte("12345678"), 0o600)
	if _, _, err := hashDay(filepath.Join(dir, "d.jsonl")); err != nil {
		t.Errorf("a file of exactly the cap: %v", err)
	}
	os.WriteFile(filepath.Join(dir, "e.jsonl"), []byte("123456789"), 0o600)
	if _, _, err := hashDay(filepath.Join(dir, "e.jsonl")); err == nil {
		t.Errorf("a file one byte over the cap was read")
	}
	dayMaxBytes = 256 // the compressed file must fit under the cap too
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write(bytes.Repeat([]byte("0"), 256))
	zw.Close()
	os.WriteFile(filepath.Join(dir, "f.jsonl.gz"), buf.Bytes(), 0o600)
	if _, _, err := hashDay(filepath.Join(dir, "f.jsonl.gz")); err != nil {
		t.Errorf("a gzip that expands to exactly the cap: %v", err)
	}
	buf.Reset()
	zw = gzip.NewWriter(&buf)
	zw.Write(bytes.Repeat([]byte("0"), 257))
	zw.Close()
	os.WriteFile(filepath.Join(dir, "g.jsonl.gz"), buf.Bytes(), 0o600)
	if _, _, err := hashDay(filepath.Join(dir, "g.jsonl.gz")); err == nil {
		t.Errorf("a gzip that expands one byte past the cap was read")
	}
}

// Protects the daemon's hourly run and `canon log seal` on an install with no log, a busy lock or a linked seal file.
func TestMaintainAndSealEdgeCases(t *testing.T) {
	empty := t.TempDir()
	if err := Maintain(empty, at("2026-10-05T00:00:00Z"), "daemon"); err != nil {
		t.Errorf("no events folder yet is not an error: %v", err)
	}
	if n, err := Seal(empty, at("2026-10-05T00:00:00Z")); n != 0 || err != nil {
		t.Errorf("seal with no events folder: %d %v", n, err)
	}
	if n, err := Seal("", at("2026-10-05T00:00:00Z")); n != 0 || err == nil {
		t.Errorf("seal with no home: %d %v", n, err)
	}
	home, dir := logWith(t, threeDays)
	os.WriteFile(filepath.Join(dir, lockName), nil, 0o600)
	if n, err := Seal(home, at("2026-10-05T00:00:00Z")); n != 0 || err != ErrBusy {
		t.Errorf("seal under a fresh lock: %d %v", n, err)
	}
	os.Remove(filepath.Join(dir, lockName))
	if runtime.GOOS == "windows" {
		return
	}
	// a linked seal file: nothing is written through it, and nothing is pruned that an anchor could not record
	outside := filepath.Join(t.TempDir(), "target")
	os.WriteFile(outside, []byte("keep\n"), 0o600)
	os.Symlink(outside, filepath.Join(dir, sealsName))
	os.WriteFile(filepath.Join(dir, "2020-01-01.jsonl"), []byte("{}\n"), 0o600)
	if err := Maintain(home, at("2026-10-05T00:00:00Z"), "tkt"); err == nil {
		t.Errorf("maintenance with a linked seal file must report it")
	}
	if b, _ := os.ReadFile(outside); string(b) != "keep\n" {
		t.Errorf("a seal was written through the link: %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "2020-01-01.jsonl")); err != nil {
		t.Errorf("a day was pruned with no way to record it")
	}
	if n, err := Seal(home, at("2026-10-05T00:00:00Z")); n != 0 || err == nil {
		t.Errorf("seal with a linked seal file: %d %v", n, err)
	}
}

// Protects the order inside a prune: the pruned_through record is written first, so if it cannot be written nothing is removed.
func TestPruneWritesTheAnchorBeforeRemoving(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs a read-only file the account cannot write")
	}
	home, dir := logWith(t, map[string]string{"2020-01-01.jsonl": "{}\n"})
	os.WriteFile(filepath.Join(dir, sealsName), nil, 0o400)
	if err := Maintain(home, at("2026-10-05T00:00:00Z"), "tkt"); err == nil {
		t.Errorf("a seal file that cannot be written must be reported")
	}
	if _, err := os.Stat(filepath.Join(dir, "2020-01-01.jsonl")); err != nil {
		t.Errorf("a day was removed although its anchor was not written")
	}
}

// Protects an anchor that names a day that still exists, exactly: the day itself is the lie, the next day is not.
func TestAnchorBoundaryDay(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-02.jsonl": "{}\n"})
	os.WriteFile(filepath.Join(dir, sealsName), []byte(`{"pruned_through":"2026-10-02","prev":""}`+"\n"), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T00:00:00Z")); ok {
		t.Errorf("a day equal to pruned_through still exists: %v", rs)
	}
	os.WriteFile(filepath.Join(dir, sealsName), []byte(`{"pruned_through":"2026-10-01","prev":""}`+"\n"), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T00:00:00Z")); !ok {
		t.Errorf("a day after pruned_through is fine: %v", rs)
	}
}

// Protects the event writer's care for the log: a failed maintenance on a new day is noted in emit-errors.log, a busy one is not.
func TestEmitNotesAFailedMaintenance(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	home, dir := logWith(t, nil)
	t.Setenv("CANON_EVENTS_CLOCK", "2026-10-05T12:00:00Z")
	os.WriteFile(filepath.Join(dir, lockName), nil, 0o600) // another run is working: not a failure
	if err := Emit(home, "ticket.closed", "tkt", "/p", map[string]string{"ticket": "t-1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "emit-errors.log")); err == nil {
		t.Errorf("a busy maintenance was noted as an error")
	}
	os.Remove(filepath.Join(dir, lockName))
	os.Symlink(filepath.Join(t.TempDir(), "x"), filepath.Join(dir, sealsName))
	t.Setenv("CANON_EVENTS_CLOCK", "2026-10-06T12:00:00Z") // a new day
	Emit(home, "ticket.closed", "tkt", "/p", map[string]string{"ticket": "t-2"})
	if b, err := os.ReadFile(filepath.Join(dir, "emit-errors.log")); err != nil || len(b) == 0 {
		t.Errorf("a failed maintenance left no note: %v", err)
	}
	// and the event itself was written
	if ev, ok := Latest(home, "ticket.closed", "/p", nil); !ok || ev.Data["ticket"] != "t-2" {
		t.Errorf("the event was lost: %+v", ev)
	}
}

// Protects the gzip step's cleanup: a day that does not match its seal leaves no temporary file behind.
func TestGzipLeavesNoTemporaryFile(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "{\"a\":1}\n"})
	Seal(home, at("2026-10-05T00:00:00Z"))
	os.WriteFile(filepath.Join(dir, "2026-10-01.jsonl"), []byte("{\"a\":2}\n"), 0o600)
	if err := Maintain(home, at("2026-10-20T00:00:00Z"), "tkt"); err == nil {
		t.Errorf("a changed day must be reported")
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "*.tmp.gz")); len(left) != 0 {
		t.Errorf("temporary files left: %v", left)
	}
}

// Protects verify on an install that has no log yet (a new machine): nothing to check is not a failure.
func TestVerifyWithNoLog(t *testing.T) {
	if rs, ok := Verify(t.TempDir(), at("2026-10-05T00:00:00Z")); !ok || len(rs) != 0 {
		t.Errorf("no events folder: %v ok=%v", rs, ok)
	}
}

// Protects the written format docs/plugins.md promises: the exact key names, in order, of a seal and an anchor.
func TestWrittenSealFormat(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2020-01-01.jsonl": "{}\n{}\n"})
	setRetention(t, home, 30)
	if err := Maintain(home, at("2026-10-05T00:00:00Z"), "tkt"); err != nil {
		t.Fatal(err)
	}
	l := sealLines(t, dir)
	want0 := `{"day":"2020-01-01","lines":2,"sha256":"` + sum("{}\n{}\n") + `","prev":""}`
	want1 := `{"pruned_through":"2020-01-01","prev":"` + sum(want0) + `"}`
	if len(l) != 2 || l[0] != want0 || l[1] != want1 {
		t.Errorf("seal lines = %q\nwant %q and %q", l, want0, want1)
	}
}

// Protects reading the seal file as written by another tool or edited by hand: no final newline is still a line, an empty day seals and
// verifies, and a blank line is a fault.
func TestSealFileEdgeShapes(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "", "2026-10-02.jsonl": "{}\n"})
	Seal(home, at("2026-10-05T00:00:00Z"))
	if rs, ok := Verify(home, at("2026-10-05T12:00:00Z")); !ok || len(rs) != 2 || rs[0].Result != resultIntact {
		t.Fatalf("an empty sealed day: %v", rs)
	}
	l := sealLines(t, dir)
	os.WriteFile(filepath.Join(dir, sealsName), []byte(l[0]+"\n"+l[1]), 0o600) // no final newline
	if rs, ok := Verify(home, at("2026-10-05T12:00:00Z")); !ok || len(rs) != 2 || rs[1].Result != resultIntact {
		t.Errorf("a last seal with no newline was dropped: %v", rs)
	}
	os.WriteFile(filepath.Join(dir, sealsName), []byte(l[0]+"\n\n"+l[1]+"\n"), 0o600)
	if rs, ok := Verify(home, at("2026-10-05T12:00:00Z")); ok {
		t.Errorf("a blank line in the seal file passed: %v", rs)
	}
}

// Protects the reason given for a bad seal file, a linked events folder and a day that cannot be read.
func TestVerifyReasonsForFileFaults(t *testing.T) {
	reason := func(h string) string {
		rs, ok := Verify(h, at("2026-10-05T12:00:00Z"))
		if ok || len(rs) == 0 {
			return "ok"
		}
		return rs[0].Day + ": " + rs[0].Why
	}
	h, d := logWith(t, nil)
	os.WriteFile(filepath.Join(d, sealsName), bytes.Repeat([]byte("x"), sealsMax+1), 0o600)
	if got := reason(h); got != "seals.jsonl: is larger than 4 MB" {
		t.Errorf("big seal file: %q", got)
	}
	if runtime.GOOS != "windows" {
		h, d = logWith(t, nil)
		os.Symlink(filepath.Join(t.TempDir(), "x"), filepath.Join(d, sealsName))
		if got := reason(h); got != "seals.jsonl: is not a regular file" {
			t.Errorf("linked seal file: %q", got)
		}
		h = t.TempDir()
		os.Symlink(t.TempDir(), filepath.Join(h, "events"))
		if got := reason(h); !strings.Contains(got, "events is not a folder") {
			t.Errorf("linked events folder: %q", got)
		}
		if n, err := Seal(h, at("2026-10-05T00:00:00Z")); n != 0 || err == nil || !strings.Contains(err.Error(), "events is not a folder") {
			t.Errorf("seal through a linked events folder: %d %v", n, err)
		}
		if os.Geteuid() != 0 {
			h, d = logWith(t, map[string]string{"2026-10-01.jsonl": "{}\n"})
			Seal(h, at("2026-10-05T00:00:00Z"))
			os.Chmod(filepath.Join(d, "2026-10-01.jsonl"), 0)
			defer os.Chmod(filepath.Join(d, "2026-10-01.jsonl"), 0o600)
			if got := reason(h); got != "2026-10-01: file cannot be read: unreadable" {
				t.Errorf("unreadable day: %q", got)
			}
		}
	}
	if _, err := Seal("", at("2026-10-05T00:00:00Z")); err == nil || !strings.Contains(err.Error(), "CANON_HOME") {
		t.Errorf("seal with no home: %v", err)
	}
	if !strings.Contains(ErrBusy.Error(), "another run") {
		t.Errorf("ErrBusy reads %q", ErrBusy)
	}
	h, d = logWith(t, map[string]string{"2026-10-02.jsonl": "{}\n"})
	os.WriteFile(filepath.Join(d, sealsName), []byte(`{"pruned_through":"2026-10-02","prev":""}`+"\n"), 0o600)
	if got := reason(h); got != "2026-10-02: present although the log was pruned through 2026-10-02" {
		t.Errorf("anchor lie: %q", got)
	}
}

// Protects Admin > Logging > Verify (t-6278): a tampered seal line made one day print `broken` then `intact`, so the totals passed the day count.
func TestVerifyOneResultPerDayWorstWins(t *testing.T) {
	home, dir := logWith(t, threeDays)
	if _, err := Seal(home, at("2026-10-05T00:00:00Z")); err != nil {
		t.Fatal(err)
	}
	l := sealLines(t, dir)
	l[1] = strings.Replace(l[1], `"lines":1`, `"lines":9`, 1) // day 2 mismatches its seal; day 3's seal no longer chains
	os.WriteFile(filepath.Join(dir, sealsName), []byte(strings.Join(l, "\n")+"\n"), 0o600)
	rs, ok := Verify(home, at("2026-10-05T12:00:00Z"))
	if ok || len(rs) != 3 {
		t.Fatalf("want 3 results (one per day) and not ok, got %v %v", rs, ok)
	}
	for _, d := range []string{"2026-10-02", "2026-10-03"} {
		if r, _ := find(rs, d); r.Result != resultBroken {
			t.Errorf("%s = %v, want broken", d, r)
		}
	}
}

// Protects Verify under the log lock (t-6278): a gzip or prune in flight must give "busy", never a false broken or missing.
func TestVerifyIsBusyWhileLocked(t *testing.T) {
	home, dir := logWith(t, threeDays)
	Seal(home, at("2026-10-05T00:00:00Z"))
	os.WriteFile(filepath.Join(dir, lockName), nil, 0o600)
	os.Remove(filepath.Join(dir, "2026-10-02.jsonl")) // would read as missing without the lock
	rs, ok := Verify(home, at("2026-10-05T12:00:00Z"))
	if ok || len(rs) != 1 || rs[0].Result != resultBusy {
		t.Fatalf("a locked log must report one busy line, got %v %v", rs, ok)
	}
	os.Remove(filepath.Join(dir, lockName))
	if rs, _ := Verify(home, at("2026-10-05T12:00:00Z")); func() bool { r, _ := find(rs, "2026-10-02"); return r.Result != resultMiss }() {
		t.Errorf("without the lock the gone day is missing, got %v", rs)
	}
	if _, err := os.Stat(filepath.Join(dir, lockName)); err == nil {
		t.Error("Verify left the lock behind")
	}
}

// Protects the daily seal (t-6278): one unreadable closed day must not stop the days after it from being sealed.
func TestSealPastAnUnreadableDay(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "{}\n", "2026-10-03.jsonl": "{}\n"})
	os.Symlink(filepath.Join(t.TempDir(), "nowhere"), filepath.Join(dir, "2026-10-02.jsonl"))
	n, err := Seal(home, at("2026-10-06T00:00:00Z"))
	if err == nil || !strings.Contains(err.Error(), "2026-10-02") {
		t.Fatalf("the error must name the bad day, got %v", err)
	}
	if n != 2 {
		t.Errorf("sealed %d days, want the 2 readable ones", n)
	}
}

// Protects the gzip step (t-6278): a link planted where a .jsonl.gz should be is never followed or written through.
func TestSymlinkInPlaceOfGzIsRefused(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "{\"a\":1}\n"})
	Seal(home, at("2026-10-03T00:00:00Z"))
	outside := filepath.Join(t.TempDir(), "secret.txt")
	os.WriteFile(outside, []byte("do not read\n"), 0o600)
	gz := filepath.Join(dir, "2026-10-01.jsonl.gz")
	os.Symlink(outside, gz)
	Maintain(home, at("2026-10-20T00:00:00Z"), "tkt")
	if b, _ := os.ReadFile(outside); string(b) != "do not read\n" {
		t.Errorf("the link target was written through: %q", b)
	}
	if fi, err := os.Lstat(gz); err != nil || !fi.Mode().IsRegular() {
		t.Errorf("the link must be replaced by the real .gz, not followed: %v %v", fi, err)
	}
	if rs, ok := Verify(home, at("2026-10-20T12:00:00Z")); !ok {
		t.Errorf("the replaced day should verify, got %v", rs)
	}
	// with no plain file to gzip, a link standing in for the .gz is read as nothing and Verify says broken
	os.Remove(gz)
	os.Symlink(outside, gz)
	if rs, ok := Verify(home, at("2026-10-20T12:00:00Z")); ok {
		t.Errorf("a linked .gz must not verify, got %v", rs)
	} else if r, _ := find(rs, "2026-10-01"); r.Result != resultBroken || strings.Contains(r.Why, "do not read") {
		t.Errorf("linked .gz = %v", r)
	}
}

// Protects the gzip step (t-6278): a day older than 7 days with no seal is never gzipped (the sealed-only rule, outside the 7-day window).
func TestOldUnsealedDayIsNeverGzipped(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-05.jsonl": "{}\n"})
	Seal(home, at("2026-10-07T00:00:00Z"))
	os.WriteFile(filepath.Join(dir, "2026-09-20.jsonl"), []byte("{}\n"), 0o600) // older than the newest seal: the sealer skips it
	if err := Maintain(home, at("2026-10-20T00:00:00Z"), "tkt"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-09-20.jsonl")); err != nil {
		t.Errorf("the unsealed day is gone: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-09-20.jsonl.gz")); err == nil {
		t.Error("an unsealed day was gzipped")
	}
}

// Protects Latest (t-6278): it reads a gunzipped day only up to dayMaxBytes+1, so a bomb cannot be read whole.
func TestLatestStopsAtTheByteBound(t *testing.T) {
	old := dayMaxBytes
	dayMaxBytes = 1 << 10
	defer func() { dayMaxBytes = old }()
	mk := func(n string) string {
		return `{"schema":1,"id":"aaaaaaaaaaaaaaaa","ts":"2026-10-01T09:00:00.000Z","kind":"github.synced","source":"tkt","project":"/p","data":{"count":"` + n + `"}}` + "\n"
	}
	var raw bytes.Buffer
	raw.WriteString(mk("1"))
	raw.WriteString(strings.Repeat("x\n", 2<<10)) // past the bound
	raw.WriteString(mk("2"))
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write(raw.Bytes())
	zw.Close()
	home, dir := logWith(t, nil)
	os.WriteFile(filepath.Join(dir, "2026-10-01.jsonl.gz"), gz.Bytes(), 0o600)
	ev, ok := Latest(home, "github.synced", "/p", nil)
	if !ok || ev.Data["count"] != "1" {
		t.Errorf("Latest read past the bound: %+v %v", ev, ok)
	}
}
