//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

// detachDaemon (t-15d8): the daemon gets its own session, so it outlives the board and a Ctrl-C in the `canon`
// terminal (sent to the launcher's process group) never reaches it.
func detachDaemon(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}
