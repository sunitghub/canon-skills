//go:build !windows

package term

import (
	"os"

	"golang.org/x/sys/unix"
)

// terminalRows is the height of the terminal on stdout, or 0 when it cannot be read.
func terminalRows() int {
	ws, err := unix.IoctlGetWinsize(int(os.Stdout.Fd()), unix.TIOCGWINSZ)
	if err != nil {
		return 0
	}
	return int(ws.Row)
}
