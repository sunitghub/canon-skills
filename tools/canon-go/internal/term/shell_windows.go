//go:build windows

package term

import (
	"context"
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
	// where looks in the current folder first, and this one is the project: ask from a folder nobody else writes to
	cmd := exec.Command("where", "bash.exe")
	cmd.Dir = os.Getenv("SystemRoot")
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
// whole job (the shell and everything it started) is terminated, as the unix group kill does.
var RealShell = func(ctx context.Context, root string) error {
	bash := gitBash()
	if bash == "" {
		return ErrNoGitBash
	}
	return runInJob(ctx, bash, []string{"-l", "-i"}, root, true)
}

// RunOnTerminal runs one program with this console attached (tkt send-issue --launch: claude --cloud needs a console), in a job
// so it can be ended, and waits. A program it leaves running is not ended: the cloud session is the user's to keep.
var RunOnTerminal = func(ctx context.Context, path string, args []string, dir string) error {
	return runInJob(ctx, path, args, dir, false)
}

// runInJob starts path on this console inside a job object. killOnClose ends everything the job holds when the program exits
// (su: nothing it started outlives the shell); ctx ending always terminates the job.
func runInJob(ctx context.Context, path string, args []string, dir string, killOnClose bool) error {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(job)
	if killOnClose {
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
	if err := cmd.Start(); err != nil {
		return err
	}
	if h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid)); err == nil {
		_ = windows.AssignProcessToJobObject(job, h)
		_ = windows.CloseHandle(h)
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = windows.TerminateJobObject(job, 1)
		case <-done:
		}
	}()
	err = cmd.Wait()
	close(done)
	return err
}
