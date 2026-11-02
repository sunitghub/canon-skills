// Package machine is the one place canon reads facts about the computer it runs on (t-c542): the hostname for every
// event's envelope, and the OS, version, chip, cores and RAM for machine.seen, `canon-go machine` (evidence headers),
// /api/version and the ticket's Machines node. Each fact is read once per process; one it cannot read is "unknown",
// never 0 or a guess.
package machine

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
)

// Unknown is the value of a fact that could not be read.
const Unknown = "unknown"

// Facts describes this machine. Every field is a string so "unknown" fits; JSON names are the machine.seen field names.
type Facts struct {
	Host      string `json:"host"`
	OS        string `json:"os"`         // runtime.GOOS: darwin, linux, windows
	OSName    string `json:"os_name"`    // macOS, Windows 11, Ubuntu 24.04.1 LTS
	OSVersion string `json:"os_version"` // 26.1, 10.0.26100, 24.04
	Kernel    string `json:"kernel"`     // Darwin 25.1.0, Linux 6.8.0-49-generic, NT 10.0.26100
	Arch      string `json:"arch"`       // runtime.GOARCH
	CPUs      string `json:"cpus"`       // logical cores
	RAMGB     string `json:"ram_gb"`     // total, whole GB
}

var (
	once  sync.Once
	facts Facts
)

// Get returns this machine's facts, read on the first call.
func Get() Facts {
	once.Do(func() { facts = read() })
	return facts
}

// Host is the raw hostname, or "unknown".
func Host() string { return Get().Host }

func read() Facts {
	f := Facts{Host: Unknown, OS: runtime.GOOS, Arch: runtime.GOARCH, CPUs: strconv.Itoa(runtime.NumCPU()),
		OSName: Unknown, OSVersion: Unknown, Kernel: Unknown, RAMGB: Unknown}
	if h, err := os.Hostname(); err == nil && strings.TrimSpace(h) != "" {
		f.Host = strings.TrimSpace(h)
	}
	readOS(&f) // per platform: machine_<goos>.go
	return f
}

// gb is total bytes as whole GB (rounded), or "unknown" for 0.
func gb(bytes uint64) string {
	if bytes == 0 {
		return Unknown
	}
	return strconv.FormatUint((bytes+(1<<29))>>30, 10)
}

// Line is the one-line form for evidence headers and the terminal: no hostname (t-a83a), ASCII separators (evidence.sh
// check shows a non-ASCII byte as ?). "macOS 26.1, Darwin 25.1.0, arm64, 10 cores, 32 GB"
func (f Facts) Line() string {
	name := f.OSName
	if f.OSVersion != Unknown && !strings.Contains(name, f.OSVersion) {
		name += " " + f.OSVersion
	}
	parts := []string{name}
	if f.OSVersion == Unknown || !strings.HasSuffix(f.Kernel, f.OSVersion) { // Windows: "NT 10.0.26100" repeats the version
		parts = append(parts, f.Kernel)
	}
	parts = append(parts, f.Arch, f.CPUs+" cores", f.RAMGB+" GB")
	return strings.Join(parts, ", ")
}

// osRelease reads PRETTY_NAME and VERSION_ID from /etc/os-release text (Linux). Pure, so it is tested on every OS.
func osRelease(text string) (name, version string) {
	for _, l := range strings.Split(text, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(l), "=")
		if !ok {
			continue
		}
		v = strings.Trim(v, `"'`)
		switch k {
		case "PRETTY_NAME":
			name = v
		case "VERSION_ID":
			version = v
		}
	}
	return name, version
}

// windowsName names a Windows release from RtlGetVersion's numbers: build 22000 and up is Windows 11 (it still reports 10.0).
func windowsName(major, minor, build uint32) string {
	switch {
	case major == 10 && build >= 22000:
		return "Windows 11"
	case major == 10:
		return "Windows 10"
	default:
		return fmt.Sprintf("Windows %d.%d", major, minor)
	}
}
