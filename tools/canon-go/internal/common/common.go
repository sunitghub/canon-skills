// Package common holds the helpers the board and the cockpit daemon had as identical copies (t-8020).
package common

import (
	"os"
	"path/filepath"
	"regexp"
)

// SessionIDRe is a live session's id: a ticket (t-xxxx) or a scratch session (s-xxxx).
var SessionIDRe = regexp.MustCompile(`^[ts]-[a-z0-9]{4}$`)

// EnvOr returns the environment variable name, or fallback when it is unset or empty.
func EnvOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// Getwd is the working directory, or "" when it cannot be read.
func Getwd() string {
	wd, _ := os.Getwd()
	return wd
}

// VersionString renders the build id "<semver> (<sha>)" when a real commit is stamped, else the semver alone.
// tools/fetch-daemon.sh reads the "(<sha>)" part, so keep that shape.
func VersionString(semver, commit string) string {
	if commit != "" && commit != "dev" {
		return semver + " (" + commit + ")"
	}
	return semver
}

// TicketVisibleIn (t-6bae) reports whether tkt run in the linked worktree dir finds ticket id, by the rule tools/ticket-root.sh's
// tickets_dir walks: the worktree's own .tickets/ wins when it has one (an adopted worktree, t-3abc), so the ticket must be in it;
// with none, tkt resolves the worktree's .git file back to the main checkout's .tickets/ (t-cd06), where the caller has already
// found the ticket. A .tickets entry of any kind (a link included) counts as the worktree's own, as bash's -d test would.
func TicketVisibleIn(dir, id string) bool {
	if _, err := os.Lstat(filepath.Join(dir, ".tickets")); os.IsNotExist(err) {
		return true
	}
	fi, err := os.Stat(filepath.Join(dir, ".tickets", id))
	return err == nil && fi.IsDir()
}
