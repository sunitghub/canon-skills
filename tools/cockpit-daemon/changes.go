package main

// t-5a4b: "what changed" without git. A project folder that isn't a git repository (the norm for
// PMs and designers) has no diff to show, so the daemon takes a BASELINE of the folder when a
// session first starts and COMPARES against it when the session ends or on request.
//
// The store lives under ~/.canon/cockpit/changes/<project>/<id>/ — never inside the person's folder.
// It holds baseline.json (a manifest), copies/ (the original text of small files, so a change can
// show a line count and a file can be restored) and changes.json (the last comparison). Anything
// skipped for size or the ignore rules is COUNTED and reported, never dropped silently, and a
// walk that hits a limit says the result is incomplete instead of pretending.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Limits are variables so tests can shrink them.
var (
	changesTextMax    int64         = 256 << 10 // largest file whose original text is kept
	changesCopyBudget int64         = 50 << 20  // total bytes of copies per baseline
	changesHashMax    int64         = 8 << 20   // files up to this size are hashed; bigger ones compare by size+mtime
	changesMaxFiles                 = 50000
	changesWalkBudget time.Duration = 3 * time.Second
	changesListCap                  = 200 // files returned in a result (Total stays exact)
	changesDiffLines                = 2000
)

// Folders canon or tooling owns, and files that are noise, are ignored both ways.
var changesIgnoreDirs = map[string]bool{
	".tickets": true, ".claude": true, ".agents": true, ".git": true,
	"node_modules": true, ".canon-cache": true,
}

func changesIgnoredFile(name string) bool {
	switch name {
	case ".DS_Store", "Thumbs.db", "desktop.ini":
		return true
	}
	// Office / LibreOffice lock files: ~$Doc.docx, .~lock.Doc.odt#
	return strings.HasPrefix(name, "~$") || strings.HasPrefix(name, ".~lock.")
}

// changesSecretName marks files whose CONTENT must never be copied into the store (hash only).
func changesSecretName(name string) bool {
	n := strings.ToLower(name)
	if n == ".env" || strings.HasPrefix(n, ".env.") {
		return true
	}
	for _, suf := range []string{".pem", ".key", ".p12", ".pfx"} {
		if strings.HasSuffix(n, suf) {
			return true
		}
	}
	return strings.HasPrefix(n, "id_rsa") || strings.HasPrefix(n, "id_ed25519") || strings.HasPrefix(n, "credentials")
}

type baselineFile struct {
	Size  int64  `json:"size"`
	MTime int64  `json:"mtime_ns"`
	Hash  string `json:"hash,omitempty"` // sha256; empty when the file is larger than changesHashMax
	Copy  bool   `json:"copy,omitempty"` // the original text is kept in the store
}

type baseline struct {
	Root     string                  `json:"root"`
	Taken    time.Time               `json:"taken"`
	Files    map[string]baselineFile `json:"files"`    // slash-separated paths relative to Root
	Skipped  map[string]int          `json:"skipped"`  // reason -> count
	Complete bool                    `json:"complete"` // false: the walk was cut short by a limit
}

type changeFile struct {
	Status     string `json:"status"` // added | modified | deleted | renamed
	Path       string `json:"path"`
	From       string `json:"from,omitempty"` // renamed: the old path
	Size       int64  `json:"size"`
	OldSize    int64  `json:"old_size,omitempty"`
	AddedLines int    `json:"added_lines,omitempty"`
	Removed    int    `json:"removed_lines,omitempty"`
	CanRestore bool   `json:"can_restore,omitempty"` // a copy of the original is in the store
}

type changesResult struct {
	Tracked  bool           `json:"tracked"`  // a baseline exists
	Complete bool           `json:"complete"` // the baseline AND this comparison covered everything
	Taken    time.Time      `json:"taken,omitempty"`
	Compared time.Time      `json:"compared"`
	Total    int            `json:"total"`
	Files    []changeFile   `json:"files"`
	Skipped  map[string]int `json:"skipped,omitempty"`
	Note     string         `json:"note,omitempty"`
}

