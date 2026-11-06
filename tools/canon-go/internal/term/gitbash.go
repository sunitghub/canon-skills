package term

import (
	"errors"
	"strings"
)

// ErrNoGitBash means no Git for Windows bash was found: su and the launch hand-off need it on Windows.
var ErrNoGitBash = errors.New("Git for Windows is required (https://git-scm.com/download/win): its bash.exe was not found")

// findGitBash finds Git's bash.exe in the order tools/tkt.cmd uses, so the Console and the board run the same bash. The path
// from `where` counts only inside a Git folder: System32\bash.exe is WSL's, which does not run canon's tools. Paths use
// backslashes on every OS so the order is testable anywhere. "" means none.
func findGitBash(getenv func(string) string, exists func(string) bool, where func() []string) string {
	var cands []string
	if pf := getenv("ProgramFiles"); pf != "" {
		cands = append(cands, pf+`\Git\bin\bash.exe`, pf+`\Git\usr\bin\bash.exe`)
	}
	if pf := getenv("ProgramFiles(x86)"); pf != "" {
		cands = append(cands, pf+`\Git\bin\bash.exe`)
	}
	if la := getenv("LocalAppData"); la != "" {
		cands = append(cands, la+`\Programs\Git\bin\bash.exe`)
	}
	for _, p := range cands {
		if exists(p) {
			return p
		}
	}
	for _, p := range where() {
		p = strings.TrimSpace(p)
		if i := strings.Index(strings.ToLower(p), `\git\`); i >= 0 && strings.HasSuffix(strings.ToLower(p), `bash.exe`) {
			return p
		}
	}
	return ""
}
