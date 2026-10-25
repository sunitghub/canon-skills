package term

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
)

// ErrNoAuth means this machine has no OS credential prompt su can use; su then falls back to the typed word.
var ErrNoAuth = errors.New("no OS authentication available")

// authCommand is the OS's own password prompt: sudo asks for the user's login password through PAM (Linux), Open
// Directory (macOS) or UAC (Windows sudo), so canon never sees it. -k drops a cached sudo ticket, so the prompt always
// appears. Windows sudo has no -v; running a command that exits at once makes it ask. ok is false when none applies.
func authCommand(goos string, lookPath func(string) (string, error)) (name string, args []string, ok bool) {
	sudo, err := lookPath("sudo")
	if err != nil {
		return "", nil, false
	}
	if goos == "windows" {
		return sudo, []string{"cmd", "/c", "exit"}, true
	}
	return sudo, []string{"-k", "-v"}, true
}

// osAuth is what Main wires; the end-to-end test child sets it nil to exercise the typed-word fallback on a real pty.
var osAuth = OSAuth

// OSAuth asks the OS for the user's password. It returns ErrNoAuth when there is no provider, nil when the user passed.
func OSAuth(ctx context.Context, out io.Writer) error {
	name, args, ok := authCommand(goos, exec.LookPath)
	if !ok {
		return ErrNoAuth
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, out, out
	return cmd.Run()
}
