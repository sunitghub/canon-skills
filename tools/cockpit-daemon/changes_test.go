package main

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// t-5a4b: the change engine — baseline at first Start, comparison later, all without git.

func writeF(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// bumpMTime makes a rewrite visible to the quick size+mtime check even on coarse clocks.
func bumpMTime(t *testing.T, root, rel string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	later := time.Now().Add(5 * time.Second)
	if err := os.Chtimes(p, later, later); err != nil {
		t.Fatal(err)
	}
}

func byPath(res *changesResult) map[string]changeFile {
	m := map[string]changeFile{}
	for _, f := range res.Files {
		m[f.Path] = f
	}
	return m
}

func treeListing(t *testing.T, root string) string {
	t.Helper()
	var out []string
	filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil {
			rel, _ := filepath.Rel(root, p)
			out = append(out, rel)
		}
		return nil
	})
	sort.Strings(out)
	return strings.Join(out, "\n")
}

func TestChangesAddModifyDeleteRename(t *testing.T) {
	root, store := t.TempDir(), t.TempDir()
	writeF(t, root, "brief.md", "one\ntwo\nthree\n")
	writeF(t, root, "keep.md", "same\n")
	writeF(t, root, "old-name.md", "moved content\n")
	writeF(t, root, "gone.md", "delete me\n")
	writeF(t, root, "touched.md", "only the clock changes\n")
	if _, err := takeBaseline(root, store); err != nil {
		t.Fatal(err)
	}

	writeF(t, root, "brief.md", "one\nTWO\nthree\nfour\n") // 2 lines added, 1 removed
	bumpMTime(t, root, "brief.md")
	os.Remove(filepath.Join(root, "gone.md"))
	writeF(t, root, "new.md", "brand new\n")
	os.Rename(filepath.Join(root, "old-name.md"), filepath.Join(root, "renamed.md"))
	bumpMTime(t, root, "touched.md") // mtime only, content identical

	res, err := compareBaseline(root, store)
	if err != nil {
		t.Fatal(err)
	}
	got := byPath(res)
	if !res.Tracked || !res.Complete || res.Total != 4 {
		t.Fatalf("tracked=%v complete=%v total=%d, want true/true/4: %+v", res.Tracked, res.Complete, res.Total, res.Files)
	}
	if f := got["brief.md"]; f.Status != "modified" || f.AddedLines != 2 || f.Removed != 1 || !f.CanRestore {
		t.Fatalf("brief.md = %+v, want modified +2 -1 restorable", f)
	}
	if f := got["gone.md"]; f.Status != "deleted" || !f.CanRestore {
		t.Fatalf("gone.md = %+v, want deleted restorable", f)
	}
	if f := got["new.md"]; f.Status != "added" {
		t.Fatalf("new.md = %+v, want added", f)
	}
	if f := got["renamed.md"]; f.Status != "renamed" || f.From != "old-name.md" {
		t.Fatalf("renamed.md = %+v, want renamed from old-name.md", f)
	}
	for _, unchanged := range []string{"keep.md", "touched.md", "old-name.md"} {
		if _, ok := got[unchanged]; ok {
			t.Fatalf("%s reported but it did not change", unchanged)
		}
	}
	if _, err := os.Stat(filepath.Join(store, "changes.json")); err != nil {
		t.Fatalf("changes.json not written: %v", err)
	}
}

