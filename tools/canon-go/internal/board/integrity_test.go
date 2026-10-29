package board

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// These tests protect Admin > Integrity and the `sprint complete` gate behind it (t-2af0): which state an install is in, that only a list
// whose hash equals the published pin is ever used, that a changed gate file is found and a hostile list is not followed out of the
// install, and that nothing but a verified release install can block.

var gateFiles = []string{"tools/sprint", "tools/gate-snapshot.sh", "tools/subagent-log.sh", "tools/evidence.sh", "tools/sprint-headless", "tools/sprint-headless-eval", "tools/gate-model.sh"}
var gatePrompts = []string{"agents/canon-reviewer.md", "agents/canon-evaluator.md", "skills/sprint/reference/review.md", "skills/sprint/reference/eval.md", "skills/sprint/reference/shared-gate-protocol.md", "skills/sprint/reference/visual-verify.md"}

type integFx struct {
	t     *testing.T
	root  string
	home  string
	list  []byte
	pin   string
	pinTx string
	deps  integrityDeps
	calls int
	fail  map[string]error // url suffix -> error
	body  map[string][]byte
}

func newIntegFx(t *testing.T) *integFx {
	t.Helper()
	root, home := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "VERSION"), []byte("1.2.3\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{integrityManifest: "manifest\n"}
	for _, p := range append(append([]string{}, gateFiles...), gatePrompts...) {
		files[p] = "content of " + p + "\n"
	}
	list := integrityList{Tag: "v1.2.3", Commit: strings.Repeat("a", 40), GateFiles: gateFiles, GatePrompts: gatePrompts, Files: map[string]string{}}
	for _, p := range gatePrompts[:2] {
		files[p] = "---\nname: " + strings.TrimSuffix(filepath.Base(p), ".md") + "\ndescription: canon's " + map[bool]string{true: "binding", false: "advisory"}[strings.Contains(p, "evaluator")] +
			" gate.\nmodel: claude-sonnet-5\neffort: high\ntools: Read, Grep, Bash\nwrites: report.md\ngraded-by: skills/sprint/reference/review.md\n---\n<!-- canon:agent (managed) -->\nYou are a gate.\nSecond line.\n"
	}
	for p, c := range files {
		full := filepath.Join(root, filepath.FromSlash(p))
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
		list.Files[p] = sha256Hex([]byte(c))
	}
	list.Files["README.md"] = sha256Hex([]byte("anything"))
	raw, _ := json.Marshal(list)
	f := &integFx{t: t, root: root, home: home, list: raw, pin: sha256Hex(raw), fail: map[string]error{}, body: map[string][]byte{}}
	f.pinTx = "# integrity\nv1.2.3 " + f.pin + "\n"
	f.deps = integrityDeps{root: root, home: home, pinURL: "https://pin.test/integrity.txt", assetBase: "https://assets.test", online: true,
		atTag: func(string, string) (bool, bool, error) { return false, true, nil }}
	f.deps.get = func(url string, max int64) ([]byte, error) {
		f.calls++
		if b, ok := f.body[url]; ok && int64(len(b)) > max {
			return nil, fmt.Errorf("larger than %d bytes", max)
		}
		for suffix, err := range f.fail {
			if strings.HasSuffix(url, suffix) {
				return nil, err
			}
		}
		if b, ok := f.body[url]; ok {
			return b, nil
		}
		switch url {
		case "https://pin.test/integrity.txt":
			return []byte(f.pinTx), nil
		case "https://assets.test/v1.2.3/integrity-1.2.3.json":
			return f.list, nil
		}
		return nil, errors.New("HTTP 404")
	}
	return f
}

