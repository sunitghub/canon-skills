// Package settings reads and writes a small, closed set of settings kept in two JSON files (t-dba0): a SHARED file the user (or a
// repo) hand-edits and commits, and a LOCAL file that is personal and the only one this package ever writes. Precedence is
// default < shared < local. A key outside the schema is never read; the shared file is untrusted input (a cloned repo supplies it),
// so only keys the schema marks Shareable may come from it. The package takes the file paths and the schema as arguments: a
// project uses `.canon/`, an install-wide file (t-3137) gives its own paths and keys.
package settings

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const (
	// MaxFileBytes and MaxDepth bound what a settings file may be: a hostile one cannot exhaust memory. Over either is "malformed".
	MaxFileBytes = 64 << 10
	MaxDepth     = 8

	SourceDefault = "default"
	SourceShared  = "shared"
	SourceLocal   = "local"
)

// Key is one setting: how a value is checked and normalised, whether a shared (repo-controlled) file may set it, and its default.
type Key struct {
	Validate  func(v any) (any, error)
	Shareable bool
	Default   any
}

// Schema maps a dotted key ("terminal.paging") to its definition. It is closed: a key not in it does not exist.
type Schema map[string]Key

// Set is one settings set. Shared and Local are file paths; "" means that file does not exist for this set.
type Set struct {
	Schema        Schema
	Shared, Local string
}

// Value is a setting's effective value and where it came from.
type Value struct {
	V      any
	Source string
}

// Result is the merged settings plus anything ignored on the way (an invalid value, a key the shared file may not set).
type Result struct {
	Values   map[string]Value
	Warnings []string
}

// FileError says a file cannot be used: it is malformed, too large, too deep, or a symlink. The name is the last two path
// elements (".canon/settings.local.json"), never an absolute path.
type FileError struct {
	File   string
	Reason string
}

func (e *FileError) Error() string { return fmt.Sprintf("%s: %s", e.File, e.Reason) }

func shortName(p string) string {
	return filepath.ToSlash(filepath.Join(filepath.Base(filepath.Dir(p)), filepath.Base(p)))
}

// readDoc loads one file as a JSON object. A missing file is an empty object; a symlink, an oversized or too deeply nested file,
// invalid JSON, or JSON that is not an object is a *FileError (the file is never rewritten by a caller that got one).
func readDoc(path string) (map[string]any, error) {
	if path == "" {
		return map[string]any{}, nil
	}
	fi, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, &FileError{shortName(path), "cannot be read"}
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return nil, &FileError{shortName(path), "is a symlink; settings files must be plain files"}
	}
	if !fi.Mode().IsRegular() {
		return nil, &FileError{shortName(path), "is not a regular file"}
	}
	if fi.Size() > MaxFileBytes {
		return nil, &FileError{shortName(path), fmt.Sprintf("is larger than %d KB", MaxFileBytes>>10)}
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, &FileError{shortName(path), "cannot be read"}
	}
	if len(bytes.TrimSpace(b)) == 0 {
		return map[string]any{}, nil
	}
	var v any
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber() // numbers keep their digits when a key this package does not own is written back
	if err := dec.Decode(&v); err != nil {
		return nil, &FileError{shortName(path), "is not valid JSON"}
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) { // nothing but whitespace may follow the one value
		return nil, &FileError{shortName(path), "is not valid JSON"}
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, &FileError{shortName(path), "is not a JSON object"}
	}
	if depth(m) > MaxDepth {
		return nil, &FileError{shortName(path), fmt.Sprintf("is nested deeper than %d levels", MaxDepth)}
	}
	return m, nil
}

func depth(v any) int {
	var kids []any
	switch x := v.(type) {
	case map[string]any:
		for _, c := range x {
			kids = append(kids, c)
		}
	case []any:
		kids = x
	default:
		return 0
	}
	d := 0
	for _, c := range kids {
		if n := depth(c); n > d {
			d = n
		}
	}
	return d + 1
}

