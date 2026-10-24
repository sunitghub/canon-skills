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

// rawMode turns off line editing, echo and signal keys on the terminal so the prompt can read each key (Tab, arrows,
// Ctrl-C) itself, and returns a function that puts the modes back. nil when fd is not a terminal.
func rawMode(fd int) func() {
	t, err := unix.IoctlGetTermios(fd, unix.TIOCGETA)
	if err != nil {
		return nil
	}
	r := *t
	r.Lflag &^= unix.ICANON | unix.ECHO | unix.ISIG | unix.IEXTEN
	r.Cc[unix.VMIN], r.Cc[unix.VTIME] = 1, 0
	if err := unix.IoctlSetTermios(fd, unix.TIOCSETA, &r); err != nil {
		return nil
	}
	return func() { _ = unix.IoctlSetTermios(fd, unix.TIOCSETA, t) }
}