func TestChangesIgnoredSecretsSymlinksAndOutsideWrites(t *testing.T) {
	root, store := t.TempDir(), t.TempDir()
	writeF(t, root, "doc.md", "hello\n")
	writeF(t, root, ".env", "API_KEY=super-secret\n")
	writeF(t, root, "id_rsa", "PRIVATE KEY\n")
	writeF(t, root, "node_modules/pkg/index.js", "x\n")
	writeF(t, root, ".tickets/t-abcd/ticket.md", "t\n")
	writeF(t, root, ".claude/settings.json", "{}\n")
	writeF(t, root, "~$Budget.xlsx", "lock\n")
	writeF(t, root, ".DS_Store", "junk\n")
	outside := t.TempDir()
	writeF(t, outside, "secret.txt", "outside the folder\n")
	linked := os.Symlink(outside, filepath.Join(root, "escape")) == nil
	before := treeListing(t, root)

	b, err := takeBaseline(root, store)
	if err != nil {
		t.Fatal(err)
	}
	if treeListing(t, root) != before {
		t.Fatal("takeBaseline wrote something into the project folder")
	}
	for _, ignored := range []string{"node_modules/pkg/index.js", ".tickets/t-abcd/ticket.md", ".claude/settings.json", "~$Budget.xlsx", ".DS_Store", "escape/secret.txt"} {
		if _, ok := b.Files[ignored]; ok {
			t.Fatalf("%s was tracked, want ignored", ignored)
		}
	}
	if linked && b.Skipped["symlink"] == 0 {
		t.Fatalf("symlink not counted as skipped: %v", b.Skipped)
	}
	if b.Skipped["ignored"] == 0 {
		t.Fatalf("ignored entries not counted: %v", b.Skipped)
	}
	if b.Files[".env"].Copy || b.Files[".env"].Hash == "" {
		t.Fatalf(".env = %+v, want hashed and NOT copied", b.Files[".env"])
	}
	if b.Files["id_rsa"].Copy {
		t.Fatal("id_rsa content was copied into the store")
	}
	if !b.Files["doc.md"].Copy {
		t.Fatal("doc.md original was not kept")
	}
	// No secret text anywhere in the store.
	filepath.WalkDir(store, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			data, _ := os.ReadFile(p)
			if strings.Contains(string(data), "super-secret") || strings.Contains(string(data), "PRIVATE KEY") {
				t.Fatalf("secret content found in the store at %s", p)
			}
		}
		return nil
	})
	// A change to a secret is still reported (by hash) but is not restorable.
	writeF(t, root, ".env", "API_KEY=rotated\n")
	bumpMTime(t, root, ".env")
	res, _ := compareBaseline(root, store)
	if f := byPath(res)[".env"]; f.Status != "modified" || f.CanRestore {
		t.Fatalf(".env change = %+v, want modified and not restorable", f)
	}
}

func TestChangesBaselineIsFixedAtFirstStart(t *testing.T) {
	root, store := t.TempDir(), t.TempDir()
	writeF(t, root, "a.md", "v1\n")
	b1, _ := ensureBaseline(root, store)
	writeF(t, root, "a.md", "v2 — after the first start\n")
	writeF(t, root, "b.md", "later\n")
	b2, err := ensureBaseline(root, store) // a resumed session
	if err != nil {
		t.Fatal(err)
	}
	if !b1.Taken.Equal(b2.Taken) || len(b2.Files) != 1 || b2.Files["a.md"].Hash != b1.Files["a.md"].Hash {
		t.Fatalf("baseline changed on the second ensure: %+v vs %+v", b1.Files, b2.Files)
	}
}

func TestChangesUntrackedWithoutBaseline(t *testing.T) {
	res, err := compareBaseline(t.TempDir(), t.TempDir())
	if err != nil || res.Tracked || res.Note == "" || res.Files == nil {
		t.Fatalf("no-baseline compare = %+v, %v, want untracked with a note and an empty list", res, err)
	}
}

func TestChangesLimitsFailOpenAndSayIncomplete(t *testing.T) {
	root, store := t.TempDir(), t.TempDir()
	for i := 0; i < 6; i++ {
		writeF(t, root, "f"+string(rune('a'+i))+".md", "x\n")
	}
	oldMax := changesMaxFiles
	changesMaxFiles = 3
	t.Cleanup(func() { changesMaxFiles = oldMax })
	b, err := takeBaseline(root, store)
	if err != nil || b.Complete || len(b.Files) != 3 || b.Skipped["too-many-files"] != 3 {
		t.Fatalf("baseline over the file cap = complete %v files %d skipped %v err %v", b.Complete, len(b.Files), b.Skipped, err)
	}
	res, _ := compareBaseline(root, store)
	if res.Complete || res.Note == "" {
		t.Fatalf("result over the cap = %+v, want incomplete with a note", res)
	}

	// The walk time budget fails open the same way.
	changesMaxFiles = oldMax
	oldBudget := changesWalkBudget
	changesWalkBudget = time.Nanosecond
	t.Cleanup(func() { changesWalkBudget = oldBudget })
	time.Sleep(time.Millisecond)
	b, err = takeBaseline(root, t.TempDir())
	if err != nil || b.Complete || b.Skipped["time-budget"] == 0 {
		t.Fatalf("baseline over the time budget = complete %v skipped %v err %v", b.Complete, b.Skipped, err)
	}
}

