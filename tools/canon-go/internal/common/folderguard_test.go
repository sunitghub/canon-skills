package common

import (
	"os"
	"path/filepath"
	"strings"
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

// Protects the first-run refusal a Windows user reads (t-dec4): the folder in the user's own form, and a command their shell accepts.
func TestDisplayPath(t *testing.T) {
	for _, c := range []struct{ in, goos, want string }{
		{"/c/Users/agentops", "windows", `C:\Users\agentops`},
		{"/c/Users/a b/projects", "windows", `C:\Users\a b\projects`},
		{"/c", "windows", `C:`},
		{"C:/Users/x", "windows", `C:\Users\x`},
		{`C:\Users\x`, "windows", `C:\Users\x`},
		{"/c/Users/agentops", "linux", "/c/Users/agentops"},
		{"/home/x", "darwin", "/home/x"},
		{"/home/x", "windows", "/home/x"}, // a one-letter first folder is the only thing read as a drive; /home is not
	} {
		if got := DisplayPath(c.in, c.goos); got != c.want {
			t.Errorf("DisplayPath(%q,%q) = %q, want %q", c.in, c.goos, got, c.want)
		}
	}
}

func TestNotAProjectMessage(t *testing.T) {
	win := NotAProjectMessage("tkt", "/c/Users/agentops", "your home folder", `C:\Users\agentops`, true, "windows")
	wantWin := []string{
		`tkt: C:\Users\agentops is not a project (your home folder with no git repository). Make a folder for your work, for example: mkdir "C:\Users\agentops\projects\demo", cd into it, run git init, then run tkt again.`,
		`tkt: C:\Users\agentops has a .tickets folder with tickets in it, left by an earlier run. If they belong to a project, move the folder into it (nothing here moves it for you), for a project that has no .tickets yet: move "C:\Users\agentops\.tickets" "C:\Users\agentops\projects\demo\.tickets"`,
	}
	if strings.Join(win, "\n") != strings.Join(wantWin, "\n") {
		t.Errorf("windows message:\n%s\nwant:\n%s", strings.Join(win, "\n"), strings.Join(wantWin, "\n"))
	}
	unix := NotAProjectMessage("canon", "/home/sam", "your home folder", "/home/sam", false, "linux")
	wantUnix := `canon: /home/sam is not a project (your home folder with no git repository). Make a folder for your work, for example: mkdir -p "/home/sam/projects/demo", cd into it, run git init, then run canon again.`
	if len(unix) != 1 || unix[0] != wantUnix {
		t.Errorf("unix message: %q", unix)
	}
	if got := NotAProjectMessage("canon", "/usr", "a system folder", "/home/sam", true, "linux"); len(got) != 1 {
		t.Errorf("the move hint is for the home folder only: %q", got)
	}
}
