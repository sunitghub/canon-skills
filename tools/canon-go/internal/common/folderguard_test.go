package common

import (
	"os"
	"path/filepath"
	"testing"
)

// TestNotAProject protects the board's start (board.Main refuses a folder this names) and shares its corpus with
// tests/folder-guard.sh, which runs the same kinds through the bash copy of the table.
func TestNotAProject(t *testing.T) {
	home := t.TempDir()
	proj := t.TempDir()
	if err := os.Mkdir(filepath.Join(proj, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitHome := t.TempDir()
	if err := os.Mkdir(filepath.Join(gitHome, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	ticketsOnly := t.TempDir()
	if err := os.Mkdir(filepath.Join(ticketsOnly, ".tickets"), 0o755); err != nil {
		t.Fatal(err)
	}
	plain := t.TempDir() // no git, not a listed folder: a plain folder is a supported project
	sub := filepath.Join(home, "work")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, dir, home, want string
	}{
		{"the filesystem root", "/", home, "the root of a drive"},
		{"a drive root", `C:\`, home, "the root of a drive"},
		{"a drive root, lower case", "c:", home, "the root of a drive"},
		{"System32", `C:\Windows\System32`, home, "a system folder"},
		{"System32, odd case, slashes", "c:/WINDOWS/system32", home, "a system folder"},
		{"the Windows folder", `C:\Windows`, home, "a system folder"},
		{"inside the Windows tree", `C:\Windows\System32\drivers`, home, "a system folder"},
		{"Program Files", `C:\Program Files`, home, "a system folder"},
		{"Program Files (x86)", `C:\Program Files (x86)`, home, "a system folder"},
		{"ProgramData", `D:\ProgramData`, home, "a system folder"},
		{"/usr", "/usr", home, "a system folder"},
		{"/etc", "/etc", home, "a system folder"},
		{"/var", "/var", home, "a system folder"},
		{"/System", "/System", home, "a system folder"},
		{"/Applications", "/Applications", home, "a system folder"},
		{"/bin", "/bin", home, "a system folder"},
		{"/private/etc (macOS's own name for /etc)", "/private/etc", home, "a system folder"},
		{"/private/var", "/private/var", home, "a system folder"},
		{"a folder under /private/var is fine", "/private/var/folders/x/T", home, ""},
		{"/sbin", "/sbin", home, "a system folder"},
		{"/opt", "/opt", home, "a system folder"},
		{"/Library", "/Library", home, "a system folder"},
		{"a folder inside Program Files is fine", `C:\Program Files\Foo`, home, ""},
		{"a folder that only starts with Windows is fine", `C:\Windowsfoo`, home, ""},
		{"a drive-looking piece in the middle is not a drive", "/tmp/c:/windows/x", home, ""},
		{"a user folder is fine", `C:\Users\sam\proj`, home, ""},
		{"the home folder", home, home, "your home folder"},
		{"a unix subfolder is fine", "/usr/local/src/p", home, ""},
		{"a temp folder under /var is fine", filepath.Join(plain), home, ""},
		{"a folder inside home is fine", sub, home, ""},
		{"a plain folder with no git is fine", plain, home, ""},
		{"a git project is fine", proj, home, ""},
		{"a dotfiles repository in the home folder is a project", gitHome, gitHome, ""},
		{".tickets alone does not rescue the home folder", ticketsOnly, ticketsOnly, "your home folder"},
		{"a .tickets-only folder is fine", ticketsOnly, home, ""},
		{"an empty home is never matched", plain, "", ""},
	}
	for _, c := range cases {
		if got := NotAProject(c.dir, c.home); got != c.want {
			t.Errorf("%s: NotAProject(%q) = %q, want %q", c.name, c.dir, got, c.want)
		}
	}
}
