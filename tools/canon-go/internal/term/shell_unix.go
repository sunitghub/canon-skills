//go:build !windows

package term

import (
	"context"
	"io"
	"os"
	"os/exec"
	"os/signal"
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
}

// loginShell is the full shell su starts: the user's own login shell on the pty.
func loginShell(root string) shellSpec {
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/sh"
	}
	return shellSpec{Path: sh, Args: []string{"-l"}, Dir: root, In: os.Stdin, Out: os.Stdout, Foreground: true}
}

// RealShell runs the user's login shell until it exits or ctx ends.
func RealShell(ctx context.Context, root string) error { return runSpec(ctx, loginShell(root)) }

// runSpec runs the shell in its own process group and, when ctx ends, hangs up and then kills that whole group, so a
// program started inside the shell does not outlive the five minutes.
func runSpec(ctx context.Context, sp shellSpec) error {
	cmd := exec.Command(sp.Path, sp.Args...)
	cmd.Dir = sp.Dir
	cmd.Stdin, cmd.Stdout, cmd.Stderr = sp.In, sp.Out, sp.Out
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if sp.Foreground {
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
	if sp.Foreground {
		_ = unix.IoctlSetPointerInt(int(os.Stdin.Fd()), unix.TIOCSPGRP, syscall.Getpgrp())
	}
	return err
}
