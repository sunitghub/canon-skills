//go:build !windows

package term

import (
	"context"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Protects the five-minute end: when the context ends, the shell's whole process group goes, so a program started
// inside it does not outlive su.
func TestRunSpecKillsTheProcessGroup(t *testing.T) {
	out := &safeBuf{}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runSpec(ctx, shellSpec{Path: "/bin/sh", Args: []string{"-c", "sleep 60 & echo child=$!; wait"}, Dir: t.TempDir(), In: strings.NewReader(""), Out: out})
	}()
	re := regexp.MustCompile(`child=(\d+)`)
	var pid int
	for i := 0; i < 300 && pid == 0; i++ {
		if m := re.FindStringSubmatch(out.String()); m != nil {
			pid, _ = strconv.Atoi(m[1])
		}
		time.Sleep(10 * time.Millisecond)
	}
	if pid == 0 {
		t.Fatalf("no child pid in %q", out.String())
	}
	cancel()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("runSpec did not return after the context ended")
	}
	for i := 0; i < 300; i++ {
		if err := syscall.Kill(pid, 0); err != nil {
			return // gone
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Errorf("the program started inside the shell (pid %d) outlived the context", pid)
}

// Protects the speed and the fallback of the end: a hang-up stops an ordinary shell quickly; a shell that ignores the
// hang-up is killed after the grace period instead of holding the prompt forever.
func TestRunSpecEndsPromptly(t *testing.T) {
	for _, c := range []struct {
		name, script string
		max          time.Duration
	}{
		// A process started under nohup has SIGHUP ignored and its children inherit that, so this one may end through the
		// kill after the 2 s grace period instead of the hang-up: both are the design, so the bound is the grace plus slack.
		{"hangup", "sleep 60 & wait", 2500 * time.Millisecond},
		{"ignores hangup", "trap '' HUP; while :; do sleep 1; done", 4 * time.Second},
	} {
		ctx, cancel := context.WithCancel(context.Background())
		started := make(chan struct{})
		out := &safeBuf{}
		done := make(chan error, 1)
		go func() {
			close(started)
			done <- runSpec(ctx, shellSpec{Path: "/bin/sh", Args: []string{"-c", c.script}, Dir: t.TempDir(), In: strings.NewReader(""), Out: out})
		}()
		<-started
		time.Sleep(300 * time.Millisecond) // let the shell start
		begin := time.Now()
		cancel()
		select {
		case <-done:
			if took := time.Since(begin); took > c.max {
				t.Errorf("%s: took %v to end, want under %v", c.name, took, c.max)
			}
		case <-time.After(c.max + 3*time.Second):
			t.Fatalf("%s: the shell was never stopped", c.name)
		}
	}
}

// A shell that exits on its own is not signalled afterwards (its process group id could belong to someone else by then).
func TestRunSpecShellExitsFirst(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	out := &safeBuf{}
	if err := runSpec(ctx, shellSpec{Path: "/bin/sh", Args: []string{"-c", "echo done"}, Dir: t.TempDir(), In: strings.NewReader(""), Out: out}); err != nil {
		t.Fatal(err)
	}
	cancel()
	time.Sleep(100 * time.Millisecond)
	if !strings.Contains(out.String(), "done") {
		t.Errorf("output %q", out.String())
	}
}

// Protects ordinary terminals: when the prompt is not the leader of its own session (it was started from someone's shell),
// the end-of-su sweep must touch nothing, because the session is that person's whole terminal.
func TestSweepSessionLeavesOtherSessionsAlone(t *testing.T) {
	if sid, _ := unix.Getsid(0); sid == os.Getpid() {
		t.Skip("this test process leads its own session; the sweep would be allowed to act")
	}
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() }()
	sweepSession()
	time.Sleep(200 * time.Millisecond)
	if err := syscall.Kill(cmd.Process.Pid, 0); err != nil {
		t.Errorf("the sweep killed a process although this one does not lead its session: %v", err)
	}
}
