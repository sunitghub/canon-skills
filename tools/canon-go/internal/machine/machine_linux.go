//go:build linux

package machine

import (
	"os"

	"golang.org/x/sys/unix"
)

func readOS(f *Facts) {
	f.OSName = "Linux"
	if b, err := os.ReadFile("/etc/os-release"); err == nil {
		if name, ver := osRelease(string(b)); name != "" {
			f.OSName = name
			if ver != "" {
				f.OSVersion = ver
			}
		}
	}
	var u unix.Utsname
	if unix.Uname(&u) == nil {
		f.Kernel = "Linux " + unix.ByteSliceToString(u.Release[:])
	}
	var si unix.Sysinfo_t
	if unix.Sysinfo(&si) == nil {
		f.RAMGB = gb(uint64(si.Totalram) * uint64(si.Unit))
	}
}
