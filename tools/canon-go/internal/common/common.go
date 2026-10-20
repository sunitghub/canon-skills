// Package common holds the helpers the board and the cockpit daemon had as identical copies (t-8020).
package common

import (
	"os"
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
