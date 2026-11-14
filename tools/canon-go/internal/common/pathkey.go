package common

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// t-9d04: the one Go owner of "the same folder" (slice 3 of t-141a). PathKey is canon_path_key's Go twin (tools/platform-lib.sh, the awk
// text canon_awk_pkey): a pure function of the string, the same answer on every OS, checked row by row against tests/fixtures/path-keys.tsv.
// The contract and its sources: docs/research-path-and-rule-standards.md section 1.5. A key is for comparing, never a path to hand to
// another program. Only the drive letter is lower-cased: lower-casing a whole path would merge /c/Foo and /c/foo on macOS and Linux.

var (
	pkUNCRe   = regexp.MustCompile(`^\\+[^\\]`)
	pkBackRe  = regexp.MustCompile(`\\+`)
	pkSlashRe = regexp.MustCompile(`/+`)
	pkDriveRe = regexp.MustCompile(`^[A-Za-z]:(/|$)`)
	pkTrailRe = regexp.MustCompile(`[^/]/+$`)
)

// PathKey is the key of one path: a UNC prefix stays //host/share, every run of backslashes is one /, every other run of slashes is one,
// C:\x, C:/x and /c/x are /c/x, a trailing slash goes (a bare / or // stays), a newline is encoded %0A. A . or .. segment is left as it is.
func PathKey(p string) string {
	p = strings.ReplaceAll(p, "\n", "%0A")
	unc := pkUNCRe.MatchString(p)
	p = pkBackRe.ReplaceAllString(p, "/")
	if unc {
		p = "/" + p
	}
	lead := len(p) > 2 && p[0] == '/' && p[1] == '/' && p[2] != '/'
	p = pkSlashRe.ReplaceAllString(p, "/")
	if lead {
		p = "/" + p
	}
	if pkDriveRe.MatchString(p) {
		p = "/" + strings.ToLower(p[:1]) + p[2:]
	}
	if pkTrailRe.MatchString(p) {
		p = strings.TrimRight(p, "/")
	}
	return p
}

// ResolvedKey is PathKey of the path with its links resolved when it exists (filepath.EvalSymlinks; on Windows that also gives the
// on-disk case), else of the path as given: the form for a map key, where identity cannot be asked.
func ResolvedKey(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		p = r
	}
	return PathKey(p)
}

// SamePath: the same folder. When both exist, file identity decides (os.SameFile: device and inode, or volume and file index on Windows),
// so two different folders never match by spelling (a POSIX folder named `root\` is not `root`). Otherwise the ResolvedKeys are compared.
// An empty path is never the same folder as anything. The shell's canon_same_folder also falls back after a "no" until -ef is verified on
// Git Bash (t-e88d); Go's SameFile needs no such fallback.
func SamePath(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	sa, ea := os.Stat(a)
	sb, eb := os.Stat(b)
	if ea == nil && eb == nil {
		return os.SameFile(sa, sb)
	}
	return ResolvedKey(a) == ResolvedKey(b)
}
