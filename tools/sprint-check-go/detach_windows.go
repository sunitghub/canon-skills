//go:build windows

package main

import "os/exec"

// detachDaemon (t-15d8): Windows has no POSIX session; the daemon already outlives the board there (detach_unix.go
// adds Setsid).
func detachDaemon(cmd *exec.Cmd) {}
