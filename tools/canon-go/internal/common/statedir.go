package common

import (
	"fmt"
	"os"
	"path/filepath"
)

// DefaultCockpitStateDir is the per-user folder where the cockpit daemon publishes daemon.json (its address and boot
// token), hook settings and its pid: $XDG_RUNTIME_DIR, else the user cache dir. The board and the daemon share it
// (t-68ae: the board used a fixed os.TempDir() path any local account could create first).
func DefaultCockpitStateDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "canon-cockpit")
	}
	if d, err := os.UserCacheDir(); err == nil {
		return filepath.Join(d, "canon-cockpit")
	}
	return filepath.Join(os.TempDir(), "canon-cockpit")
}

// SecureStateDir creates dir 0700 when it is missing (MkdirAll fails on a file), then refuses it when it is a
// symlink or (on unix) owned by another user or open to group or others. It never changes an existing folder's mode or owner.
func SecureStateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("cockpit state folder %s: %v", dir, err)
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return fmt.Errorf("cockpit state folder %s: %v", dir, err)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("cockpit state folder %s is a symlink; remove it and start the cockpit again", dir)
	}
	return stateDirOwnerOK(dir, fi)
}
