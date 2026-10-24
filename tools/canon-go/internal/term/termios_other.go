//go:build !windows && !linux && !darwin

package term

// saveTerminal does nothing where the terminal modes are not read (the release builds are linux, macOS and Windows).
func saveTerminal(fd int) func() { return func() {} }
