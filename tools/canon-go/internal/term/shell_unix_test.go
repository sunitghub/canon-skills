//go:build !windows

package term

import (
	"context"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
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
