package common

import (
	"errors"
	"os"
)

// The refusals of OpenRegular (t-adcb). The texts are events' seal errors, which alias them.
var (
	ErrNotRegular = errors.New("not a regular file")
	ErrChanged    = errors.New("changed while opening")
)

// afterLstat runs between OpenRegular's Lstat and its open; a test swaps the file there. Nil in production.
var afterLstat func()

// SameRegular reports whether opened (an fstat) is a regular file and the same file as before (an Lstat). Identity alone is
// not enough (t-adcb): Linux gives a FIFO made after an unlink the freed inode number, so os.SameFile matches the FIFO.
func SameRegular(before, opened os.FileInfo) bool {
	return opened.Mode().IsRegular() && os.SameFile(before, opened)
}

// OpenRegular opens path for reading only when it is a regular, non-link file, and the file opened is still that one. The
// open does not block, so a file swapped for a FIFO after the Lstat is refused instead of hanging the caller. It returns the
// opened file's info for the caller's size checks.
func OpenRegular(path string) (*os.File, os.FileInfo, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, nil, ErrNotRegular
	}
	if afterLstat != nil {
		afterLstat()
	}
	f, err := os.OpenFile(path, os.O_RDONLY|NonblockFlag, 0)
	if err != nil {
		return nil, nil, err
	}
	ofi, err := f.Stat()
	switch {
	case err != nil:
		f.Close()
		return nil, nil, err
	case !ofi.Mode().IsRegular():
		f.Close()
		return nil, nil, ErrNotRegular
	case !SameRegular(fi, ofi):
		f.Close()
		return nil, nil, ErrChanged
	}
	return f, ofi, nil
}
