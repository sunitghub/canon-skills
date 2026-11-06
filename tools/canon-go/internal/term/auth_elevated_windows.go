//go:build windows

package term

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// processElevated reads this process's own token: Windows sudo gives an elevated caller no UAC prompt. A token that cannot be
// read counts as elevated (x/sys's IsElevated would say false), so doubt means su refuses.
func processElevated() bool {
	var elevated uint32
	var n uint32
	if err := windows.GetTokenInformation(windows.GetCurrentProcessToken(), windows.TokenElevation, (*byte)(unsafe.Pointer(&elevated)), uint32(unsafe.Sizeof(elevated)), &n); err != nil {
		return true
	}
	return elevated != 0
}
