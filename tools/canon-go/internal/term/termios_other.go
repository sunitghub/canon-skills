//go:build !windows && !linux && !darwin

package term

// saveTerminal does nothing where the terminal modes are not read (the release builds are linux, macOS and Windows).
func saveTerminal(fd int) func() { return func() {} }

// rawMode: no key-by-key input where the terminal modes are not read; the prompt reads whole lines.
func rawMode(fd int) func() { return nil }