func TestChangesCopyBudgetAndBigFiles(t *testing.T) {
	root, store := t.TempDir(), t.TempDir()
	writeF(t, root, "a.md", strings.Repeat("a", 100))
	writeF(t, root, "b.md", strings.Repeat("b", 100))
	writeF(t, root, "big.txt", strings.Repeat("z", 400)) // over the per-file text cap below
	oldText, oldBudget, oldHash := changesTextMax, changesCopyBudget, changesHashMax
	changesTextMax, changesCopyBudget, changesHashMax = 300, 150, 200
	t.Cleanup(func() { changesTextMax, changesCopyBudget, changesHashMax = oldText, oldBudget, oldHash })
	b, err := takeBaseline(root, store)
	if err != nil {
		t.Fatal(err)
	}
	copies := 0
	for _, f := range b.Files {
		if f.Copy {
			copies++
		}
	}
	if copies != 1 {
		t.Fatalf("copies = %d, want exactly 1 (budget 150 covers one 100-byte file)", copies)
	}
	if b.Files["big.txt"].Copy || b.Files["big.txt"].Hash != "" {
		t.Fatalf("big.txt = %+v, want no copy and no hash (over both caps)", b.Files["big.txt"])
	}
	// A big file's change is still seen, by size/mtime.
	writeF(t, root, "big.txt", strings.Repeat("z", 401))
	res, _ := compareBaseline(root, store)
	if f := byPath(res)["big.txt"]; f.Status != "modified" || f.CanRestore {
		t.Fatalf("big.txt = %+v, want modified, not restorable", f)
	}
}

func TestChangesStorePermissionsAndListCap(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	s := newServer(config{projectRoot: root, stateDir: t.TempDir(), changesHome: home})
	store := s.changesStoreDir(root, "t-ab12")
	if !strings.HasPrefix(store, home) || strings.HasPrefix(store, root) {
		t.Fatalf("store %q must be under changesHome and outside the project", store)
	}
	writeF(t, root, "a.md", "x\n")
	if _, err := takeBaseline(root, store); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		fi, err := os.Stat(filepath.Join(store, "baseline.json"))
		if err != nil || fi.Mode().Perm() != 0o600 {
			t.Fatalf("baseline.json mode = %v (%v), want 0600", fi.Mode().Perm(), err)
		}
		di, _ := os.Stat(filepath.Join(store, "copies"))
		if di.Mode().Perm() != 0o700 {
			t.Fatalf("copies dir mode = %v, want 0700", di.Mode().Perm())
		}
	}
	oldCap := changesListCap
	changesListCap = 2
	t.Cleanup(func() { changesListCap = oldCap })
	for _, n := range []string{"n1.md", "n2.md", "n3.md", "n4.md"} {
		writeF(t, root, n, n+"\n")
	}
	res, _ := compareBaseline(root, store)
	if res.Total != 4 || len(res.Files) != 2 {
		t.Fatalf("list cap: total %d listed %d, want 4 and 2", res.Total, len(res.Files))
	}
}

func TestLineDiffCounts(t *testing.T) {
	for _, c := range []struct {
		a, b     string
		add, rem int
	}{
		{"a\nb\nc", "a\nb\nc", 0, 0},
		{"a\nb\nc", "a\nB\nc\nd", 2, 1},
		{"", "x", 1, 1}, // "" splits to one empty line
		{"a\nb", "b\na", 1, 1},
	} {
		add, rem, ok := lineDiffCounts(c.a, c.b)
		if !ok || add != c.add || rem != c.rem {
			t.Errorf("lineDiffCounts(%q,%q) = +%d -%d ok=%v, want +%d -%d", c.a, c.b, add, rem, ok, c.add, c.rem)
		}
	}
	long := strings.Repeat("l\n", changesDiffLines+5)
	if _, _, ok := lineDiffCounts(long, long); ok {
		t.Fatal("over-long input must report ok=false")
	}
}

