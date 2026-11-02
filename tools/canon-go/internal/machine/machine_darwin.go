//go:build darwin

package machine

import "golang.org/x/sys/unix"

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
