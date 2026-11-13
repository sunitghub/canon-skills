package board

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"
)

// t-a854: the first snapshot of a project that just turned on version history. trackChanges commits only a
// .gitignore; this saves the user's files too, after the user saw what they are, and only when
// tools/secret-scan.sh --staged (t-5988) finds nothing. Every failure leaves nothing committed and the index reset.

const firstSnapshotMessage = "chore: first snapshot of this folder"
const firstSnapshotLarge = 5 << 20
const firstSnapshotMaxFiles = 200000

// firstSnapshotIgnoreEntries are the credential shapes the default .gitignore keeps out of a snapshot.
const firstSnapshotIgnoreEntries = ".env\n.env.*\n*.pem\nid_rsa\nid_ed25519\n.claude/settings.local.json\n"

var secretFindingRe = regexp.MustCompile(`^(?:[0-9a-f]{7,40}:)?(.*):([0-9]+): (\S+)$`)

type snapshotFinding struct {
	Path string `json:"path"`
	Line string `json:"line"`
	Rule string `json:"rule"`
}

// canonStartOnly: the folder is a work tree whose only commit is the one trackChanges made, so there is something to save.
func canonStartOnly(root string) (bool, string) {
	if !insideWorkTree(root) {
		return false, "This folder does not keep a version history yet."
	}
	n, _, err := gitOutIn(root, 10*time.Second, "rev-list", "--count", "HEAD")
	if err != nil || strings.TrimSpace(n) != "1" {
		return false, "A first snapshot is only offered right after version history is turned on."
	}
	subj, _, err := gitOutIn(root, 10*time.Second, "log", "-1", "--format=%s")
	if err != nil || strings.TrimSpace(subj) != trackChangesMessage {
		return false, "A first snapshot is only offered right after version history is turned on."
	}
	return true, ""
}

// untrackedFiles: the files a snapshot would save (not ignored), as git names them.
func untrackedFiles(root string) ([]string, error) {
	out, errOut, err := gitOutIn(root, 60*time.Second, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return nil, errors.New(strings.TrimSpace(errOut))
	}
	var files []string
	for _, f := range strings.Split(out, "\x00") {
		if f != "" {
			files = append(files, f)
		}
	}
	return files, nil
}

// firstSnapshotPreview stages nothing: it counts what a snapshot would save.
func firstSnapshotPreview(root string) map[string]any {
	if ok, msg := canonStartOnly(root); !ok {
		return map[string]any{"ok": true, "can_snapshot": false, "reason": msg}
	}
	files, err := untrackedFiles(root)
	if err != nil {
		return map[string]any{"ok": false, "error": "Could not list the files: " + err.Error()}
	}
	truncated := len(files) > firstSnapshotMaxFiles
	if truncated {
		files = files[:firstSnapshotMaxFiles]
	}
	var total int64
	folders := map[string]int{}
	type big struct {
		Path  string `json:"path"`
		Bytes int64  `json:"bytes"`
	}
	var large []big
	for _, f := range files {
		top := "."
		if i := strings.IndexByte(f, '/'); i >= 0 {
			top = f[:i]
		}
		folders[top]++
		if fi, err := os.Lstat(filepath.Join(root, filepath.FromSlash(f))); err == nil {
			total += fi.Size()
			if fi.Size() >= firstSnapshotLarge {
				large = append(large, big{f, fi.Size()})
			}
		}
	}
	type folder struct {
		Name  string `json:"name"`
		Files int    `json:"files"`
	}
	var fl []folder
	for n, c := range folders {
		fl = append(fl, folder{n, c})
	}
	sort.Slice(fl, func(i, j int) bool {
		if fl[i].Files != fl[j].Files {
			return fl[i].Files > fl[j].Files
		}
		return fl[i].Name < fl[j].Name
	})
	if len(fl) > 8 {
		fl = fl[:8]
	}
	sort.Slice(large, func(i, j int) bool { return large[i].Bytes > large[j].Bytes })
	if len(large) > 5 {
		large = large[:5]
	}
	return map[string]any{"ok": true, "can_snapshot": true, "files": len(files), "bytes": total, "folders": fl, "large": large, "truncated": truncated}
}