// defaultCanonCockpitDir is canon's durable per-user store (where the boards keep projects.json).
func defaultCanonCockpitDir() string {
	if h := os.Getenv("CANON_HOME"); h != "" {
		return filepath.Join(h, "cockpit")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".canon", "cockpit")
}

// changesStoreDir is the per-project, per-session/ticket store directory.
func (s *server) changesStoreDir(root, id string) string {
	home := s.cfg.changesHome
	if home == "" {
		home = defaultCanonCockpitDir()
	}
	sum := sha256.Sum256([]byte(root))
	return filepath.Join(home, "changes", hex.EncodeToString(sum[:])[:12], id)
}

func copyName(rel string) string {
	sum := sha256.Sum256([]byte(rel))
	return hex.EncodeToString(sum[:])[:24]
}

// writeFileAtomic writes through a uniquely named temp file beside p, so concurrent writers never share
// one and a person's own file can never be mistaken for it.
func writeFileAtomic(p string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(p), ".canon-*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func hashFile(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// looksText reports whether data (the start of a file) has no NUL byte.
func looksText(data []byte) bool { return !bytes.Contains(data, []byte{0}) }

type walked struct {
	files    map[string]baselineFile
	skipped  map[string]int
	complete bool
}

// walkTracked lists the trackable files under root. onFile, when set, runs for each regular file
// that will be recorded (baseline uses it to keep copies).
func walkTracked(root string, onFile func(rel, abs string, size int64) baselineFile) walked {
	w := walked{files: map[string]baselineFile{}, skipped: map[string]int{}, complete: true}
	deadline := time.Now().Add(changesWalkBudget)
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			w.skipped["unreadable"]++
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if p == root {
			return nil
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if changesIgnoreDirs[d.Name()] {
				w.skipped["ignored"]++
				return fs.SkipDir
			}
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			w.skipped["symlink"]++ // never followed: a link could lead out of the folder
			return nil
		}
		if !d.Type().IsRegular() {
			w.skipped["special"]++
			return nil
		}
		if changesIgnoredFile(d.Name()) {
			w.skipped["ignored"]++
			return nil
		}
		if len(w.files) >= changesMaxFiles {
			w.skipped["too-many-files"]++
			w.complete = false
			return nil
		}
		if time.Now().After(deadline) {
			w.skipped["time-budget"]++
			w.complete = false
			return fs.SkipAll
		}
		info, ierr := d.Info()
		if ierr != nil {
			w.skipped["unreadable"]++
			return nil
		}
		bf := baselineFile{Size: info.Size(), MTime: info.ModTime().UnixNano()}
		if onFile != nil {
			bf = onFile(rel, p, info.Size())
			bf.MTime = info.ModTime().UnixNano()
		}
		w.files[rel] = bf
		return nil
	})
	return w
}

// takeBaseline records the folder's current state in storeDir. copies are kept for small text files
// (secrets excluded) until the copy budget runs out.
func takeBaseline(root, storeDir string) (*baseline, error) {
	if err := os.MkdirAll(filepath.Join(storeDir, "copies"), 0o700); err != nil {
		return nil, err
	}
	budget := changesCopyBudget
	w := walkTracked(root, func(rel, abs string, size int64) baselineFile {
		bf := baselineFile{Size: size}
		if size <= changesHashMax {
			if h, err := hashFile(abs); err == nil {
				bf.Hash = h
			}
		}
		if size <= changesTextMax && size <= budget && !changesSecretName(path.Base(rel)) {
			if data, err := os.ReadFile(abs); err == nil && looksText(data[:min(len(data), 8192)]) {
				if writeFileAtomic(filepath.Join(storeDir, "copies", copyName(rel)), data) == nil {
					bf.Copy = true
					budget -= size
				}
			}
		}
		return bf
	})
	b := &baseline{Root: root, Taken: time.Now().UTC(), Files: w.files, Skipped: w.skipped, Complete: w.complete}
	data, err := json.Marshal(b)
	if err != nil {
		return nil, err
	}
	if err := writeFileAtomic(filepath.Join(storeDir, "baseline.json"), data); err != nil {
		return nil, err
	}
	return b, nil
}

