//go:build windows

package term

import (
	"context"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func pingRunning() bool {
	out, _ := exec.Command("tasklist", "/FI", "IMAGENAME eq PING.EXE", "/NH").Output()
	return strings.Contains(strings.ToUpper(string(out)), "PING.EXE")
}

// Protects su on Windows (prod path: RealShell's job ends the shell and what it started when the ten minutes run out). Runs on
// the Windows VM only: this was written on a Mac and has not run there. It needs no other PING.EXE running on the machine.
func TestJobEndsTheProgramAndItsChildAtTheLimit(t *testing.T) {
	if pingRunning() {
		t.Skip("another PING.EXE is running")
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	// cmd starts ping (the child); both must end when ctx does
	go func() {
		done <- runOnConsole(ctx, "cmd.exe", []string{"/c", "ping -n 60 127.0.0.1 >nul"}, t.TempDir(), true)
	}()
	time.Sleep(2 * time.Second)
	cancel()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the job was not ended when ctx ended")
	}
	if pingRunning() {
		t.Errorf("the child outlived the job")
	}
}

// Same prod path, the `exit` case the docs promise: the shell leaves a background program running, and closing the job ends it.
func TestJobEndsWhatTheShellLeftBehindWhenItExits(t *testing.T) {
	if pingRunning() {
		t.Skip("another PING.EXE is running")
	}
	if err := runOnConsole(context.Background(), "cmd.exe", []string{"/c", "start /b ping -n 60 127.0.0.1 >nul"}, t.TempDir(), true); err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Second)
	if pingRunning() {
		t.Errorf("a program the shell started outlived the shell")
	}
}

// Protects su on Windows (prod path: OSAuth's elevation refusal reads this): the process token's elevation must match what Windows
// itself says, `net session` succeeding only for an elevated caller. Runs on the Windows VM only; written on a Mac, not run there.
func TestProcessElevatedMatchesWindows(t *testing.T) {
	want := exec.Command("net", "session").Run() == nil
	if got := processElevated(); got != want {
		t.Errorf("processElevated() = %v, but `net session` says elevated = %v", got, want)
	}
}
