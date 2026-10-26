package common

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// t-b2ff: canon must not treat a system folder, a drive root or the home folder as a project: run there by mistake (an
// Administrator PowerShell opens in C:\Windows\System32) it would serve, and then fill, a folder nobody keeps tickets in.
// NotAProject says why a folder is refused, or "" when it is fine. The same table lives in tools/ticket-root.sh
// (folder_guard_reason) for the launcher, tkt and sprint; tests/folder-guard.sh and the test here run one corpus through both.

var (
	driveRootRe    = regexp.MustCompile(`^[a-z]:/?$`)
	windowsTreeRe  = regexp.MustCompile(`^[a-z]:/windows(/|$)`)
	windowsExactRe = regexp.MustCompile(`^[a-z]:/(program files|program files \(x86\)|programdata)$`)
	unixSystem     = map[string]bool{"/usr": true, "/bin": true, "/sbin": true, "/etc": true, "/var": true, "/private/etc": true, "/private/var": true, "/opt": true, "/system": true, "/library": true, "/applications": true}
)

// NotAProject returns the reason dir is refused ("a system folder" or "the root of a drive") or "". The home folder is NOT refused (t-dec4:
// it is a project like any other); IsHome is how the walk-up recognises it, so a walk that started below home stops there.
// A .git at dir (inside the Windows tree: at dir or any folder above it) makes it a project; a .tickets folder never does.
// The folder is checked as given and with its links resolved (/var is /private/var on macOS).
func NotAProject(dir string) string {
	abs := dir
	if len(dir) < 2 || dir[1] != ':' { // a drive path is classified by its name on any OS
		var err error
		if abs, err = filepath.Abs(dir); err != nil {
			return ""
		}
	}
	abs = strings.ReplaceAll(abs, `\`, "/")
	forms := []string{abs}
	if r, err := filepath.EvalSymlinks(abs); err == nil && r != abs {
		forms = append(forms, r)
	}
	for _, f := range forms {
		if why := refused(f); why != "" {
			return why
		}
	}
	return ""
}

func refused(abs string) string {
	p := strings.ToLower(filepath.ToSlash(abs))
	why, tree := "", windowsTreeRe.MatchString(p)
	switch {
	case p == "/" || driveRootRe.MatchString(p):
		why = "the root of a drive"
	case tree || windowsExactRe.MatchString(p) || unixSystem[p]:
		why = "a system folder"
	default:
		return ""
	}
	for d := abs; ; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return ""
		}
		if !tree || filepath.Dir(d) == d {
			return why
		}
	}
}

// IsHome says dir is the home folder itself (links resolved, case ignored). t-dec4: home is a project only for a walk that started IN it; a
// folder under home never walks up into home or above it (t-5738), so findProjectRoot and ticketsDirIn stop at home.
func IsHome(dir, home string) bool {
	if home == "" || dir == "" {
		return false
	}
	abs := dir
	if len(dir) < 2 || dir[1] != ':' {
		var err error
		if abs, err = filepath.Abs(dir); err != nil {
			return false
		}
	}
	return sameFolder(abs, home)
}

// sameFolder: the same folder, resolving links and ignoring case (Windows and macOS file systems do).
func sameFolder(a, b string) bool {
	if r, err := filepath.EvalSymlinks(b); err == nil {
		b = r
	}
	if r, err := filepath.EvalSymlinks(a); err == nil {
		a = r
	}
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}

var gitBashDriveRe = regexp.MustCompile(`^/([a-zA-Z])(/.*)?$`)

// DisplayPath is a folder as the user's own shell spells it (t-dec4). A PowerShell user does not know Git Bash's /c/Users/x: on Windows
// it becomes C:\Users\x, and a drive path written with slashes gets backslashes. Anywhere else it is unchanged. goos is runtime.GOOS
// (a parameter so the table is tested on every OS).
func DisplayPath(p, goos string) string {
	if goos != "windows" {
		return p
	}
	if m := gitBashDriveRe.FindStringSubmatch(p); m != nil {
		return strings.ToUpper(m[1]) + `:` + strings.ReplaceAll(m[2], "/", `\`)
	}
	if len(p) >= 2 && p[1] == ':' {
		return strings.ReplaceAll(p, "/", `\`)
	}
	return p
}

// NotAProjectMessage is what canon, tkt and sprint print when the folder is refused (a system folder or a drive root; t-dec4): why, and a folder
// to make with a command the user's shell accepts (Windows: mkdir "C:\Users\x\projects\demo", works in PowerShell, cmd and Git Bash;
// elsewhere mkdir -p). tools/ticket-root.sh prints the same words (require_project_folder); tests/folder-guard.sh compares the two.
func NotAProjectMessage(tool, dir, why, home, goos string) []string {
	shown, h := DisplayPath(dir, goos), DisplayPath(home, goos)
	sep, mk := "/", "mkdir -p"
	if goos == "windows" {
		sep, mk = `\`, "mkdir"
	}
	demo := h + sep + "projects" + sep + "demo"
	return []string{tool + ": " + shown + " is not a project (" + why + " with no git repository). Make a folder for your work, for example: " + mk + ` "` + demo + `", cd into it, run git init, then run ` + tool + " again."}
}
