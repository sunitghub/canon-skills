//go:build !windows

package main

import (
	"syscall"

	pty "github.com/aymanbagabas/go-pty"
)

// killProcess terminates the session's whole process group. go-pty starts the
// child with Setsid, so it is a session/group leader (pgid == pid); killing the
// negative pid reaps the agent and any children it spawned — no orphans.
func killProcess(c *pty.Cmd) {
	if c == nil || c.Process == nil {
		return
	}
	pid := c.Process.Pid
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	_ = c.Process.Kill()
}
