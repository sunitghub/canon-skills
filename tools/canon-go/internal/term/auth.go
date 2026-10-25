package term

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
)

// ErrNoAuth means this machine has no OS password prompt su can use; su is then unavailable (there is no typed-word
// fallback: without the account password there is no admin shell).
var ErrNoAuth = errors.New("no OS authentication available")

// authCommand is the OS's own password prompt for the signed-in account, one that asks for the password whatever sudo is
// set to (sudo -v passes silently for a NOPASSWD user, so it is not used): macOS checks it against Open Directory with
// dscl -authonly, Linux with su to the same account, which asks PAM for that account's password. canon never sees the
// password. Windows has no console password check that fits: its sudo (11 24H2+, off until switched on in Settings) asks
// for UAC consent, and has no -v, so a command that exits at once makes it ask. ok is false when no provider applies.
func authCommand(goos, account string, lookPath func(string) (string, error), sudoOn func() bool) (name string, args []string, ok bool) {
	switch goos {
	case "darwin":
		p, err := lookPath("dscl")
		if err != nil || account == "" {
			return "", nil, false
		}
		return p, []string{".", "-authonly", account}, true
	case "linux":
		p, err := lookPath("su")
		if err != nil || account == "" {
			return "", nil, false
		}
		return p, []string{"-c", "true", account}, true
	case "windows":
		p, err := lookPath("sudo")
		if err != nil || !sudoOn() {
			return "", nil, false
		}
		return p, []string{"cmd", "/c", "exit"}, true
	}
	return "", nil, false
}

// windowsSudoOn reads Windows' own switch for sudo (HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo, Enabled: 0
// off, 1-3 on in one of its three modes). Anything unreadable counts as off, so doubt means su is unavailable.
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

// osAuth is what Main wires.
var osAuth = OSAuth

// OSAuth asks the OS for the signed-in account's password. It returns ErrNoAuth when there is no provider, nil when the
// user passed.
func OSAuth(ctx context.Context, out io.Writer) error {
	account := ""
	if u, err := user.Current(); err == nil {
		account = u.Username
	}
	if account == "" {
		account = os.Getenv("USER")
	}
	name, args, ok := authCommand(goos, account, exec.LookPath, windowsSudoOn)
	if !ok {
		return ErrNoAuth
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, out, out
	return cmd.Run()
}