// lookup finds a dotted key in a nested document.
func lookup(doc map[string]any, key string) (any, bool) {
	var cur any = doc
	for _, part := range strings.Split(key, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		if cur, ok = m[part]; !ok {
			return nil, false
		}
	}
	return cur, true
}

// assign sets a dotted key in a nested document, creating objects on the way and keeping every other key as it was.
func assign(doc map[string]any, key string, v any) error {
	parts := strings.Split(key, ".")
	cur := doc
	for _, part := range parts[:len(parts)-1] {
		next, ok := cur[part].(map[string]any)
		if !ok {
			if _, exists := cur[part]; exists {
				return fmt.Errorf("%s: %q is not an object in this file", key, part)
			}
			next = map[string]any{}
			cur[part] = next
		}
		cur = next
	}
	cur[parts[len(parts)-1]] = v
	return nil
}

func (s Set) keys() []string {
	ks := make([]string, 0, len(s.Schema))
	for k := range s.Schema {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// Load merges defaults, the shared file and the local file. A malformed or unreadable file is an error naming it. A value that
// fails its key's check, or a key the shared file may not set, is ignored and reported in Warnings.
func (s Set) Load() (Result, error) {
	shared, err := readDoc(s.Shared)
	if err != nil {
		return Result{}, err
	}
	local, err := readDoc(s.Local)
	if err != nil {
		return Result{}, err
	}
	res := Result{Values: map[string]Value{}}
	for _, k := range s.keys() {
		def := s.Schema[k]
		res.Values[k] = Value{def.Default, SourceDefault}
		for _, f := range []struct {
			doc    map[string]any
			path   string
			source string
		}{{shared, s.Shared, SourceShared}, {local, s.Local, SourceLocal}} {
			raw, ok := lookup(f.doc, k)
			if !ok {
				continue
			}
			if f.source == SourceShared && !def.Shareable {
				res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %s may not be set in a shared file; ignored (set it in the local file)", shortName(f.path), k))
				continue
			}
			if n, isNum := raw.(json.Number); isNum { // validators see a float64, as they do for a request body
				if f, ferr := n.Float64(); ferr == nil {
					raw = f
				}
			}
			v, err := def.Validate(raw)
			if err != nil {
				res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %s: %v; ignored", shortName(f.path), k, err))
				continue
			}
			res.Values[k] = Value{v, f.source}
		}
	}
	return res, nil
}

// SetLocal validates value for key, changes that one key in the LOCAL file (every other key kept) and returns the merged settings.
// It refuses an unknown key, a bad value, a missing local path, and a local file that is malformed or a symlink (left untouched).
// The write is a temp file in the same folder (mode 0600) renamed over the target: a reader never sees half a file, and a symlink
// target is replaced, never followed.
func (s Set) SetLocal(key string, value any) (Result, error) {
	def, ok := s.Schema[key]
	if !ok {
		return Result{}, fmt.Errorf("unknown setting %q", key)
	}
	if s.Local == "" {
		return Result{}, errors.New("no local settings file for this set")
	}
	v, err := def.Validate(value)
	if err != nil {
		return Result{}, fmt.Errorf("%s: %v", key, err)
	}
	doc, err := readDoc(s.Local)
	if err != nil {
		return Result{}, err
	}
	if err := assign(doc, key, v); err != nil {
		return Result{}, err
	}
	dir := filepath.Dir(s.Local)
	if fi, err := os.Lstat(dir); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return Result{}, &FileError{filepath.Base(dir), "is a symlink; settings must live in a plain folder"}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false) // < and & stay as they were written
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return Result{}, err
	}
	body := bytes.TrimRight(buf.Bytes(), "\n")
	if len(body)+1 > MaxFileBytes { // never write a file this package would then refuse to read
		return Result{}, fmt.Errorf("%s would be larger than %d KB with this change; trim it by hand first", shortName(s.Local), MaxFileBytes>>10)
	}
	if err := os.Mkdir(dir, 0o755); err != nil && !errors.Is(err, os.ErrExist) { // one level only: a missing project folder is not recreated
		return Result{}, fmt.Errorf("cannot create %s: is the project folder still there?", filepath.Base(dir))
	}
	tmp, err := os.CreateTemp(dir, ".settings-*.tmp")
	if err != nil {
		return Result{}, fmt.Errorf("cannot write %s", shortName(s.Local))
	}
	tmpName := tmp.Name()
	_, werr := tmp.Write(append(body, '\n'))
	if serr := tmp.Sync(); werr == nil {
		werr = serr
	}
	if cerr := tmp.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Rename(tmpName, s.Local)
	}
	if werr != nil {
		os.Remove(tmpName)
		return Result{}, fmt.Errorf("cannot write %s", shortName(s.Local))
	}
	return s.Load()
}

