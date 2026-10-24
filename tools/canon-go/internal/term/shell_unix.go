//go:build !windows

package term

import (
	"context"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// shellSpec is one shell run; tests give it pipes and a plain program.
type shellSpec struct {
	Path       string
	Args       []string
	Dir        string
	In         io.Reader
	Out        io.Writer
	Foreground bool // hand the terminal to the shell's process group (the real pty), and take it back after
	Sweep      bool // when the shell ends, also end everything else it started in this terminal's session
}

// loginShell is the full shell su starts: the user's own login shell on the pty.
func loginShell(root string) shellSpec {
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/sh"
	}
	return shellSpec{Path: sh, Args: []string{"-l"}, Dir: root, In: os.Stdin, Out: os.Stdout, Foreground: true, Sweep: true}
}

// RealShell runs the user's login shell until it exits or ctx ends.
func RealShell(ctx context.Context, root string) error { return runSpec(ctx, loginShell(root)) }

// runSpec runs the shell in its own process group and, when ctx ends, hangs up and then kills that whole group, so a
// program started inside the shell does not outlive the ten minutes.
func runSpec(ctx context.Context, sp shellSpec) error {
	cmd := exec.Command(sp.Path, sp.Args...)
	cmd.Dir = sp.Dir
	cmd.Stdin, cmd.Stdout, cmd.Stderr = sp.In, sp.Out, sp.Out
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	restoreModes := func() {}
	if sp.Foreground {
		restoreModes = saveTerminal(int(os.Stdin.Fd()))
		cmd.SysProcAttr.Foreground = true
		cmd.SysProcAttr.Ctty = int(os.Stdin.Fd())
		// The prompt writes to the terminal while the shell owns it: a background process would get SIGTTOU.
		signal.Ignore(syscall.SIGTTOU, syscall.SIGTTIN)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	pgid := cmd.Process.Pid
	finished := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			select {
			case <-finished: // the shell already ended: its group id may belong to someone else now
				return
			default:
			}
			_ = syscall.Kill(-pgid, syscall.SIGHUP)
			select {
			case <-finished:
			case <-time.After(2 * time.Second):
				_ = syscall.Kill(-pgid, syscall.SIGKILL)
			}
		case <-finished:
		}
	}()
	err := cmd.Wait()
	close(finished)
	if sp.Sweep {
		sweepSession()
	}
	if sp.Foreground {
		_ = unix.IoctlSetPointerInt(int(os.Stdin.Fd()), unix.TIOCSPGRP, syscall.Getpgrp())
		restoreModes() // after the foreground is ours again: a killed program may have left the terminal raw
	}
	return err
}

// sweepSession ends every process left in this terminal's session, so a background job the shell started (a shell that
// does not hang its jobs up, such as dash, leaves them running) does not outlive su. It only runs when this process is
// the leader of its own session, as the daemon makes it: started from an ordinary terminal, the session is the user's
// whole terminal and nothing is touched. A program that starts a session of its own (setsid) is out of reach.
func sweepSession() {
	me := os.Getpid()
	sid, err := unix.Getsid(0)
	if err != nil || sid != me {
		return
	}
	out, err := exec.Command("ps", "-A", "-o", "pid=").Output()
	if err != nil {
		return
	}
	for _, f := range strings.Fields(string(out)) {
		pid, err := strconv.Atoi(f)
		if err != nil || pid <= 1 || pid == me {
			continue
		}
		if s, err := unix.Getsid(pid); err == nil && s == sid {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
}
