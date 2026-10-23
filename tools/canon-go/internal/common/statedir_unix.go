//go:build !windows

package common

import (
	"fmt"
	"os"
	"syscall"
)

func stateDirOwnerOK(dir string, fi os.FileInfo) error {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return fmt.Errorf("cockpit state folder %s is owned by uid %d, not you (uid %d); remove it and start the cockpit again", dir, st.Uid, os.Getuid())
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("cockpit state folder %s has mode %04o; it must be 0700 (only you). Fix it with: chmod 700 %s", dir, fi.Mode().Perm(), dir)
	}
	return nil
}
