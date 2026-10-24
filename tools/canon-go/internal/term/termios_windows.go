//go:build windows

package term

// rawMode: the Windows terminal keeps its own line editing; the prompt reads whole lines.
func rawMode(fd int) func() { return nil }