// IgnoreInGit adds rel (a path relative to root) to the repository's own info/exclude once, so a personal file stays out of
// `git status` without any tracked file changing. No git, or a root that is not in a repository, is nil; a symlinked exclude is refused.
func IgnoreInGit(root, rel string) error {
	out, err := exec.Command("git", "-C", root, "rev-parse", "--git-path", "info/exclude").Output()
	if err != nil {
		return nil
	}
	p := strings.TrimSpace(string(out))
	if p == "" {
		return nil
	}
	// a project below the repository's top (a monorepo folder) is excluded by its path from the top, which is what exclude patterns mean
	pre, err := exec.Command("git", "-C", root, "rev-parse", "--show-prefix").Output()
	if err != nil {
		return nil
	}
	rel = filepath.ToSlash(strings.TrimSpace(string(pre))) + filepath.ToSlash(rel)
	if !filepath.IsAbs(p) {
		p = filepath.Join(root, p)
	}
	if fi, err := os.Lstat(p); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			return &FileError{shortName(p), "is a symlink; not edited"}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil
	}
	line := filepath.ToSlash(rel)
	b, _ := os.ReadFile(p)
	for _, l := range strings.Split(string(b), "\n") {
		if strings.TrimSpace(l) == line {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return nil
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return nil
	}
	defer f.Close()
	prefix := ""
	if len(b) > 0 && !bytes.HasSuffix(b, []byte("\n")) {
		prefix = "\n"
	}
	_, err = f.WriteString(prefix + line + "\n")
	return err
}

// Paging is terminal.paging: "auto" (the screen's height), "off" (never pause), or a whole number of lines from MinPaging to MaxPaging.
const (
	MinPaging = 5
	MaxPaging = 500
)

func validatePaging(v any) (any, error) {
	bad := fmt.Errorf("must be \"auto\", \"off\" or a whole number of lines from %d to %d", MinPaging, MaxPaging)
	switch x := v.(type) {
	case string:
		if x == "auto" || x == "off" {
			return x, nil
		}
	case float64:
		if x == math.Trunc(x) && x >= MinPaging && x <= MaxPaging {
			return int(x), nil
		}
	case int:
		if x >= MinPaging && x <= MaxPaging {
			return x, nil
		}
	case json.Number:
		if n, err := x.Int64(); err == nil && n >= MinPaging && n <= MaxPaging {
			return int(n), nil
		}
	}
	return nil, bad
}

// ProjectSet is the settings of one project: `.canon/settings.json` (shared) and `.canon/settings.local.json` (local).
func ProjectSet(root string) Set {
	return Set{
		Schema: Schema{"terminal.paging": {Validate: validatePaging, Shareable: true, Default: "auto"}},
		Shared: filepath.Join(root, ".canon", "settings.json"),
		Local:  filepath.Join(root, ".canon", "settings.local.json"),
	}
}

// LocalRel is the local file's path relative to the project root (what IgnoreInGit takes).
const LocalRel = ".canon/settings.local.json"
