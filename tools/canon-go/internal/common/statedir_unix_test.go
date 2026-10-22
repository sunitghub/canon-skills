//go:build !windows

package common

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSecureStateDir(t *testing.T) {
	base := t.TempDir()

	missing := filepath.Join(base, "new", "canon-cockpit")
	if err := SecureStateDir(missing); err != nil {
		t.Fatalf("missing folder: %v", err)
	}
	if fi, _ := os.Stat(missing); fi.Mode().Perm() != 0o700 {
		t.Fatalf("created mode %04o, want 0700", fi.Mode().Perm())
	}

	open := filepath.Join(base, "open")
	os.Mkdir(open, 0o755)
	os.Chmod(open, 0o755)
	if err := SecureStateDir(open); err == nil || !strings.Contains(err.Error(), "must be 0700") {
		t.Fatalf("0755 folder must be refused, got %v", err)
	}
	if fi, _ := os.Stat(open); fi.Mode().Perm() != 0o755 {
		t.Fatal("SecureStateDir must never chmod an existing folder")
	}

	link := filepath.Join(base, "link")
	os.Symlink(missing, link)
	if err := SecureStateDir(link); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("symlinked folder must be refused, got %v", err)
	}

	file := filepath.Join(base, "file")
	os.WriteFile(file, nil, 0o600)
	if err := SecureStateDir(file); err == nil || !strings.Contains(err.Error(), "cockpit state folder "+file) {
		t.Fatalf("a file in place of the folder must be refused naming it, got %v", err)
	}
}

// Another account's folder is refused even at 0700. Changing a folder's owner needs root, so this runs only as root.
func TestSecureStateDirRefusesOtherOwner(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("needs root to chown")
	}
	dir := filepath.Join(t.TempDir(), "theirs")
	os.Mkdir(dir, 0o700)
	if err := os.Chown(dir, 65534, 65534); err != nil {
		t.Skip(err)
	}
	if err := SecureStateDir(dir); err == nil || !strings.Contains(err.Error(), "owned by uid 65534") {
		t.Fatalf("another account's folder must be refused, got %v", err)
	}
}

func TestDefaultCockpitStateDirIsPerUser(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/4242")
	if got := DefaultCockpitStateDir(); got != "/run/user/4242/canon-cockpit" {
		t.Fatalf("DefaultCockpitStateDir = %q", got)
	}
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("XDG_CACHE_HOME", "/home/someone/.cache")
	if got := DefaultCockpitStateDir(); got != "/home/someone/.cache/canon-cockpit" {
		t.Fatalf("without XDG_RUNTIME_DIR the default is the user cache dir, got %q", got)
	}
	t.Setenv("XDG_CACHE_HOME", "")
	t.Setenv("HOME", "")
	if _, err := os.UserCacheDir(); err == nil {
		t.Skip("this platform still finds a cache dir without HOME")
	}
	if got := DefaultCockpitStateDir(); got != filepath.Join(os.TempDir(), "canon-cockpit") {
		t.Fatalf("with no cache dir the last resort is %s, got %q", filepath.Join(os.TempDir(), "canon-cockpit"), got)
	}
}
