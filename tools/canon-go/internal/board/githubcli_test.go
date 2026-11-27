package board

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"canon/internal/settings"
)

// t-393e: `canon github on|off|status`. Prod path: the shipped `canon github` command (tools/canon → sprint-check github).
func TestGitHubCLI(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	stub := filepath.Join(t.TempDir(), "security")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nexit 44\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	oldBin, oldOS := settings.SecurityBin, settings.GitHubGOOS
	settings.SecurityBin, settings.GitHubGOOS = stub, "darwin"
	t.Cleanup(func() { settings.SecurityBin, settings.GitHubGOOS = oldBin, oldOS })

	w, err := filepath.EvalSymlinks(t.TempDir()) // git prints the physical spelling (/private/var on macOS)
	if err != nil {
		t.Fatal(err)
	}
	repo, wt := filepath.Join(w, "it's repo"), filepath.Join(w, "wt")
	git := func(args ...string) {
		t.Helper()
		c := exec.Command("git", args...)
		c.Env = append(os.Environ(), "HOME="+w, "GIT_CONFIG_NOSYSTEM=1")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	git("init", "-q", repo)
	git("-C", repo, "-c", "user.name=t", "-c", "user.email=t@e", "commit", "-q", "--allow-empty", "-m", "x")
	git("-C", repo, "worktree", "add", "-q", wt)
	run := func(args ...string) (int, string, string) {
		var o, e bytes.Buffer
		code := githubCLI(args, &o, &e)
		return code, o.String(), e.String()
	}

	for _, bad := range [][]string{{}, {"enable"}, {"on", wt, "x"}} {
		if code, _, e := run(bad...); code != 2 || !strings.Contains(e, "usage: canon github on | off | status") {
			t.Errorf("%q: exit %d %q, want 2 with usage", bad, code, e)
		}
	}
	if code, o, _ := run("status", repo); code != 0 || !strings.Contains(o, "restricted GitHub access: off") {
		t.Errorf("status before on: %d %q", code, o)
	}
	if code, o, e := run("on", wt); code != 0 || !strings.Contains(o, "on for "+repo) {
		t.Fatalf("on from the worktree: %d %q %q, want the main checkout %s", code, o, e, repo)
	}
	roots, err := settings.RestrictedRoots(home)
	if err != nil || len(roots) != 1 || !settings.SameFolder(roots[0], repo) {
		t.Fatalf("recorded %q %v, want the main checkout", roots, err)
	}
	if code, o, _ := run("on", repo); code != 0 || !strings.Contains(o, "already on") {
		t.Errorf("second on: %d %q", code, o)
	}
	code, o, _ := run("status", wt)
	quoted := `'` + strings.ReplaceAll(repo, `'`, `'\''`) + `'`
	if code != 0 || !strings.Contains(o, "restricted GitHub access: on") || !strings.Contains(o, "token: none") ||
		!strings.Contains(o, "security add-generic-password -U -s canon-github -a "+quoted+" -w\n") {
		t.Errorf("status on: %d %q", code, o)
	}
	// the printed line runs in a shell as one argument for -a, even with a quote in the folder name
	line := "printf '%s\\n' -a " + quoted
	if out, err := exec.Command("sh", "-c", line).Output(); err != nil || string(out) != "-a\n"+repo+"\n" {
		t.Errorf("pasted -a argument: %q %v", out, err)
	}
	if code, o, _ := run("off", repo); code != 0 || !strings.Contains(o, "off for") {
		t.Errorf("off: %d %q", code, o)
	}
	if roots, _ := settings.RestrictedRoots(home); len(roots) != 0 {
		t.Errorf("after off: %q", roots)
	}
	if err := os.WriteFile(filepath.Join(home, "settings.json"), []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, e := run("on", repo); code != 1 || !strings.Contains(e, "every Cockpit claude session is restricted") {
		t.Errorf("malformed settings: %d %q, want 1 naming the fail-closed effect", code, e)
	}
	if b, _ := os.ReadFile(filepath.Join(home, "settings.json")); string(b) != "{broken" {
		t.Errorf("a malformed settings file was rewritten: %q", b)
	}
	if code, _, _ := run("status", t.TempDir()); code != 1 {
		t.Errorf("status outside a repository: exit %d, want 1", code)
	}
}