// gitignoreLine: one file as a root-anchored .gitignore line; the characters a pattern reads specially are escaped.
func gitignoreLine(p string) string {
	var b strings.Builder
	b.WriteByte('/')
	for _, r := range p {
		if strings.ContainsRune(`\*?[]`, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	s := b.String()
	trimmed := strings.TrimRight(s, " ")
	s = trimmed + strings.Repeat(`\ `, len(s)-len(trimmed)) // a trailing space is part of the name only when escaped
	return s
}

// runIn runs a program in root with a timeout; stdout, stderr, the exit code (-1 when it could not run).
func runIn(root string, timeout time.Duration, name string, args ...string) (string, string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if err == nil {
		return out.String(), errb.String(), 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) && ctx.Err() == nil {
		return out.String(), errb.String(), ee.ExitCode()
	}
	return out.String(), errb.String(), -1
}

// firstSnapshot saves the folder's files as one commit. ignore lists files (from the preview) to keep out first.
func firstSnapshot(root string, confirm any, ignore []string) map[string]any {
	fail := func(msg string) map[string]any { return map[string]any{"ok": false, "error": msg} }
	if confirm != true {
		return fail("A first snapshot needs confirm: true.")
	}
	if _, err := exec.LookPath("git"); err != nil {
		return fail("Version history needs Git, which isn't installed on this computer.")
	}
	if ok, msg := canonStartOnly(root); !ok {
		return fail(msg)
	}
	// Fail closed before anything is staged: no scanner, no snapshot.
	croot := canonRootDir()
	script := filepath.Join(croot, "tools", "secret-scan.sh")
	if croot == "" || !exists(script) {
		return fail("The secret scan is not available, so nothing was saved.")
	}
	ignorePath := filepath.Join(root, ".gitignore")
	orig, readErr := os.ReadFile(ignorePath)
	hadIgnore := readErr == nil
	restore := func() {
		if hadIgnore {
			_ = os.WriteFile(ignorePath, orig, 0o644)
		} else {
			_ = os.Remove(ignorePath)
		}
	}
	reset := func() { _, _, _ = runIn(root, 30*time.Second, "git", "reset", "-q") }
	if len(ignore) > 0 {
		files, err := untrackedFiles(root)
		if err != nil {
			return fail("Could not list the files: " + err.Error())
		}
		have := map[string]bool{}
		for _, f := range files {
			have[f] = true
		}
		var lines strings.Builder
		for _, p := range ignore {
			if !have[p] || strings.ContainsAny(p, "\r\n") {
				return fail("That file is not part of the snapshot: " + truncStr(p, 120))
			}
			lines.WriteString(gitignoreLine(p) + "\n")
		}
		body := string(orig)
		if body != "" && !strings.HasSuffix(body, "\n") {
			body += "\n"
		}
		if err := os.WriteFile(ignorePath, []byte(body+lines.String()), 0o644); err != nil {
			restore()
			return fail("Could not update .gitignore: " + err.Error())
		}
	}
	failed := func(msg string) map[string]any { reset(); restore(); return fail(msg) }
	if _, errOut, code := runIn(root, 180*time.Second, "git", "add", "-A", "--", "."); code != 0 {
		return failed("Could not stage the files: " + truncStr(strings.TrimSpace(errOut), 300))
	}
	bash := scanBash()
	if bash == "" {
		return failed("The secret scan needs bash (Git for Windows on Windows), so nothing was saved.")
	}
	_, scanErr, code := runIn(root, 180*time.Second, bash, script, "--staged")
	switch code {
	case 0:
	case 1:
		var found []snapshotFinding
		for _, l := range strings.Split(scanErr, "\n") {
			if m := secretFindingRe.FindStringSubmatch(strings.TrimRight(l, "\r")); m != nil && !strings.HasPrefix(l, "secret-scan:") {
				found = append(found, snapshotFinding{m[1], m[2], m[3]})
			}
		}
		reset()
		return map[string]any{"ok": false, "blocked": true, "findings": found,
			"error": "The secret scan found something in these files. Nothing was saved."}
	default:
		return failed("The secret scan could not run, so nothing was saved.")
	}
	if _, _, c := runIn(root, 30*time.Second, "git", "diff", "--cached", "--quiet"); c == 0 {
		return failed("There is nothing to save yet.")
	}
	var identity []string
	if _, _, err := gitOutIn(root, 10*time.Second, "config", "user.name"); err != nil {
		identity = append(identity, "-c", "user.name=canon")
	}
	if _, _, err := gitOutIn(root, 10*time.Second, "config", "user.email"); err != nil {
		identity = append(identity, "-c", "user.email=canon@localhost")
	}
	if _, errOut, c := runIn(root, 120*time.Second, "git", append(identity, "commit", "-q", "-m", firstSnapshotMessage)...); c != 0 {
		return failed("Could not save the snapshot: " + truncStr(strings.TrimSpace(errOut), 300))
	}
	sha, _, _ := gitOutIn(root, 10*time.Second, "rev-parse", "--short", "HEAD")
	return map[string]any{"ok": true, "commit": strings.TrimSpace(sha)}
}

// scanBash: the bash that runs the scanner, as skillshealth.go finds it. On Windows System32\bash.exe is WSL's, which would read the
// folder through another file system and path spelling: it does not count, and the snapshot fails closed.
func scanBash() string {
	b, err := exec.LookPath("bash")
	if err != nil || (runtime.GOOS == "windows" && strings.Contains(strings.ToLower(filepath.ToSlash(b)), "/windows/system32/")) {
		return ""
	}
	return b
}

func truncStr(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
