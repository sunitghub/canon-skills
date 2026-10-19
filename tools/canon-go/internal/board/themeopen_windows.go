//go:build windows

package board

import "os"

// themeOpen (t-f889): Windows has no FIFO a file could be swapped for, so a plain open (themeopen_unix.go adds
// O_NONBLOCK).
func themeOpen(path string) (*os.File, error) {
	return os.Open(path)
}
