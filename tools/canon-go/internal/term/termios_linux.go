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
