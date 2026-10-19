//go:build !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// t-15d8: the daemon the board starts leads its own session, so a Ctrl-C to the `canon` terminal's process group
// never reaches it (server.py's start_new_session=True).
func TestDetachDaemonStartsOwnSession(t *testing.T) {
	cmd := exec.Command("sleep", "5")
	detachDaemon(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	sid, err := getsid(cmd.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	if sid != cmd.Process.Pid {
		t.Fatalf("daemon session id = %d, want its own pid %d (not detached)", sid, cmd.Process.Pid)
	}
	pgid, _ := syscall.Getpgid(cmd.Process.Pid)
	if pgid == syscall.Getpgrp() {
		t.Fatalf("daemon shares the board's process group %d", pgid)
	}
}

func getsid(pid int) (int, error) {
	r, _, errno := syscall.RawSyscall(syscall.SYS_GETSID, uintptr(pid), 0, 0)
	if errno != 0 {
		return 0, errno
	}
	return int(r), nil
}

// t-15d8: board git calls (track-changes, ticket-commit) run with GIT_TERMINAL_PROMPT=0, so a credential prompt
// fails instead of hanging a request that has no terminal.
func TestGitOutInDisablesTerminalPrompt(t *testing.T) {
	bin := t.TempDir()
	fake := "#!/bin/sh\nprintf '%s' \"$GIT_TERMINAL_PROMPT\"\n"
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("GIT_TERMINAL_PROMPT", "1")
	out, _, err := gitOutIn(t.TempDir(), 5*time.Second, "status")
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(out) != "0" {
		t.Fatalf("GIT_TERMINAL_PROMPT seen by git = %q, want 0", out)
	}
}

// t-15d8: ensureCockpit, the one place the board starts the daemon, detaches it before starting it (a test of the helper
// alone passes even if the call is dropped).
func TestEnsureCockpitDetachesBeforeStart(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	i := strings.Index(s, "func ensureCockpit(")
	if i < 0 {
		t.Fatal("ensureCockpit not found in main.go")
	}
	body := s[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	d, st := strings.Index(body, "detachDaemon(cmd)"), strings.Index(body, "cmd.Start()")
	if d < 0 || st < 0 || d > st {
		t.Fatalf("ensureCockpit must call detachDaemon(cmd) before cmd.Start() (detach at %d, start at %d)", d, st)
	}
}