func loadBaseline(storeDir string) (*baseline, error) {
	data, err := os.ReadFile(filepath.Join(storeDir, "baseline.json"))
	if err != nil {
		return nil, err
	}
	var b baseline
	if err := json.Unmarshal(data, &b); err != nil {
		return nil, err
	}
	if b.Files == nil {
		b.Files = map[string]baselineFile{}
	}
	return &b, nil
}

// ensureBaseline takes a baseline only when none exists: the first Start of a ticket fixes it until
// the sprint closes, so a resumed session keeps comparing against the same starting point.
func ensureBaseline(root, storeDir string) (*baseline, error) {
	if b, err := loadBaseline(storeDir); err == nil {
		return b, nil
	}
	return takeBaseline(root, storeDir)
}

// lineDiffCounts returns how many lines were added and removed between a and b (LCS on lines).
// Inputs longer than changesDiffLines lines report ok=false.
func lineDiffCounts(a, b string) (added, removed int, ok bool) {
	la, lb := strings.Split(a, "\n"), strings.Split(b, "\n")
	if len(la) > changesDiffLines || len(lb) > changesDiffLines {
		return 0, 0, false
	}
	prev := make([]int, len(lb)+1)
	cur := make([]int, len(lb)+1)
	for i := 1; i <= len(la); i++ {
		for j := 1; j <= len(lb); j++ {
			switch {
			case la[i-1] == lb[j-1]:
				cur[j] = prev[j-1] + 1
			case prev[j] >= cur[j-1]:
				cur[j] = prev[j]
			default:
				cur[j] = cur[j-1]
			}
		}
		prev, cur = cur, prev
	}
	lcs := prev[len(lb)]
	return len(lb) - lcs, len(la) - lcs, true
}

// compareBaseline walks the folder again and reports what changed since the baseline, writing
// changes.json next to it. A missing baseline is reported as untracked, not as an error.
func compareBaseline(root, storeDir string) (*changesResult, error) {
	res := &changesResult{Compared: time.Now().UTC(), Files: []changeFile{}}
	b, err := loadBaseline(storeDir)
	if err != nil {
		res.Note = "Changes weren't tracked for this session."
		return res, nil
	}
	res.Tracked, res.Taken = true, b.Taken
	cur := walkTracked(root, func(rel, abs string, size int64) baselineFile {
		bf := baselineFile{Size: size}
		if old, ok := b.Files[rel]; ok {
			if info, err := os.Stat(abs); err == nil && old.Size == size && old.MTime == info.ModTime().UnixNano() {
				return old // untouched: reuse, no hashing
			}
		}
		if size <= changesHashMax {
			if h, err := hashFile(abs); err == nil {
				bf.Hash = h
			}
		}
		return bf
	})
	res.Skipped = cur.skipped
	res.Complete = b.Complete && cur.complete
	var files []changeFile
	added := map[string]baselineFile{}
	for rel, now := range cur.files {
		old, existed := b.Files[rel]
		switch {
		case !existed:
			added[rel] = now
		case old.Size == now.Size && old.MTime == now.MTime:
		case old.Hash != "" && old.Hash == now.Hash:
			// touched, content identical
		default:
			f := changeFile{Status: "modified", Path: rel, Size: now.Size, OldSize: old.Size, CanRestore: old.Copy}
			if old.Copy {
				if orig, err := os.ReadFile(filepath.Join(storeDir, "copies", copyName(rel))); err == nil && now.Size <= changesTextMax {
					if data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel))); err == nil && looksText(data[:min(len(data), 8192)]) {
						if a, r, ok := lineDiffCounts(string(orig), string(data)); ok {
							f.AddedLines, f.Removed = a, r
						}
					}
				}
			}
			files = append(files, f)
		}
	}
	deleted := map[string]baselineFile{}
	for rel, old := range b.Files {
		if _, still := cur.files[rel]; !still {
			deleted[rel] = old
		}
	}
	// A deleted and an added file with the same non-empty content hash are one rename.
	byHash := map[string]string{}
	for rel, old := range deleted {
		if old.Hash != "" {
			byHash[old.Hash] = rel
		}
	}
	for rel, now := range added {
		if from, ok := byHash[now.Hash]; ok && now.Hash != "" {
			files = append(files, changeFile{Status: "renamed", Path: rel, From: from, Size: now.Size})
			delete(deleted, from)
			delete(byHash, now.Hash)
			continue
		}
		files = append(files, changeFile{Status: "added", Path: rel, Size: now.Size})
	}
	for rel, old := range deleted {
		files = append(files, changeFile{Status: "deleted", Path: rel, OldSize: old.Size, CanRestore: old.Copy})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	res.Total = len(files)
	if len(files) > changesListCap {
		files = files[:changesListCap]
	}
	if files != nil {
		res.Files = files
	}
	if !res.Complete {
		res.Note = "This folder was too large to track completely — some changes may not be listed."
	}
	if data, err := json.Marshal(res); err == nil {
		_ = writeFileAtomic(filepath.Join(storeDir, "changes.json"), data)
	}
	return res, nil
}

