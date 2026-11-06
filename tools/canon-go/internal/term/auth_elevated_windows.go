//go:build windows

package term

import "golang.org/x/sys/windows"

// processElevated reads this process's own token: Windows sudo gives an elevated caller no UAC prompt.
func processElevated() bool { return windows.GetCurrentProcessToken().IsElevated() }
