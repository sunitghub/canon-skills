package board

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"canon/internal/common"
	"canon/internal/events"
)

// Admin > Integrity (t-2af0). Slice 1: do the gate files, the gate prompts and the programs' manifest in this install still have the
// content hash of the release they came from? The hashes are a file published beside the release (integrity-X.Y.Z.json, written by
// scripts/integrity-list.sh), trusted only when its sha256 equals the line for the tag in getcanon.dev's integrity.txt (a file of its own:
// releases.txt keeps its three fields). A verified copy and its pin are saved under CANON_HOME/integrity/ so a check works offline.
// Hash comparison only: a match proves a file is unchanged since the release, not that the release was safe.

const (
	integrityPinURL    = "https://getcanon.dev/integrity.txt"
	integrityAssetBase = "https://github.com/sunitghub/canon-skills/releases/download"
	integrityPinMax    = 1 << 20
	integrityListMax   = 4 << 20
	integrityMaxFiles  = 5000
	// the programs' manifest (tools/cockpit-daemon.sha256): the binaries are themselves checked against it by fetch-daemon at every start
	integrityManifest = "tools/cockpit-daemon.sha256"
)

var (
	integrityVerRe  = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	integrityPathRe = regexp.MustCompile(`^[A-Za-z0-9._/@+-]+$`)
	integrityPinRe  = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{64}$`)
	integrityHexRe  = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// The four things a check can say. Only "verified" counts files and can block; no other state is ever shown green.
const (
	integrityVerified       = "verified"
	integrityNotFromRelease = "not-from-release"
	integrityNotChecked     = "not-checked"
	integrityListPending    = "list-pending"
)

type integrityFile struct {
	Path    string `json:"path"`
	Group   string `json:"group"` // agents | prompts | tools | programs
	Gate    bool   `json:"gate"`
	Status  string `json:"status"`            // match | changed | missing
	Restore string `json:"restore,omitempty"` // the command that puts it back, for a changed or missing file
}

type integrityResult struct {
	State    string          `json:"state"`
	Tag      string          `json:"tag,omitempty"`
	Reason   string          `json:"reason,omitempty"`
	Source   string          `json:"source,omitempty"` // online | cached
	Files    []integrityFile `json:"files"`
	Match    int             `json:"match"`
	Total    int             `json:"total"`
	Blocking bool            `json:"blocking"` // a gate file or gate prompt differs in a verified install
}

type integrityDeps struct {
	root      string // the install: the folder holding VERSION and tools/
	home      string // events.Home(): the saved list lives in <home>/integrity
	pinURL    string
	assetBase string
	online    bool // false: use the saved list when there is one, and go online only when there is none
	get       func(url string, max int64) ([]byte, error)
	atTag     func(root, tag string) (isGit, at bool, err error)
}

type integrityList struct {
	Tag         string            `json:"tag"`
	Commit      string            `json:"commit"`
	GateFiles   []string          `json:"gate_files"`
	GatePrompts []string          `json:"gate_prompts"`
	Files       map[string]string `json:"files"`
}

func defaultIntegrityDeps(root string, online bool) integrityDeps {
	return integrityDeps{root: root, home: events.Home(), pinURL: common.EnvOr("CANON_INTEGRITY_URL", integrityPinURL),
		assetBase: common.EnvOr("CANON_INTEGRITY_ASSET_BASE", integrityAssetBase), online: online, get: httpsGet, atTag: gitAtTag}
}

// httpsGet reads one https URL (a redirect must stay on https) up to max bytes; anything longer is an error, never a cut copy.
func httpsGet(url string, max int64) ([]byte, error) {
	if !strings.HasPrefix(url, "https://") {
		return nil, fmt.Errorf("not an https address")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	c := &http.Client{CheckRedirect: func(r *http.Request, via []*http.Request) error {
		if r.URL.Scheme != "https" || len(via) > 5 {
			return errors.New("redirect refused")
		}
		return nil
	}}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("larger than %d bytes", max)
	}
	return b, nil
}

// gitAtTag: in a git install, is HEAD exactly the release tag's commit? A zip install has no .git and counts as a release install.
func gitAtTag(root, tag string) (bool, bool, error) {
	if _, err := os.Lstat(filepath.Join(root, ".git")); err != nil {
		return false, true, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	run := func(args ...string) (string, error) {
		out, err := exec.CommandContext(ctx, "git", append([]string{"-C", root}, args...)...).Output()
		return strings.TrimSpace(string(out)), err
	}
	head, err := run("rev-parse", "-q", "--verify", "HEAD^{commit}")
	if err != nil {
		return true, false, err
	}
	tagCommit, err := run("rev-parse", "-q", "--verify", "refs/tags/"+tag+"^{commit}")
	if err != nil {
		return true, false, nil // the tag is not in this clone: not at it
	}
	return true, head == tagCommit, nil
}

func sha256Hex(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func hashFile(path string) (string, string) { // hash, status ("" when readable)
	fi, err := os.Lstat(path)
	if err != nil {
		return "", "missing"
	}
	if !fi.Mode().IsRegular() { // a link or a folder where a file belongs is a change
		return "", "changed"
	}
	f, err := os.Open(path)
	if err != nil {
		return "", "missing"
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", "changed"
	}
	return hex.EncodeToString(h.Sum(nil)), ""
}

// pinFor reads integrity.txt: the one distinct, well-formed line for the tag (found=false when there is none).
func pinFor(body []byte, tag string) (pin string, found bool, err error) {
	if bytes.IndexByte(body, 0) >= 0 {
		return "", false, errors.New("integrity.txt contains a NUL byte")
	}
	seen := map[string]bool{}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) == 0 || f[0] != tag {
			continue
		}
		if !integrityPinRe.MatchString(line) {
			return "", false, fmt.Errorf("a malformed line for %s in integrity.txt", tag)
		}
		seen[f[1]] = true
		pin = f[1]
	}
	switch len(seen) {
	case 0:
		return "", false, nil
	case 1:
		return pin, true, nil
	}
	return "", false, fmt.Errorf("integrity.txt lists %s twice with different hashes", tag)
}

func (d integrityDeps) cachePaths(tag string) (list, pin string) {
	dir := filepath.Join(d.home, "integrity")
	return filepath.Join(dir, tag+".json"), filepath.Join(dir, tag+".pin")
}

func (d integrityDeps) readCache(tag string) ([]byte, bool) {
	lp, pp := d.cachePaths(tag)
	b, err1 := os.ReadFile(lp)
	p, err2 := os.ReadFile(pp)
	if err1 != nil || err2 != nil || int64(len(b)) > integrityListMax {
		return nil, false
	}
	pin := strings.TrimSpace(string(p))
	if !integrityHexRe.MatchString(pin) || sha256Hex(b) != pin { // the saved list no longer equals the pin it was saved under
		return nil, false
	}
	return b, true
}

func (d integrityDeps) writeCache(tag string, list []byte, pin string) {
	lp, pp := d.cachePaths(tag)
	if os.MkdirAll(filepath.Dir(lp), 0o700) != nil {
		return
	}
	put := func(path string, data []byte) {
		tmp := path + ".tmp"
		if os.WriteFile(tmp, data, 0o600) == nil && os.Rename(tmp, path) != nil {
			_ = os.Remove(tmp)
		}
	}
	put(lp, list)
	put(pp, []byte(pin+"\n"))
}

// loadList returns a verified list for the tag: the saved copy when it is still equal to its pin (unless the caller asked to go
// online), else fetched and checked against integrity.txt. state is "" on success.
func (d integrityDeps) loadList(tag, ver string) (list []byte, source, state, reason string) {
	if !d.online {
		if b, ok := d.readCache(tag); ok {
			return b, "cached", "", ""
		}
	}
	body, err := d.get(d.pinURL, integrityPinMax)
	if err != nil {
		if b, ok := d.readCache(tag); ok {
			return b, "cached", "", ""
		}
		return nil, "", integrityNotChecked, "cannot read " + d.pinURL + " (" + err.Error() + ") and no list is saved on this machine"
	}
	pin, found, err := pinFor(body, tag)
	if err != nil {
		return nil, "", integrityNotChecked, err.Error()
	}
	if !found {
		if b, ok := d.readCache(tag); ok {
			return b, "cached", "", ""
		}
		return nil, "", integrityListPending, tag + " has no line in integrity.txt yet"
	}
	list, err = d.get(d.assetBase+"/"+tag+"/integrity-"+ver+".json", integrityListMax)
	if err != nil {
		if b, ok := d.readCache(tag); ok {
			return b, "cached", "", ""
		}
		return nil, "", integrityNotChecked, "cannot read the list for " + tag + " (" + err.Error() + ")"
	}
	if sha256Hex(list) != pin {
		return nil, "", integrityNotChecked, "the list for " + tag + " does not match its published hash; it was not used"
	}
	d.writeCache(tag, list, pin)
	return list, "online", "", ""
}

func validRel(p string) bool {
	return integrityPathRe.MatchString(p) && !strings.HasPrefix(p, "/") && !strings.Contains(p, "..") && !strings.Contains(p, "//")
}

func integrityGroup(p string, gate bool) string {
	switch {
	case p == integrityManifest:
		return "programs"
	case strings.HasPrefix(p, "agents/"):
		return "agents"
	case gate:
		return "tools"
	}
	return "prompts"
}

// checkIntegrity decides the install's state and, for a verified one, compares the slice-1 files with the list.
func checkIntegrity(d integrityDeps) integrityResult {
	res := integrityResult{Files: []integrityFile{}}
	root, err := filepath.EvalSymlinks(d.root)
	if err != nil {
		res.State, res.Reason = integrityNotFromRelease, "cannot read the install folder"
		return res
	}
	d.root = root
	vb, _ := os.ReadFile(filepath.Join(root, "VERSION"))
	ver := strings.TrimSpace(string(vb))
	if !integrityVerRe.MatchString(ver) {
		res.State, res.Reason = integrityNotFromRelease, "this folder has no release version"
		return res
	}
	tag := "v" + ver
	res.Tag = tag
	if tb, _ := os.ReadFile(filepath.Join(root, ".canon-track")); strings.TrimSpace(string(tb)) == "main" {
		res.State, res.Reason = integrityNotFromRelease, "this install follows main: there is no released copy to compare with"
		return res
	}
	if isGit, at, err := d.atTag(root, tag); err != nil || (isGit && !at) {
		res.State, res.Reason = integrityNotFromRelease, "this checkout is not exactly at "+tag
		return res
	}
	raw, source, state, reason := d.loadList(tag, ver)
	if state != "" {
		res.State, res.Reason = state, reason
		return res
	}
	var l integrityList
	if err := json.Unmarshal(raw, &l); err != nil || l.Tag != tag || len(l.Files) == 0 || len(l.Files) > integrityMaxFiles {
		res.State, res.Reason = integrityNotChecked, "the list for "+tag+" is not one canon can read"
		return res
	}
	gate := map[string]bool{}
	var paths []string
	for _, group := range [][]string{l.GateFiles, l.GatePrompts} {
		for _, p := range group {
			gate[p] = true
			paths = append(paths, p)
		}
	}
	paths = append(paths, integrityManifest)
	res.State, res.Source = integrityVerified, source
	_, noGit := os.Lstat(filepath.Join(root, ".git"))
	for _, p := range paths {
		want, ok := l.Files[p]
		if !validRel(p) || !ok || !integrityHexRe.MatchString(want) {
			res.State, res.Reason = integrityNotChecked, "the list for "+tag+" names a file canon cannot check: "+p
			res.Files, res.Match, res.Total, res.Blocking = []integrityFile{}, 0, 0, false
			return res
		}
		f := integrityFile{Path: p, Group: integrityGroup(p, gate[p]), Gate: gate[p]}
		got, st := hashFile(filepath.Join(root, filepath.FromSlash(p)))
		switch {
		case st != "":
			f.Status = st
		case got == want:
			f.Status = "match"
		default:
			f.Status = "changed"
		}
		if f.Status == "match" {
			res.Match++
		} else {
			if noGit == nil {
				f.Restore = "git -C " + shellQuote(root) + " checkout -- " + p
			} else {
				f.Restore = "canon update"
			}
			if f.Gate {
				res.Blocking = true
			}
		}
		res.Files = append(res.Files, f)
	}
	res.Total = len(res.Files)
	return res
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// integrityRoot is the install this binary belongs to: SPRINT_CHECK_ROOT is a project, not the install, so it is the executable's own
// tools folder's parent (the same rule main uses for toolsDir).
func integrityRoot() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	dir := filepath.Dir(exe)
	if strings.HasSuffix(filepath.ToSlash(dir), "/sprint-check-bin") {
		dir = filepath.Dir(dir)
	}
	return filepath.Dir(dir)
}

// integrityCLI is `sprint-check integrity [--json] [--gate] [--online]`: --gate exits 3 only when the state is verified and a gate file or
// prompt differs; every other outcome exits 0 (a missing list, an offline run or a main install never blocks a close).
func integrityCLI(args []string, stdout, stderr io.Writer) int {
	asJSON, gate, online := false, false, false
	for _, a := range args {
		switch a {
		case "--json":
			asJSON = true
		case "--gate":
			gate = true
		case "--online":
			online = true
		default:
			fmt.Fprintln(stderr, "usage: sprint-check integrity [--json] [--gate] [--online]")
			return 2
		}
	}
	root := common.EnvOr("CANON_INTEGRITY_ROOT", integrityRoot())
	res := checkIntegrity(defaultIntegrityDeps(root, online))
	if asJSON {
		b, _ := json.Marshal(res)
		fmt.Fprintln(stdout, string(b))
	} else if !gate || res.Blocking || res.State != integrityVerified {
		fmt.Fprintln(stdout, integritySummary(res))
	}
	if gate && res.Blocking {
		for _, f := range res.Files {
			if f.Gate && f.Status != "match" {
				fmt.Fprintf(stdout, "  %s: %s. Put it back: %s\n", f.Path, f.Status, f.Restore)
			}
		}
		return 3
	}
	return 0
}

func integritySummary(r integrityResult) string {
	switch r.State {
	case integrityVerified:
		if r.Blocking {
			return fmt.Sprintf("integrity: a gate file or gate prompt differs from release %s (%d of %d files match)", r.Tag, r.Match, r.Total)
		}
		return fmt.Sprintf("integrity: %d of %d files match release %s", r.Match, r.Total, r.Tag)
	default:
		return fmt.Sprintf("integrity: %s (%s)", r.State, r.Reason)
	}
}
