package term

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// ErrNoAuth means this machine has no OS credential prompt su can use; su then falls back to the typed word.
var ErrNoAuth = errors.New("no OS authentication available")

// authCommand is the OS's own prompt: sudo asks for the user's login password through PAM (Linux) or Open Directory
// (macOS), so canon never sees it. -k drops a cached sudo ticket, so the prompt always appears. Windows sudo (11 24H2+,
// off until switched on in Settings) asks for UAC consent, not a password, and has no -v: running a command that exits
// at once makes it ask. A sudo.exe that ships but is switched off would only fail, so Windows needs sudoOn to say it is
// on. ok is false when no provider applies; su then asks for the typed word.
func authCommand(goos string, lookPath func(string) (string, error), sudoOn func() bool) (name string, args []string, ok bool) {
	sudo, err := lookPath("sudo")
	if err != nil {
		return "", nil, false
	}
	if goos == "windows" {
		if !sudoOn() {
			return "", nil, false
		}
		return sudo, []string{"cmd", "/c", "exit"}, true
	}
	return sudo, []string{"-k", "-v"}, true
}

// windowsSudoOn reads Windows' own switch for sudo (HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo, Enabled: 0
// off, 1-3 on in one of its three modes). Anything unreadable counts as off, so doubt falls back to the typed word.
func windowsSudoOn() bool {
	out, err := exec.Command("reg", "query", `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo`, "/v", "Enabled").Output()
	return err == nil && sudoEnabledIn(string(out))
}

// sudoEnabledIn reads `reg query ... /v Enabled` output: its last field is the DWORD, 0x0 off, 0x1-0x3 on.
func sudoEnabledIn(out string) bool {
	f := strings.Fields(out)
	if len(f) == 0 {
		return false
	}
	v, err := strconv.ParseUint(strings.TrimPrefix(f[len(f)-1], "0x"), 16, 32)
	return err == nil && v >= 1 && v <= 3
}

// osAuth is what Main wires; the end-to-end test child sets it nil to exercise the typed-word fallback on a real pty.
var osAuth = OSAuth

// OSAuth asks the OS for the user's password. It returns ErrNoAuth when there is no provider, nil when the user passed.
func OSAuth(ctx context.Context, out io.Writer) error {
	name, args, ok := authCommand(goos, exec.LookPath, windowsSudoOn)
	if !ok {
		return ErrNoAuth
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, out, out
	return cmd.Run()
}
