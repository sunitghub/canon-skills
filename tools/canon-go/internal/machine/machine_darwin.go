//go:build darwin

package machine

import (
	"runtime"

	"golang.org/x/sys/unix"
)

// nativeArch: sysctl.proc_translated is 1 for a process Rosetta runs, which only an Apple Silicon Mac does, so the machine is arm64.
func nativeArch() string {
	if v, err := unix.SysctlUint32("sysctl.proc_translated"); err == nil && v == 1 && runtime.GOARCH == "amd64" {
		return "arm64"
	}
	return ""
}

func readOS(f *Facts) {
	f.OSName = "macOS"
	if v, err := unix.Sysctl("kern.osproductversion"); err == nil && v != "" {
		f.OSVersion = v
	}
	if v, err := unix.Sysctl("kern.osrelease"); err == nil && v != "" {
		f.Kernel = "Darwin " + v
	}
	if n, err := unix.SysctlUint64("hw.memsize"); err == nil {
		f.RAMGB = gb(n)
	}
}
