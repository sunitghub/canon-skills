//go:build windows

package term

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The Terminal is the daemon's ConPTY child, so a program started with this process's own stdin and stdout shares that
// console: Git's bash runs inside the same ConPTY with no second pty (t-353a).

func fileExists(p string) bool { st, err := os.Stat(p); return err == nil && !st.IsDir() }

func whereBash() []string {
	// where looks in the current folder first, and this one is the project: ask from a folder nobody else writes to, or not at all
	root := os.Getenv("SystemRoot")
	if root == "" {
		return nil
	}
	cmd := exec.Command("where", "bash.exe")
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	return strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n")
}

func gitBash() string { return findGitBash(os.Getenv, fileExists, whereBash) }

// shellCheck is su's up-front check: no Git bash, no shell, and no OS prompt asked for nothing.
var shellCheck = func() error {
	if gitBash() == "" {
		return ErrNoGitBash
	}
	return nil
}

// RealShell runs Git's bash as a login, interactive shell in the project folder until it exits or ctx ends; at the end the
// whole job (the shell and everything it started) is terminated, as the unix group kill does. A program the shell started in
// its first milliseconds, before the job held it, is outside the job (the process cannot be created suspended through os/exec).
var RealShell = func(ctx context.Context, root string) error {
	bash := gitBash()
	if bash == "" {
		return ErrNoGitBash
	}
	return runOnConsole(ctx, bash, []string{"-l", "-i"}, root, true)
}

// RunOnTerminal runs one program with this console attached (tkt send-issue --launch: claude --cloud needs a console) and
// waits; the cloud session it starts is the user's to keep, so there is no job.
var RunOnTerminal = func(ctx context.Context, path string, args []string, dir string) error {
	return runOnConsole(ctx, path, args, dir, false)
}

// runOnConsole starts path on this console. inJob: the program runs in a job object that ends with ctx and when the program
// exits (su: nothing it started outlives the shell). It fails closed: a program that cannot be put in its job is ended and
// reported, never left running outside the time limit.
func runOnConsole(ctx context.Context, path string, args []string, dir string, inJob bool) error {
	var job windows.Handle
	if inJob {
		var err error
		if job, err = windows.CreateJobObject(nil, nil); err != nil {
			return err
		}
		defer windows.CloseHandle(job)
		var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
		info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
			return err
		}
	}
	cmd := exec.Command(path, args...)
	cmd.Dir = dir
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	// Ctrl-C reaches every process on the console, this one too: while the program runs it is the program's, not ours to exit on.
	intr := make(chan os.Signal, 1)
	signal.Notify(intr, os.Interrupt)
	finished := make(chan struct{})
	go func() {
		for {
			select {
			case <-intr:
			case <-finished:
				return
			}
		}
	}()
	defer func() { close(finished); signal.Stop(intr) }()
	// A program that was ended (or killed with its job) can leave the console in its own mode: put ours back after.
	defer restoreConsoleModes(saveConsoleModes())
	if err := cmd.Start(); err != nil {
		return err
	}
	if inJob {
		if err := assignToJob(job, cmd.Process.Pid); err != nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			return fmt.Errorf("could not put the shell under its time limit, so it was ended: %w", err)
		}
	}
	waited := make(chan struct{})
	watcherGone := make(chan struct{})
	go func() {
		defer close(watcherGone)
		select {
		case <-ctx.Done():
			if inJob {
				_ = windows.TerminateJobObject(job, 1)
			}
		case <-waited:
		}
	}()
	err := cmd.Wait()
	close(waited)
	<-watcherGone // the job handle is closed only after nothing can terminate it
	return err
}

func assignToJob(job windows.Handle, pid int) error {
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	return windows.AssignProcessToJobObject(job, h)
}

// consoleModes are the input and output modes of this console's handles.
type consoleModes struct {
	in, out         uint32
	haveIn, haveOut bool
}

func saveConsoleModes() consoleModes {
	var m consoleModes
	m.haveIn = windows.GetConsoleMode(windows.Handle(os.Stdin.Fd()), &m.in) == nil
	m.haveOut = windows.GetConsoleMode(windows.Handle(os.Stdout.Fd()), &m.out) == nil
	return m
}

func restoreConsoleModes(m consoleModes) {
	if m.haveIn {
		_ = windows.SetConsoleMode(windows.Handle(os.Stdin.Fd()), m.in)
	}
	if m.haveOut {
		_ = windows.SetConsoleMode(windows.Handle(os.Stdout.Fd()), m.out)
	}
}
