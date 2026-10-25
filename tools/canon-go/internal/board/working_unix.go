//go:build !windows

package board

import "syscall"

// pidAlive: signal 0 only checks that the process exists; EPERM means it exists but is not ours.
func pidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}
