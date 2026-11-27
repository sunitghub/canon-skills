package board

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"
)

// t-2800: a file the board serves or writes under a root is a rootLoc, and every read or write of it opens an *os.Root
// for that one call. A path check alone (Clean, EvalSymlinks, Rel) leaves a window: a folder swapped for a link after
// the check moves the I/O outside. os.Root refuses any link that leaves the root, an absolute one included, at the
// moment of the I/O. The root is opened per call, never cached, so no handle pins a folder (Windows) or goes stale.
type rootLoc struct {
	dir string // opened with os.OpenRoot (links in dir itself are followed, as before)
	sub string // optional folder under dir, opened as a nested root, so rel cannot leave it either
	rel string // the file under dir (or sub)
}

// afterPathCheck is the swap test's seam: it runs after the caller's path check, before the root opens. nil in prod.
var afterPathCheck func()

func (l rootLoc) do(fn func(r *os.Root, name string) error) error {
	if afterPathCheck != nil {
		afterPathCheck()
	}
	r, err := os.OpenRoot(l.dir)
	if err != nil {
		return err
	}
	defer r.Close()
	if l.sub != "" {
		inner, err := r.OpenRoot(filepath.FromSlash(l.sub))
		if err != nil {
			return err
		}
		defer inner.Close()
		r = inner
	}
	return fn(r, filepath.FromSlash(l.rel))
}

func (l rootLoc) base() string { return filepath.Base(filepath.FromSlash(l.rel)) }

// errNotRegular: read refuses a FIFO, device or folder (t-fe8d).
var errNotRegular = errors.New("not a regular file")

// read opens with the nonblock flag and reads only a regular file, so a FIFO planted under the root cannot block the
// request (t-fe8d; Root.ReadFile opened it blocking).
func (l rootLoc) read() (b []byte, err error) {
	err = l.do(func(r *os.Root, name string) error {
		f, err := r.OpenFile(name, os.O_RDONLY|nonblockFlag, 0)
		if err != nil {
			return err
		}
		defer f.Close()
		if fi, err := f.Stat(); err != nil {
			return err
		} else if !fi.Mode().IsRegular() {
			return errNotRegular
		}
		b, err = io.ReadAll(f)
		return err
	})
	return b, err
}

func (l rootLoc) stat() (fi os.FileInfo, err error) {
	err = l.do(func(r *os.Root, name string) error { fi, err = r.Stat(name); return err })
	return fi, err
}

func (l rootLoc) lstat() (fi os.FileInfo, err error) {
	err = l.do(func(r *os.Root, name string) error { fi, err = r.Lstat(name); return err })
	return fi, err
}

func (l rootLoc) exists() bool {
	_, err := l.stat()
	return err == nil
}

// write creates the missing parent folders (0755) and writes data (0644), as os.MkdirAll + os.WriteFile did.
func (l rootLoc) write(data []byte) error { return l.writeMode(data, 0644) }

// writeMode is write with the new file's mode (the .worktreeinclude copy keeps the source's, t-fe8d).
func (l rootLoc) writeMode(data []byte, mode os.FileMode) error {
	return l.do(func(r *os.Root, name string) error {
		if err := r.MkdirAll(filepath.Dir(name), 0755); err != nil {
			return err
		}
		return r.WriteFile(name, data, mode)
	})
}

func (l rootLoc) remove() error {
	return l.do(func(r *os.Root, name string) error { return r.Remove(name) })
}

// openNonblock opens for reading with the per-OS nonblock flag (themeopen_*.go): a file swapped for a FIFO cannot block.
func (l rootLoc) openNonblock() (f *os.File, err error) {
	err = l.do(func(r *os.Root, name string) error {
		f, err = r.OpenFile(name, os.O_RDONLY|nonblockFlag, 0)
		return err
	})
	return f, err
}

// atomicWrite replaces the file by a temp file in the same folder and a rename, both inside the root (os.Root has no
// CreateTemp: a random name opened O_EXCL), so no reader ever sees a half-written doc. A new file is 0644; an existing
// one keeps its mode. Windows refuses to replace a file another process has open, so the rename is retried briefly.
func (l rootLoc) atomicWrite(data []byte) error {
	return l.do(func(r *os.Root, name string) error {
		var tmp string
		var f *os.File
		var err error
		for i := 0; i < 8; i++ {
			var rb [8]byte
			if _, err = rand.Read(rb[:]); err != nil {
				return err
			}
			tmp = filepath.Join(filepath.Dir(name), ".board-"+hex.EncodeToString(rb[:])+".tmp")
			if f, err = r.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600); !errors.Is(err, os.ErrExist) {
				break
			}
		}
		if err != nil {
			return err
		}
		_, werr := f.Write(data)
		if werr == nil {
			werr = f.Sync()
		}
		if cerr := f.Close(); werr == nil {
			werr = cerr
		}
		if werr != nil {
			r.Remove(tmp)
			return werr
		}
		mode := os.FileMode(0o644)
		if fi, err := r.Stat(name); err == nil {
			mode = fi.Mode().Perm()
		}
		_ = r.Chmod(tmp, mode)
		var rerr error
		for i := 0; i < 6; i++ {
			if rerr = r.Rename(tmp, name); rerr == nil {
				return nil
			}
			time.Sleep(50 * time.Millisecond)
		}
		r.Remove(tmp)
		return rerr
	})
}

// atomicWriteFile is atomicWrite for a path the caller built itself (tags.go's project files): rooted at its folder.
func atomicWriteFile(target string, data []byte) error {
	return rootLoc{dir: filepath.Dir(target), rel: filepath.Base(target)}.atomicWrite(data)
}
