//go:build !windows

package term

func processElevated() bool { return false }

// shellCheck is nil off Windows: the login shell always exists.
var shellCheck func() error
