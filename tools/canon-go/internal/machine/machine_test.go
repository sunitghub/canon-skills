package machine

import (
	"os"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// t-c542: the facts every event's host, machine.seen, `canon-go machine` (evidence headers), /api/version and the ticket's
// Machines node read. Prod path: events.Emit's envelope and the board's machine routes.
func TestGetReadsThisMachine(t *testing.T) {
	f := Get()
	want, _ := os.Hostname()
	if f.Host != strings.TrimSpace(want) || f.Host == "" {
		t.Fatalf("Host = %q, want os.Hostname() %q", f.Host, want)
	}
	if f.OS != runtime.GOOS || f.Arch != runtime.GOARCH {
		t.Fatalf("OS/Arch = %s/%s, want %s/%s", f.OS, f.Arch, runtime.GOOS, runtime.GOARCH)
	}
	if n, err := strconv.Atoi(f.CPUs); err != nil || n != runtime.NumCPU() {
		t.Fatalf("CPUs = %q, want %d", f.CPUs, runtime.NumCPU())
	}
	if runtime.GOOS == "darwin" || runtime.GOOS == "linux" || runtime.GOOS == "windows" {
		for name, v := range map[string]string{"os_name": f.OSName, "os_version": f.OSVersion, "kernel": f.Kernel, "ram_gb": f.RAMGB} {
			if v == "" || v == Unknown {
				t.Errorf("%s = %q: a supported OS reads it", name, v)
			}
		}
		if n, err := strconv.Atoi(f.RAMGB); err != nil || n < 1 {
			t.Errorf("RAMGB = %q, want whole GB ≥ 1", f.RAMGB)
		}
	}
	if Get() != f {
		t.Fatal("a second Get differs: facts are read once")
	}
}

func TestLineHasNoHostname(t *testing.T) {
	f := Facts{Host: "secret-host", OS: "darwin", OSName: "macOS", OSVersion: "26.1", Kernel: "Darwin 25.1.0", Arch: "arm64", CPUs: "10", RAMGB: "32"}
	if got, want := f.Line(), "macOS 26.1, Darwin 25.1.0, arm64, 10 cores, 32 GB"; got != want {
		t.Fatalf("Line = %q, want %q", got, want)
	}
	if strings.Contains(f.Line(), "secret-host") {
		t.Fatal("Line carries the hostname (t-a83a: evidence headers never do)")
	}
	w := Facts{OSName: "Windows 11", OSVersion: "10.0.26100", Kernel: "NT 10.0.26100", Arch: "amd64", CPUs: "4", RAMGB: "8"}
	if got, want := w.Line(), "Windows 11 10.0.26100, amd64, 4 cores, 8 GB"; got != want {
		t.Fatalf("Windows Line = %q, want %q", got, want)
	}
	u := Facts{OSName: "Ubuntu 24.04.1 LTS", OSVersion: "24.04", Kernel: "Linux 6.8.0-49-generic", Arch: "amd64", CPUs: "4", RAMGB: Unknown}
	if got, want := u.Line(), "Ubuntu 24.04.1 LTS, Linux 6.8.0-49-generic, amd64, 4 cores, unknown GB"; got != want {
		t.Fatalf("Linux Line = %q, want %q", got, want)
	}
}

func TestOSReleaseAndWindowsName(t *testing.T) {
	name, ver := osRelease("NAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\nID=ubuntu\n")
	if name != "Ubuntu 24.04.1 LTS" || ver != "24.04" {
		t.Fatalf("osRelease = %q, %q", name, ver)
	}
	if n, v := osRelease("garbage\n=\n"); n != "" || v != "" {
		t.Fatalf("osRelease of garbage = %q, %q, want empty", n, v)
	}
	for _, c := range []struct {
		maj, min, build uint32
		want            string
	}{{10, 0, 26100, "Windows 11"}, {10, 0, 22000, "Windows 11"}, {10, 0, 19045, "Windows 10"}, {6, 3, 9600, "Windows 6.3"}} {
		if got := windowsName(c.maj, c.min, c.build); got != c.want {
			t.Errorf("windowsName(%d.%d.%d) = %q, want %q", c.maj, c.min, c.build, got, c.want)
		}
	}
	if gb(0) != Unknown || gb(34359738368) != "32" || gb(17179869184-(1<<28)) != "16" {
		t.Fatalf("gb rounding: %s %s %s", gb(0), gb(34359738368), gb(17179869184-(1<<28)))
	}
}
