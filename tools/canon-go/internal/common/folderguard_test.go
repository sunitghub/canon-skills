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
		name, dir, want string
	}{
		{"the filesystem root", "/", "the root of a drive"},
		{"a drive root", `C:\`, "the root of a drive"},
		{"a drive root, lower case", "c:", "the root of a drive"},
		{"System32", `C:\Windows\System32`, "a system folder"},
		{"System32, odd case, slashes", "c:/WINDOWS/system32", "a system folder"},
		{"the Windows folder", `C:\Windows`, "a system folder"},
		{"inside the Windows tree", `C:\Windows\System32\drivers`, "a system folder"},
		{"Program Files", `C:\Program Files`, "a system folder"},
		{"Program Files (x86)", `C:\Program Files (x86)`, "a system folder"},
		{"ProgramData", `D:\ProgramData`, "a system folder"},
		{"/usr", "/usr", "a system folder"},
		{"/etc", "/etc", "a system folder"},
		{"/var", "/var", "a system folder"},
		{"/System", "/System", "a system folder"},
		{"/Applications", "/Applications", "a system folder"},
		{"/bin", "/bin", "a system folder"},
		{"/private/etc (macOS's own name for /etc)", "/private/etc", "a system folder"},
		{"/private/var", "/private/var", "a system folder"},
		{"a folder under /private/var is fine", "/private/var/folders/x/T", ""},
		{"/sbin", "/sbin", "a system folder"},
		{"/opt", "/opt", "a system folder"},
		{"/Library", "/Library", "a system folder"},
		{"a folder inside Program Files is fine", `C:\Program Files\Foo`, ""},
		{"a folder that only starts with Windows is fine", `C:\Windowsfoo`, ""},
		{"a drive-looking piece in the middle is not a drive", "/tmp/c:/windows/x", ""},
		{"a user folder is fine", `C:\Users\sam\proj`, ""},
		{"the home folder is a project like any other (t-dec4)", home, ""},
		{"a unix subfolder is fine", "/usr/local/src/p", ""},
		{"a temp folder under /var is fine", filepath.Join(plain), ""},
		{"a folder inside home is fine", sub, ""},
		{"a plain folder with no git is fine", plain, ""},
		{"a git project is fine", proj, ""},
		{"a dotfiles repository in the home folder is a project", gitHome, ""},
		{"a .tickets-only folder is fine", ticketsOnly, ""},
	}
	for _, c := range cases {
		if got := NotAProject(c.dir); got != c.want {
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
	win := NotAProjectMessage("tkt", "/c/Windows/System32", "a system folder", `C:\Users\agentops`, "windows")
	wantWin := `tkt: C:\Windows\System32 is not a project (a system folder with no git repository). Make a folder for your work, for example: mkdir "C:\Users\agentops\projects\demo", cd into it, run git init, then run tkt again.`
	if len(win) != 1 || win[0] != wantWin {
		t.Errorf("windows message:\n%q\nwant:\n%q", win, wantWin)
	}
	unix := NotAProjectMessage("canon", "/usr", "a system folder", "/home/sam", "linux")
	wantUnix := `canon: /usr is not a project (a system folder with no git repository). Make a folder for your work, for example: mkdir -p "/home/sam/projects/demo", cd into it, run git init, then run canon again.`
	if len(unix) != 1 || unix[0] != wantUnix {
		t.Errorf("unix message: %q", unix)
	}
}

// t-dec4: home is a project when the walk starts there, and a folder under home never adopts home's .tickets.
func TestSkipTicketsAndIsHome(t *testing.T) {
	home := t.TempDir()
	under := filepath.Join(home, "Documents")
	if err := os.Mkdir(under, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, dir, start string
		want             bool
	}{
		{"home, walk started in home: taken", home, home, false},
		{"home, walk started under home: skipped", home, under, true},
		{"a folder under home is taken", under, under, false},
		{"a system folder is skipped", "/etc", "/etc", true},
		{"a drive root is skipped", `C:\`, `C:\`, true},
	} {
		if got := SkipTickets(c.dir, c.start, home); got != c.want {
			t.Errorf("%s: SkipTickets(%q,%q) = %v, want %v", c.name, c.dir, c.start, got, c.want)
		}
	}
	if !IsHome(home, home) || IsHome(under, home) || IsHome(home, "") {
		t.Error("IsHome: wrong")
	}
}
