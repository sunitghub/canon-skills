//go:build windows

package main

import (
	pty "github.com/aymanbagabas/go-pty"
)

// killProcess terminates the session process on Windows. The ConPTY is also
// closed by the caller (handleKill), which tears down the pseudo-console the
// child is attached to. Killing the full child tree (taskkill /T) is a
// documented follow-up; Windows runtime is validated on a Windows box.
func killProcess(c *pty.Cmd) {
	if c == nil || c.Process == nil {
		return
	}
	_ = c.Process.Kill()
}
