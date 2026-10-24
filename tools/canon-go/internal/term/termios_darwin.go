//go:build darwin

package term

import "golang.org/x/sys/unix"

// saveTerminal remembers the terminal's modes and returns a function that puts them back (see termios_linux.go).
func saveTerminal(fd int) func() {
	t, err := unix.IoctlGetTermios(fd, unix.TIOCGETA)
	if err != nil {
		return func() {}
	}
	return func() { _ = unix.IoctlSetTermios(fd, unix.TIOCSETA, t) }
}
