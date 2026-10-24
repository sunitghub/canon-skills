//go:build linux

package term

import "golang.org/x/sys/unix"

// saveTerminal remembers the terminal's modes (echo, line editing, newline handling) and returns a function that puts
// them back, so a program killed while it had the terminal raw (less, vim) does not leave the prompt without echo.
func saveTerminal(fd int) func() {
	t, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	if err != nil {
		return func() {}
	}
	return func() { _ = unix.IoctlSetTermios(fd, unix.TCSETS, t) }
}

// rawMode turns off line editing, echo and signal keys on the terminal so the prompt can read each key (Tab, arrows,
// Ctrl-C) itself, and returns a function that puts the modes back. nil when fd is not a terminal.
func rawMode(fd int) func() {
	t, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	if err != nil {
		return nil
	}
	r := *t
	r.Lflag &^= unix.ICANON | unix.ECHO | unix.ISIG | unix.IEXTEN
	r.Cc[unix.VMIN], r.Cc[unix.VTIME] = 1, 0
	if err := unix.IoctlSetTermios(fd, unix.TCSETS, &r); err != nil {
		return nil
	}
	return func() { _ = unix.IoctlSetTermios(fd, unix.TCSETS, t) }
}
