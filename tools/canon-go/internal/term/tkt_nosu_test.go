package term

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeTkt is a tkt that records that it ran (marker) and what it was given.
func fakeTkt(t *testing.T) (bin, marker string) {
	t.Helper()
	marker = filepath.Join(t.TempDir(), "ran")
	bin = filepath.Join(t.TempDir(), "tkt")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho \"$@\" >> "+marker+"\necho ran-$1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, marker
}

// Protects the ten tkt commands the Terminal runs without su: each runs, and each writes one terminal.tkt event naming the
// subcommand only (never an argument); a read-only command writes none; merge-pr and the rest are refused with no event.
func TestRunTktIsAuditedByNameOnly(t *testing.T) {
	root, _ := project(t)
	bin, marker := fakeTkt(t)
	for _, s := range RunTkt() {
		_ = os.Remove(marker)
		f := newFakeSu()
		cfg := f.cfg(root)
		cfg.Tkt = bin
		out := run(t, cfg, "tkt "+s+" t-ab12 secret-title\nexit\n")
		if !strings.Contains(out, "ran-"+s) {
			t.Errorf("tkt %s should run without su:\n%s", s, out)
		}
		if got, want := f.log(), "terminal.tkt sub="+s; got != want {
			t.Errorf("tkt %s: events %q, want %q", s, got, want)
		}
		if strings.Contains(f.log(), "t-ab12") || strings.Contains(f.log(), "secret") {
			t.Errorf("tkt %s: an argument reached the log: %q", s, f.log())
		}
	}
	for _, s := range []string{"ls", "show", "merge-pr", "push-main", "worktree-reset", "land", "compact"} {
		f := newFakeSu()
		cfg := f.cfg(root)
		cfg.Tkt = bin
		_ = os.Remove(marker)
		run(t, cfg, "tkt "+s+" x\nexit\n")
		if f.log() != "" {
			t.Errorf("tkt %s wrote an event: %q", s, f.log())
		}
	}
}

// Protects the fail-closed rule for the ten: when terminal.tkt cannot be written, nothing runs.
func TestRunTktFailsClosedWhenTheLogCannotBeWritten(t *testing.T) {
	root, _ := project(t)
	bin, marker := fakeTkt(t)
	cfg := Config{Root: root, Tkt: bin, Session: "sid", Ticket: "s-ab12",
		Emit: func(string, map[string]string) error { return errors.New("disk full") }}
	out := run(t, cfg, "tkt create x\nexit\n")
	if _, err := os.Stat(marker); err == nil || !strings.Contains(out, "the audit log cannot be written") {
		t.Errorf("tkt ran although its event could not be written:\n%s", out)
	}
}

// Protects the two flags that stay behind su on every tkt subcommand: --test runs any command, --body-file reads any file.
func TestSuFlagsAreRefusedEverywhere(t *testing.T) {
	root, _ := project(t)
	bin, marker := fakeTkt(t)
	for _, sub := range append(append(ReadOnlyTkt(), RunTkt()...), "merge-pr") {
		for _, flag := range []string{"--test", "--test=true", "--body-file", "--body-file=/etc/passwd"} {
			for _, line := range []string{"tkt " + sub + " " + flag, "tkt " + sub + " t-ab12 " + flag + " x", "tkt " + sub + " -d hi " + flag} {
				_ = os.Remove(marker)
				f := newFakeSu()
				cfg := f.cfg(root)
				cfg.Tkt = bin
				out := run(t, cfg, line+"\nexit\n")
				if _, err := os.Stat(marker); err == nil || !strings.Contains(out, "not allowed here") {
					t.Errorf("%q must be refused without su:\n%s", line, out)
				}
				if f.log() != "" {
					t.Errorf("%q wrote an event: %q", line, f.log())
				}
			}
		}
	}
}

// Protects send-issue --launch: it goes to the runner that gives it the real terminal, not through the pager's pipe, with
// the project as its folder; with no runner (Windows) it says so, names PowerShell and Git Bash, and runs nothing.
func TestSendIssueLaunchUsesTheTerminal(t *testing.T) {
	root, _ := project(t)
	bin, marker := fakeTkt(t)
	var gotPath, gotDir string
	var gotArgs []string
	f := newFakeSu()
	cfg := f.cfg(root)
	cfg.Tkt = bin
	cfg.RunOnTerminal = func(_ context.Context, path string, args []string, dir string) error {
		gotPath, gotArgs, gotDir = path, args, dir
		return nil
	}
	run(t, cfg, "tkt send-issue t-ab12 --launch\nexit\n")
	if gotPath != bin || strings.Join(gotArgs, " ") != "send-issue t-ab12 --launch" || gotDir != root {
		t.Errorf("runner got %q %v in %q", gotPath, gotArgs, gotDir)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("--launch also ran through the pager pipe")
	}
	if f.log() != "terminal.tkt sub=send-issue" {
		t.Errorf("events %q", f.log())
	}
	// A plain send-issue (no --launch) keeps the paged output.
	_ = os.Remove(marker)
	gotPath = ""
	if out := run(t, cfg, "tkt send-issue t-ab12 --dry-run\nexit\n"); !strings.Contains(out, "ran-send-issue") || gotPath != "" {
		t.Errorf("send-issue without --launch must not use the terminal runner:\n%s", out)
	}
	// No runner: Windows.
	_ = os.Remove(marker)
	cfg.RunOnTerminal = nil
	out := run(t, cfg, "tkt send-issue t-ab12 --launch\nexit\n")
	if _, err := os.Stat(marker); err == nil || !strings.Contains(out, "PowerShell or Git Bash") {
		t.Errorf("without a runner --launch must refuse and say where to paste it:\n%s", out)
	}
}