func (f *integFx) edit(p, content string) {
	f.t.Helper()
	if err := os.WriteFile(filepath.Join(f.root, filepath.FromSlash(p)), []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *integFx) status(r integrityResult, p string) string {
	for _, x := range r.Files {
		if x.Path == p {
			return x.Status
		}
	}
	return "absent"
}

func TestIntegrityVerifiedMatchesEverything(t *testing.T) {
	f := newIntegFx(t)
	r := checkIntegrity(f.deps)
	if r.State != integrityVerified || r.Source != "online" || r.Blocking || r.Match != 14 || r.Total != 14 {
		t.Fatalf("a clean release install: %+v", r)
	}
	for _, g := range gateFiles {
		if f.status(r, g) != "match" {
			t.Errorf("%s: %s", g, f.status(r, g))
		}
	}
	// the list and its pin are saved, readable by the owner only
	lp, pp := f.deps.cachePaths("v1.2.3")
	for _, p := range []string{lp, pp} {
		fi, err := os.Stat(p)
		if err != nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("saved %s: %v %v", p, fi, err)
		}
	}
}

func TestIntegrityOneByteInAGateFileBlocks(t *testing.T) {
	for _, gate := range append(append([]string{}, gateFiles...), gatePrompts...) {
		f := newIntegFx(t)
		f.edit(gate, "content of "+gate+"!\n") // one byte more
		r := checkIntegrity(f.deps)
		if r.State != integrityVerified || !r.Blocking || f.status(r, gate) != "changed" || r.Match != 13 {
			t.Errorf("%s: %+v", gate, r)
		}
		for _, x := range r.Files {
			if x.Path != gate && x.Status != "match" {
				t.Errorf("%s: only %s should differ, %s is %s", gate, gate, x.Path, x.Status)
			}
		}
	}
}