// t-5a4b: Restore original puts back only what it holds a copy of, never touches what it doesn't,
// saves what it overwrites, keeps file permissions, and never writes through a link the agent planted.
func TestRestoreOriginal(t *testing.T) {
	root, store := t.TempDir(), t.TempDir()
	writeF(t, root, "brief.md", "original brief\n")
	writeF(t, root, "gone.md", "delete me\n")
	writeF(t, root, "sub/deep.md", "deep original\n")
	writeF(t, root, "same.md", "unchanged\n")
	writeF(t, root, ".env", "SECRET=1\n") // never copied at baseline
	if err := os.Chmod(filepath.Join(root, "brief.md"), 0o640); err != nil && runtime.GOOS != "windows" {
		t.Fatal(err)
	}
	if _, err := takeBaseline(root, store); err != nil {
		t.Fatal(err)
	}
	writeF(t, root, "brief.md", "agent rewrote this\n")
	os.Chmod(filepath.Join(root, "brief.md"), 0o640)
	os.Remove(filepath.Join(root, "gone.md"))
	os.RemoveAll(filepath.Join(root, "sub"))
	writeF(t, root, "made-by-agent.md", "new file\n")
	writeF(t, root, ".env", "SECRET=changed\n")

	got, err := restoreOriginal(root, store)
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != "brief.md,gone.md,sub/deep.md" {
		t.Fatalf("restored %v, want brief.md, gone.md, sub/deep.md (not same.md, .env or the new file)", got)
	}
	for rel, want := range map[string]string{"brief.md": "original brief\n", "gone.md": "delete me\n", "sub/deep.md": "deep original\n",
		"made-by-agent.md": "new file\n", ".env": "SECRET=changed\n"} {
		if b, _ := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel))); string(b) != want {
			t.Errorf("%s = %q, want %q", rel, b, want)
		}
	}
	if runtime.GOOS != "windows" {
		if fi, _ := os.Stat(filepath.Join(root, "brief.md")); fi.Mode().Perm() != 0o640 {
			t.Errorf("restored file mode = %v, want 0640 kept", fi.Mode().Perm())
		}
	}
	// What the restore overwrote is saved, so it can be undone.
	var savedBrief string
	filepath.WalkDir(filepath.Join(store, "before-restore"), func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && d.Name() == "brief.md" {
			b, _ := os.ReadFile(p)
			savedBrief = string(b)
		}
		return nil
	})
	if savedBrief != "agent rewrote this\n" {
		t.Errorf("the overwritten version was not saved: %q", savedBrief)
	}
	// Running it again finds nothing left to restore.
	if again, _ := restoreOriginal(root, store); len(again) != 0 {
		t.Errorf("second restore touched %v", again)
	}
	res, _ := compareBaseline(root, store)
	if m := byPath(res); len(m) != 2 || m["made-by-agent.md"].Status != "added" || m[".env"].Status != "modified" {
		t.Errorf("after restore only the new file and the secret should differ, got %+v", res.Files)
	}
}

func TestRestoreOriginalRefusesLinksOutOfTheFolder(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	root, store, outside := t.TempDir(), t.TempDir(), t.TempDir()
	writeF(t, root, "docs/plan.md", "original plan\n")
	if _, err := takeBaseline(root, store); err != nil {
		t.Fatal(err)
	}
	// The agent replaces the directory with a link to somewhere else.
	os.RemoveAll(filepath.Join(root, "docs"))
	if err := os.Symlink(outside, filepath.Join(root, "docs")); err != nil {
		t.Fatal(err)
	}
	got, err := restoreOriginal(root, store)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("restored through a link: %v", got)
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Fatalf("a file was written outside the folder: %v", entries)
	}
}

func TestRestoreOriginalWithoutBaseline(t *testing.T) {
	if _, err := restoreOriginal(t.TempDir(), t.TempDir()); err == nil {
		t.Fatal("restoring with no baseline must fail, not succeed silently")
	}
}
