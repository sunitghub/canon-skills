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
	unixSystem     = map[string]bool{"/usr": true, "/bin": true, "/sbin": true, "/etc": true, "/var": true, "/opt": true, "/system": true, "/library": true, "/applications": true}
)

// NotAProject returns the reason dir is refused ("a system folder", "your home folder", "the root of a drive") or "".
// A .git at dir (inside the Windows tree: at dir or any folder above it) makes it a project; a .tickets folder never does.
// The folder is checked as given and with its links resolved (/var is /private/var on macOS).
func NotAProject(dir, home string) string {
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
		if why := refused(f, home); why != "" {
			return why
		}
	}
	return ""
}

func refused(abs, home string) string {
	p := strings.ToLower(filepath.ToSlash(abs))
	why, tree := "", windowsTreeRe.MatchString(p)
	switch {
	case p == "/" || driveRootRe.MatchString(p):
		why = "the root of a drive"
	case tree || windowsExactRe.MatchString(p) || unixSystem[p]:
		why = "a system folder"
	case home != "" && sameFolder(abs, home):
		why = "your home folder"
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