func TestIntegrityMissingAndLinkedGateFile(t *testing.T) {
	f := newIntegFx(t)
	_ = os.Remove(filepath.Join(f.root, "tools/gate-model.sh"))
	_ = os.Remove(filepath.Join(f.root, "tools/evidence.sh"))
	if err := os.Symlink(filepath.Join(f.root, "tools/sprint"), filepath.Join(f.root, "tools/evidence.sh")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	r := checkIntegrity(f.deps)
	if !r.Blocking || f.status(r, "tools/gate-model.sh") != "missing" || f.status(r, "tools/evidence.sh") != "changed" {
		t.Errorf("missing and linked gate files: %+v", r)
	}
}

func TestIntegrityManifestChangeShowsButDoesNotBlock(t *testing.T) {
	f := newIntegFx(t)
	f.edit(integrityManifest, "other\n")
	r := checkIntegrity(f.deps)
	if r.State != integrityVerified || r.Blocking || f.status(r, integrityManifest) != "changed" {
		t.Errorf("a changed programs manifest is shown, never blocking: %+v", r)
	}
}

func TestIntegrityRestoreCommand(t *testing.T) {
	f := newIntegFx(t)
	f.edit("tools/sprint", "x")
	r := checkIntegrity(f.deps)
	if got := r.Files[0].Restore; got != "canon update" {
		t.Errorf("a zip install is put back with canon update, got %q", got)
	}
	if err := os.Mkdir(filepath.Join(f.root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.deps.atTag = func(string, string) (bool, bool, error) { return true, true, nil }
	r = checkIntegrity(f.deps)
	want := "git -C '" + realPath(t, f.root) + "' checkout -- tools/sprint"
	if got := r.Files[0].Restore; got != want {
		t.Errorf("a git install is put back with git checkout, got %q want %q", got, want)
	}
}

func realPath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestIntegrityListMustEqualItsPin(t *testing.T) {
	f := newIntegFx(t)
	f.pinTx = "v1.2.3 " + strings.Repeat("0", 64) + "\n" // the published hash is another file's
	r := checkIntegrity(f.deps)
	if r.State != integrityNotChecked || anyChecked(r) || !strings.Contains(r.Reason, "does not match its published hash") {
		t.Errorf("a list that does not equal its pin must not be used: %+v", r)
	}
	if _, err := os.Stat(filepath.Join(f.home, "integrity")); err == nil {
		t.Error("a refused list was saved")
	}
}

func TestIntegrityPinFileShapes(t *testing.T) {
	// every bad shape carries the REAL pin of the list, so only the shape guards in pinFor can refuse it; with a wrong hash the
	// list-versus-pin comparison would refuse it anyway and the guard would go untested
	probe := newIntegFx(t)
	p := probe.pin
	other := strings.Repeat("c", 64)
	for name, c := range map[string]struct {
		body  string
		state string
	}{
		"no line for the tag":  {"v9.9.9 " + p + "\n", integrityListPending},
		"empty file":           {"", integrityListPending},
		"only comments":        {"# v1.2.3 " + p + "\n", integrityListPending},
		"fourth field":         {"v1.2.3 " + p + " " + p + "\n", integrityNotChecked},
		"three fields":         {"v1.2.3 " + p + " " + strings.Repeat("b", 40) + "\n", integrityNotChecked},
		"short hash":           {"v1.2.3 " + p[:63] + "\n", integrityNotChecked},
		"upper-case hash":      {"v1.2.3 " + strings.ToUpper(p) + "\n", integrityNotChecked},
		"two different hashes": {"v1.2.3 " + p + "\nv1.2.3 " + other + "\n", integrityNotChecked},
		"the other line first": {"v1.2.3 " + other + "\nv1.2.3 " + p + "\n", integrityNotChecked},
		"NUL byte":             {"v1.2.3 " + p + "\x00\n", integrityNotChecked},
		"NUL in a comment":     {"# a\x00b\nv1.2.3 " + p + "\n", integrityNotChecked},
	} {
		f := newIntegFx(t)
		f.pinTx = c.body
		if r := checkIntegrity(f.deps); r.State != c.state || r.Match != 0 {
			t.Errorf("%s: %+v", name, r)
		}
	}
	// a comment line, a blank line and a line for another tag around the real one are fine, and so is the same line twice
	f := newIntegFx(t)
	f.pinTx = "# header\n\nv1.2.2 " + other + "\nv1.2.3 " + f.pin + "\r\nv1.2.3 " + f.pin + "\r\n"
	if r := checkIntegrity(f.deps); r.State != integrityVerified {
		t.Errorf("a clean file with comments, another tag and a repeated line: %+v", r)
	}
}

func TestPinForDirect(t *testing.T) {
	h := strings.Repeat("a", 64)
	if pin, ok, err := pinFor([]byte("v1.0.0 "+h+"\n"), "v1.0.0"); pin != h || !ok || err != nil {
		t.Errorf("one good line: %q %v %v", pin, ok, err)
	}
	for name, body := range map[string]string{"NUL": "v1.0.0 " + h + "\x00", "fourth field": "v1.0.0 " + h + " x", "conflict": "v1.0.0 " + h + "\nv1.0.0 " + strings.Repeat("b", 64)} {
		if _, ok, err := pinFor([]byte(body), "v1.0.0"); ok || err == nil {
			t.Errorf("%s must be an error, got ok=%v err=%v", name, ok, err)
		}
	}
}

func TestIntegrityOfflineUsesTheSavedListOnlyWhileItEqualsItsPin(t *testing.T) {
	f := newIntegFx(t)
	if r := checkIntegrity(f.deps); r.State != integrityVerified {
		t.Fatalf("first check: %+v", r)
	}
	f.fail["integrity.txt"] = errors.New("no network")
	r := checkIntegrity(f.deps)
	if r.State != integrityVerified || r.Source != "cached" {
		t.Errorf("offline with a saved list: %+v", r)
	}
	// the saved list is edited (to match an edited file): it no longer equals its pin and is not used
	lp, _ := f.deps.cachePaths("v1.2.3")
	f.edit("tools/sprint", "edited to run something else\n")
	var l integrityList
	_ = json.Unmarshal(f.list, &l)
	l.Files["tools/sprint"] = sha256Hex([]byte("edited to run something else\n")) // the list is edited to agree with the file
	raw, _ := json.Marshal(l)
	if err := os.WriteFile(lp, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	r = checkIntegrity(f.deps)
	if r.State != integrityNotChecked {
		t.Errorf("a tampered saved list must not be used: %+v", r)
	}
	// no saved list and no network
	if err := os.RemoveAll(filepath.Join(f.home, "integrity")); err != nil {
		t.Fatal(err)
	}
	r = checkIntegrity(f.deps)
	if r.State != integrityNotChecked || !strings.Contains(r.Reason, "no list is saved") {
		t.Errorf("offline with nothing saved: %+v", r)
	}
}

func TestIntegrityCacheFirstSkipsTheNetwork(t *testing.T) {
	f := newIntegFx(t)
	checkIntegrity(f.deps)
	f.calls = 0
	f.deps.online = false
	r := checkIntegrity(f.deps)
	if r.State != integrityVerified || r.Source != "cached" || f.calls != 0 {
		t.Errorf("a saved list answers without the network: %+v calls=%d", r, f.calls)
	}
	f.deps.online = true
	checkIntegrity(f.deps)
	if f.calls == 0 {
		t.Error("an online check must go to the network")
	}
}

func TestIntegrityStatesThatNeverCountOrBlock(t *testing.T) {
	cases := map[string]func(f *integFx){
		"follows main":         func(f *integFx) { _ = os.WriteFile(filepath.Join(f.root, ".canon-track"), []byte("main\n"), 0o644) },
		"no VERSION":           func(f *integFx) { _ = os.Remove(filepath.Join(f.root, "VERSION")) },
		"VERSION is not a tag": func(f *integFx) { f.edit("VERSION", "1.2.3-rc1\n") },
		"HEAD is not the tag":  func(f *integFx) { f.deps.atTag = func(string, string) (bool, bool, error) { return true, false, nil } },
		"git cannot answer": func(f *integFx) {
			f.deps.atTag = func(string, string) (bool, bool, error) { return true, false, errors.New("git") }
		},
	}
	for name, setup := range cases {
		f := newIntegFx(t)
		f.edit("tools/sprint", "edited on purpose")
		setup(f)
		r := checkIntegrity(f.deps)
		if r.State != integrityNotFromRelease || r.Blocking || r.Match != 0 || anyChecked(r) {
			t.Errorf("%s: %+v", name, r)
		}
		if f.calls != 0 {
			t.Errorf("%s: the network was used for an install that has no release", name)
		}
	}
}

func TestIntegrityHostileListIsNotFollowed(t *testing.T) {
	for _, bad := range []string{"../secret", "/etc/passwd", "tools/../../secret", "tools//sprint", "tools/sp rint", "tools\\sprint"} {
		f := newIntegFx(t)
		secret := filepath.Join(filepath.Dir(f.root), "secret")
		_ = os.WriteFile(secret, []byte("s"), 0o644)
		var l integrityList
		_ = json.Unmarshal(f.list, &l)
		l.GateFiles = append(l.GateFiles, bad)
		l.Files[bad] = sha256Hex([]byte("s"))
		raw, _ := json.Marshal(l)
		f.list, f.pinTx = raw, "v1.2.3 "+sha256Hex(raw)+"\n" // the pin matches: the list is genuine but hostile
		r := checkIntegrity(f.deps)
		if r.State != integrityNotChecked || r.Match != 0 || anyChecked(r) || !strings.Contains(r.Reason, bad) {
			t.Errorf("%q: %+v", bad, r)
		}
	}
}

func TestIntegrityListShapes(t *testing.T) {
	for name, mut := range map[string]func(l *integrityList){
		"another tag":     func(l *integrityList) { l.Tag = "v9.9.9" },
		"no files":        func(l *integrityList) { l.Files = map[string]string{} },
		"gate not listed": func(l *integrityList) { delete(l.Files, "tools/sprint") },
		"hash not hex":    func(l *integrityList) { l.Files["tools/sprint"] = "zz" },
	} {
		f := newIntegFx(t)
		var l integrityList
		_ = json.Unmarshal(f.list, &l)
		mut(&l)
		raw, _ := json.Marshal(l)
		f.list, f.pinTx = raw, "v1.2.3 "+sha256Hex(raw)+"\n"
		if r := checkIntegrity(f.deps); r.State != integrityNotChecked || r.Blocking {
			t.Errorf("%s: %+v", name, r)
		}
	}
	f := newIntegFx(t)
	f.list = []byte("not json")
	f.pinTx = "v1.2.3 " + sha256Hex(f.list) + "\n"
	if r := checkIntegrity(f.deps); r.State != integrityNotChecked {
		t.Errorf("a list that is not JSON: %+v", r)
	}
}

func TestIntegrityAssetFetchFailureFallsBackOnlyToAGoodSavedList(t *testing.T) {
	f := newIntegFx(t)
	f.fail["integrity-1.2.3.json"] = errors.New("HTTP 502")
	if r := checkIntegrity(f.deps); r.State != integrityNotChecked || !strings.Contains(r.Reason, "cannot read the list") {
		t.Errorf("no saved list: %+v", r)
	}
	delete(f.fail, "integrity-1.2.3.json")
	checkIntegrity(f.deps) // saves it
	f.fail["integrity-1.2.3.json"] = errors.New("HTTP 502")
	if r := checkIntegrity(f.deps); r.State != integrityVerified || r.Source != "cached" {
		t.Errorf("a saved list covers a failed download: %+v", r)
	}
}

func TestIntegrityRunExitCodesAndOutput(t *testing.T) {
	f := newIntegFx(t)
	var out bytes.Buffer
	if code := integrityRun(false, true, f.deps, &out); code != 0 || !strings.Contains(out.String(), "14 of 14 files match release v1.2.3") || strings.Count(out.String(), "\n") != 1 {
		t.Errorf("a clean verified gate check prints one line and exits 0: %d %q", code, out.String())
	}
	out.Reset()
	if code := integrityRun(false, false, f.deps, &out); code != 0 || !strings.Contains(out.String(), "14 of 14 files match release v1.2.3") {
		t.Errorf("without --gate the summary prints: %d %q", code, out.String())
	}
	out.Reset()
	if code := integrityRun(true, false, f.deps, &out); code != 0 || !strings.Contains(out.String(), `"state":"verified"`) {
		t.Errorf("--json: %d %q", code, out.String())
	}
	f.edit("tools/gate-model.sh", "x")
	f.edit(integrityManifest, "x")
	out.Reset()
	if code := integrityRun(false, true, f.deps, &out); code != 3 || !strings.Contains(out.String(), "differs from release v1.2.3 (12 of 14") ||
		!strings.Contains(out.String(), "tools/gate-model.sh: changed. Put it back: canon update") || strings.Contains(out.String(), integrityManifest) {
		t.Errorf("a changed gate file exits 3 and names only the gate file: %d %q", code, out.String())
	}
	out.Reset()
	if code := integrityRun(false, false, f.deps, &out); code != 0 {
		t.Errorf("without --gate a difference never exits 3: %d", code)
	}
	g := newIntegFx(t)
	g.edit("tools/sprint", "x")
	g.deps.atTag = func(string, string) (bool, bool, error) { return true, false, nil }
	out.Reset()
	if code := integrityRun(false, true, g.deps, &out); code != 0 || !strings.Contains(out.String(), "not-from-release") {
		t.Errorf("a state that is not verified prints its reason and never blocks: %d %q", code, out.String())
	}
}

func TestIntegrityCLIUnknownFlag(t *testing.T) {
	var out, errb bytes.Buffer
	if code := integrityCLI([]string{"--nope"}, &out, &errb); code != 2 || !strings.Contains(errb.String(), "usage") {
		t.Errorf("an unknown flag: %d %q", code, errb.String())
	}
}

func TestShellQuote(t *testing.T) {
	if got := shellQuote("/a b/it's"); got != `'/a b/it'\''s'` {
		t.Errorf("got %s", got)
	}
}

func TestIntegrityRootIsTheToolsFolderParent(t *testing.T) {
	exe, _ := os.Executable()
	if got, want := integrityRoot(), filepath.Dir(filepath.Dir(exe)); got != want {
		t.Errorf("integrityRoot = %q, want the parent of the folder holding the executable, %q", got, want)
	}
}

func TestGitAtTag(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		c := exec.Command("git", append([]string{"-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"}, args...)...)
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	if isGit, at, err := gitAtTag(dir, "v1.2.3"); isGit || !at || err != nil {
		t.Errorf("a folder with no .git is a zip install, counted as at the release: %v %v %v", isGit, at, err)
	}
	git("init", "-q")
	git("commit", "-q", "--allow-empty", "-m", "one")
	if isGit, at, err := gitAtTag(dir, "v1.2.3"); !isGit || at || err != nil {
		t.Errorf("a clone without the tag is not at it: %v %v %v", isGit, at, err)
	}
	git("tag", "v1.2.3")
	if isGit, at, err := gitAtTag(dir, "v1.2.3"); !isGit || !at || err != nil {
		t.Errorf("HEAD at the tag: %v %v %v", isGit, at, err)
	}
	git("commit", "-q", "--allow-empty", "-m", "two")
	if isGit, at, err := gitAtTag(dir, "v1.2.3"); !isGit || at || err != nil {
		t.Errorf("HEAD past the tag is not at it: %v %v %v", isGit, at, err)
	}
}

func TestHttpsGetAgainstATLSServer(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ok", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("0123456789")) })
	mux.HandleFunc("/exact", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(bytes.Repeat([]byte("a"), 10)) })
	mux.HandleFunc("/big", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(bytes.Repeat([]byte("a"), 11)) })
	mux.HandleFunc("/missing", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	mux.HandleFunc("/to-http", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://127.0.0.1:1/x", http.StatusFound)
	})
	mux.HandleFunc("/loop", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/loop", http.StatusFound) })
	mux.HandleFunc("/hop", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/ok", http.StatusFound) })
	srv := httptest.NewTLSServer(mux)
	defer srv.Close()
	get := func(p string) ([]byte, error) { return httpsGetWith(srv.Client(), srv.URL+p, 10) }
	if b, err := get("/ok"); err != nil || string(b) != "0123456789" {
		t.Errorf("a plain 200: %q %v", b, err)
	}
	if b, err := get("/exact"); err != nil || len(b) != 10 {
		t.Errorf("a body exactly at the cap is allowed: %d %v", len(b), err)
	}
	if b, err := get("/big"); err == nil || b != nil || !strings.Contains(err.Error(), "larger than 10 bytes") {
		t.Errorf("a body over the cap is an error, never a cut copy: %q %v", b, err)
	}
	if _, err := get("/missing"); err == nil || !strings.Contains(err.Error(), "HTTP 404") {
		t.Errorf("a 404: %v", err)
	}
	if _, err := get("/to-http"); err == nil || !strings.Contains(err.Error(), "redirect refused") {
		t.Errorf("a redirect to http: %v", err)
	}
	if _, err := get("/loop"); err == nil || !strings.Contains(err.Error(), "redirect refused") {
		t.Errorf("a redirect loop stops after five hops: %v", err)
	}
	if b, err := get("/hop"); err != nil || string(b) != "0123456789" {
		t.Errorf("one https redirect is followed: %q %v", b, err)
	}
	if _, err := httpsGetWith(srv.Client(), "http://127.0.0.1:1/x", 10); err == nil || err.Error() != "not an https address" {
		t.Errorf("a plain http address is refused before any request: %v", err)
	}
}

func TestIntegrityDirectoryWhereAFileBelongsIsChanged(t *testing.T) {
	f := newIntegFx(t)
	p := filepath.Join(f.root, "tools/gate-model.sh")
	_ = os.Remove(p)
	if err := os.Mkdir(p, 0o755); err != nil {
		t.Fatal(err)
	}
	if r := checkIntegrity(f.deps); f.status(r, "tools/gate-model.sh") != "changed" || !r.Blocking {
		t.Errorf("a folder in place of a gate file: %+v", r)
	}
}

func TestIntegrityGroupsAndJSONKeys(t *testing.T) {
	f := newIntegFx(t)
	f.edit("tools/sprint", "x")
	r := checkIntegrity(f.deps)
	want := map[string]string{"tools/sprint": "tools", "agents/canon-reviewer.md": "agents", "skills/sprint/reference/eval.md": "prompts", integrityManifest: "programs"}
	for _, x := range r.Files {
		if g, ok := want[x.Path]; ok && x.Group != g {
			t.Errorf("%s is in group %q, want %q", x.Path, x.Group, g)
		}
		if x.Gate != (x.Path != integrityManifest) {
			t.Errorf("%s gate=%v", x.Path, x.Gate)
		}
	}
	b, _ := json.Marshal(r) // the page reads these names
	for _, k := range []string{`"state":"verified"`, `"tag":"v1.2.3"`, `"source":"online"`, `"match":13`, `"total":14`, `"blocking":true`, `"files":[`, `"path":"tools/sprint"`, `"group":"tools"`, `"gate":true`, `"status":"changed"`, `"restore":"canon update"`} {
		if !strings.Contains(string(b), k) {
			t.Errorf("the JSON lacks %s: %s", k, b)
		}
	}
}

func TestIntegrityReasonsSayWhy(t *testing.T) {
	f := newIntegFx(t)
	f.fail["integrity.txt"] = errors.New("no network")
	if r := checkIntegrity(f.deps); !strings.Contains(r.Reason, "cannot read https://pin.test/integrity.txt (no network)") {
		t.Errorf("offline: %q", r.Reason)
	}
	g := newIntegFx(t)
	g.pinTx = "v9.9.9 " + strings.Repeat("a", 64) + "\n"
	if r := checkIntegrity(g.deps); r.Reason != "v1.2.3 has no line in integrity.txt yet" {
		t.Errorf("pending: %q", r.Reason)
	}
	h := newIntegFx(t)
	h.deps.root = filepath.Join(h.root, "gone")
	if r := checkIntegrity(h.deps); r.State != integrityNotFromRelease || r.Reason != "cannot read the install folder" {
		t.Errorf("no folder: %+v", r)
	}
	k := newIntegFx(t)
	k.deps.atTag = func(string, string) (bool, bool, error) { return true, false, nil }
	if r := checkIntegrity(k.deps); r.Reason != "this checkout is not exactly at v1.2.3" {
		t.Errorf("off the tag: %q", r.Reason)
	}
}

func TestIntegrityOversizedSavedListIsNotUsed(t *testing.T) {
	f := newIntegFx(t)
	checkIntegrity(f.deps)
	lp, pp := f.deps.cachePaths("v1.2.3")
	big := bytes.Repeat([]byte(" "), integrityListMax+1)
	_ = os.WriteFile(lp, big, 0o600)
	_ = os.WriteFile(pp, []byte(sha256Hex(big)+"\n"), 0o600)
	f.deps.online = false
	f.fail["integrity.txt"] = errors.New("offline")
	if r := checkIntegrity(f.deps); r.State != integrityNotChecked {
		t.Errorf("an oversized saved list: %+v", r)
	}
}

func TestIntegrityAgentCards(t *testing.T) {
	f := newIntegFx(t)
	r := checkIntegrity(f.deps)
	if len(r.Agents) != 2 {
		t.Fatalf("agents: %+v", r.Agents)
	}
	rev, ev := r.Agents[0], r.Agents[1]
	if rev.Name != "canon-reviewer" || rev.Role != "advisory" || ev.Role != "binding" || rev.Model != "claude-sonnet-5" || rev.Effort != "high" ||
		rev.Tools != "Read, Grep, Bash" || rev.Writes != "report.md" || !rev.ReadOnly || rev.GradedBy != "skills/sprint/reference/review.md" ||
		rev.File != "agents/canon-reviewer.md" || rev.Prompt != "You are a gate.\nSecond line." {
		t.Errorf("reviewer card: %+v", rev)
	}
	f.edit("agents/canon-reviewer.md", "---\ntools: Read, Write\n---\nx")
	if a := checkIntegrity(f.deps).Agents[0]; a.ReadOnly || a.Prompt != "x" {
		t.Errorf("a tool list with Write is not read-only: %+v", a)
	}
	f.edit("agents/canon-reviewer.md", "no front matter")
	if a := checkIntegrity(f.deps).Agents[0]; a.Name != "canon-reviewer" || a.Model != "" || a.Prompt != "" {
		t.Errorf("a file without front matter gives a bare card: %+v", a)
	}
	g := newIntegFx(t)
	g.deps.atTag = func(string, string) (bool, bool, error) { return true, false, nil }
	if r := checkIntegrity(g.deps); len(r.Agents) != 2 || r.Agents[0].Model != "claude-sonnet-5" {
		t.Errorf("a state that is not verified still lists the cards: %+v", r.Agents)
	}
}

func TestParseIntegrityArgs(t *testing.T) {
	for args, want := range map[string][4]bool{"": {false, false, false, true}, "--json": {true, false, false, true}, "--gate": {false, true, false, true},
		"--online": {false, false, true, true}, "--gate --online": {false, true, true, true}, "--bogus": {false, false, false, false}} {
		j, g, o, ok := parseIntegrityArgs(strings.Fields(args))
		if got := [4]bool{j, g, o, ok}; got != want {
			t.Errorf("%q: %v want %v", args, got, want)
		}
	}
}

func TestIntegrityEditOnlyOrWriteOnlyToolsAreNotReadOnly(t *testing.T) {
	for _, tools := range []string{"Read, Edit", "Read, Write", "Edit", "Write"} {
		f := newIntegFx(t)
		f.edit("agents/canon-reviewer.md", "---\ntools: "+tools+"\n---\nx")
		if a := checkIntegrity(f.deps).Agents[0]; a.ReadOnly {
			t.Errorf("tools %q must not read as read-only", tools)
		}
	}
}

// anyChecked: does the result claim anything about a file's content? A state that is not verified may list files, as "unchecked".
func anyChecked(r integrityResult) bool {
	for _, x := range r.Files {
		if x.Status != "unchecked" || x.Restore != "" {
			return true
		}
	}
	return r.Match != 0 || r.Total != 0 || r.Blocking
}

func TestIntegrityPreviewListsFilesWithoutClaimingAnything(t *testing.T) {
	f := newIntegFx(t)
	f.deps.atTag = func(string, string) (bool, bool, error) { return true, false, nil }
	f.edit("tools/sprint", "edited")
	r := checkIntegrity(f.deps)
	if r.State != integrityNotFromRelease || len(r.Files) != 14 || anyChecked(r) || len(r.Agents) != 2 {
		t.Fatalf("preview: %+v", r)
	}
	groups := map[string]int{}
	for _, x := range r.Files {
		groups[x.Group]++
	}
	if groups["agents"] != 2 || groups["prompts"] != 4 || groups["tools"] != 7 || groups["programs"] != 1 {
		t.Errorf("groups: %v", groups)
	}
	h := newIntegFx(t)
	h.deps.root = filepath.Join(h.root, "gone")
	if r := checkIntegrity(h.deps); len(r.Files) != 0 || len(r.Agents) != 0 {
		t.Errorf("an unreadable install folder lists nothing: %+v", r)
	}
}

// The preview lists must equal the ones the release list is built from: scripts/integrity-list.sh owns them.
func TestPreviewListsMatchTheReleaseScript(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "scripts", "integrity-list.sh"))
	if err != nil {
		t.Skip("scripts/integrity-list.sh is not beside this checkout:", err)
	}
	arr := func(name string) []string {
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, name+"=(") {
				return strings.Fields(strings.TrimSuffix(strings.TrimPrefix(l, name+"=("), ")"))
			}
		}
		t.Fatalf("%s not found in integrity-list.sh", name)
		return nil
	}
	if got, want := strings.Join(previewGateFiles, " "), strings.Join(arr("GATE_FILES"), " "); got != want {
		t.Errorf("gate files drifted:\n%s\n%s", got, want)
	}
	if got, want := strings.Join(previewGatePrompts, " "), strings.Join(arr("GATE_PROMPTS"), " "); got != want {
		t.Errorf("gate prompts drifted:\n%s\n%s", got, want)
	}
}

func TestIntegrityOversizedPinFileIsNotUsed(t *testing.T) {
	f := newIntegFx(t)
	f.body["https://pin.test/integrity.txt"] = append([]byte("v1.2.3 "+f.pin+"\n# "), bytes.Repeat([]byte("x"), integrityPinMax)...)
	if r := checkIntegrity(f.deps); r.State != integrityNotChecked || !strings.Contains(r.Reason, "larger than") {
		t.Errorf("an integrity.txt over the cap: %+v", r)
	}
}
