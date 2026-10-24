//go:build windows

package term

// terminalRows is 0 on Windows: cat pages at 24 lines there until the size is read (the prompt itself works).
func terminalRows() int { return 0 }
