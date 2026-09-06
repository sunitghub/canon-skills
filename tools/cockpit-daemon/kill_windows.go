//go:build windows

package main

import (
	"os/exec"

	pty "github.com/aymanbagabas/go-pty"
)

// killProcess terminates the session process AND its children on Windows.
// c.Process.Kill() alone reaps only the top process, orphaning whatever the
// agent spawned (claude's helpers, node, etc.) — the Windows analogue of the
// process-group kill kill_unix.go does. `taskkill /T` walks the process tree
// and `/F` forces it; the call is best-effort (the process may already be gone,
// so its error is ignored) and c.Process.Kill() still runs as a fallback, the
// same both-paths belt-and-suspenders as the unix side. The ConPTY is closed by
// the caller (handleKill), which does not reliably reap grandchildren — hence
// the explicit tree kill (t-902f, closing t-8a63's documented follow-up).
func killProcess(c *pty.Cmd) {
	if c == nil || c.Process == nil {
		return
	}
	_ = exec.Command("taskkill", taskkillTreeArgs(c.Process.Pid)...).Run()
	_ = c.Process.Kill()
}
