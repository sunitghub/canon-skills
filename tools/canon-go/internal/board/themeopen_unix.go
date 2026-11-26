//go:build !windows

package board

import (
	"os"
	"syscall"
)

// themeOpen (t-f889): O_NONBLOCK, so a theme file swapped for a FIFO after its Lstat cannot block the request forever
// (break-it). server.py opens the same way.
func themeOpen(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|nonblockFlag, 0)
}

// nonblockFlag is the same flag for a read through an os.Root (rootLoc.openNonblock, t-2800).
const nonblockFlag = syscall.O_NONBLOCK
