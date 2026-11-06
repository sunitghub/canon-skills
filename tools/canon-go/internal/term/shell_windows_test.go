//go:build windows

package term

import (
	"context"
	"os/exec"
	"testing"
	"time"
)

// Protects su on Windows (prod path: RealShell's job ends the shell and what it started at the ten minutes). Runs on the
// Windows VM only: this was written on a Mac and has not run there.
func TestJobEndsTheProgramAndItsChild(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	// cmd starts ping (the child); both must end when ctx does
	go func() { done <- runInJob(ctx, "cmd.exe", []string{"/c", "ping -n 60 127.0.0.1 >nul"}, t.TempDir(), true) }()
	time.Sleep(2 * time.Second)
	cancel()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the job was not ended when ctx ended")
	}
	if out, _ := exec.Command("tasklist", "/FI", "IMAGENAME eq PING.EXE", "/NH").Output(); len(out) > 0 && containsPing(string(out)) {
		t.Errorf("the child outlived the job:\n%s", out)
	}
}

func containsPing(s string) bool {
	for i := 0; i+8 <= len(s); i++ {
		if s[i:i+8] == "PING.EXE" || s[i:i+8] == "ping.exe" {
			return true
		}
	}
	return false
}
