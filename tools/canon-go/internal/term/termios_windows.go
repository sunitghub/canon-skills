//go:build windows

package term

import "golang.org/x/sys/windows"

// rawMode turns off the Windows console's own line editing, echo and Ctrl-C handling, and asks for keys as VT sequences,
// so the prompt reads each key itself (Tab completes, arrows walk the history, Ctrl-C arrives as 0x03), as on macOS and
// Linux (t-c8ff; the console's cooked editor had no completion and pasted the previous command on Right). It returns a
// function that puts the saved mode back, or nil when fd is not a console or a call fails: the prompt then reads whole
// lines, as before.
func rawMode(fd int) func() {
	h := windows.Handle(fd)
	var mode uint32
	if err := windows.GetConsoleMode(h, &mode); err != nil {
		return nil
	}
	raw := mode&^(windows.ENABLE_LINE_INPUT|windows.ENABLE_ECHO_INPUT|windows.ENABLE_PROCESSED_INPUT) | windows.ENABLE_VIRTUAL_TERMINAL_INPUT
	if err := windows.SetConsoleMode(h, raw); err != nil {
		return nil
	}
	return func() { _ = windows.SetConsoleMode(h, mode) }
}