// restoreOriginal puts back every file whose original text was kept at baseline time and that is now
// missing or different, and returns the restored paths. Files added since the baseline, and files too
// large or too sensitive to have been copied, are left alone — the caller reports how many changes remain.
// Each file it overwrites is first saved under storeDir/before-restore, so a restore can itself be undone.
// Paths come only from the baseline (never from a request) and must resolve inside root.
func restoreOriginal(root, storeDir string) ([]string, error) {
	b, err := loadBaseline(storeDir)
	if err != nil {
		return nil, fmt.Errorf("changes weren't tracked for this session")
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, err
	}
	rels := make([]string, 0, len(b.Files))
	for rel, f := range b.Files {
		if f.Copy {
			rels = append(rels, rel)
		}
	}
	sort.Strings(rels)
	saved := filepath.Join(storeDir, "before-restore", time.Now().UTC().Format("20060102T150405Z"))
	var restored []string
	for _, rel := range rels {
		orig, err := os.ReadFile(filepath.Join(storeDir, "copies", copyName(rel)))
		if err != nil {
			continue
		}
		dst := filepath.Join(realRoot, filepath.FromSlash(rel))
		// The agent can write the folder: never follow a link it put anywhere in the path of a file we restore.
		if !plainPath(realRoot, filepath.Dir(rel)) {
			continue
		}
		mode := os.FileMode(0o644)
		cur, err := os.ReadFile(dst)
		if err == nil {
			fi, lerr := os.Lstat(dst)
			if lerr != nil || !fi.Mode().IsRegular() || bytes.Equal(cur, orig) {
				continue
			}
			mode = fi.Mode().Perm()
			if err := os.MkdirAll(filepath.Dir(filepath.Join(saved, filepath.FromSlash(rel))), 0o700); err != nil {
				return restored, err
			}
			if err := writeFileAtomic(filepath.Join(saved, filepath.FromSlash(rel)), cur); err != nil {
				return restored, err
			}
		} else if !os.IsNotExist(err) {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return restored, err
		}
		if err := writeFileAtomic(dst, orig); err != nil {
			return restored, err
		}
		_ = os.Chmod(dst, mode) // writeFileAtomic writes 0600; a person's file keeps its own permissions
		restored = append(restored, rel)
	}
	return restored, nil
}

// plainPath reports whether every directory of rel (slash-separated, relative to root) that already
// exists is a real directory, not a link. Directories that don't exist yet are fine: we create them.
func plainPath(root, rel string) bool {
	cur := root
	for _, part := range strings.Split(filepath.ToSlash(rel), "/") {
		if part == "." || part == "" {
			continue
		}
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if os.IsNotExist(err) {
			return true
		}
		if err != nil || !fi.IsDir() {
			return false
		}
	}
	return true
}
