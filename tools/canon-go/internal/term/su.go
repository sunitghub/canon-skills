package term

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"time"
)

// Defaults for su: ten minutes, with a warning half a minute before the end.
const (
	DefaultLimit = 10 * time.Minute
	DefaultWarn  = 30 * time.Second
)

// su asks the OS for the account password and, only when it passes, runs the full shell for Limit. The OS reads the
// password from the terminal itself, so a pasted or scripted "su" cannot confirm itself and canon never sees it. With no
// OS prompt on the machine su is unavailable. The timer lives here, in the same process as the prompt, so there is no
// token to steal.
func (c Config) su(_ *bufio.Reader) (closeTerminal bool) {
	if c.RunShell == nil {
		fmt.Fprintln(c.Out, "su is not available here yet")
		return false
	}
	limit, warn := c.Limit, c.Warn
	if limit <= 0 {
		limit = DefaultLimit
	}
	if warn <= 0 || warn >= limit {
		warn = DefaultWarn
	}
	st := c.st
	if st == nil {
		st = &suState{}
	}
	c.emit("terminal.su_prompted", nil)
	if c.Auth == nil {
		c.unavailable()
		return false
	}
	fmt.Fprintf(c.Out, "Full shell mode lasts %s, then you drop back to this prompt.\nNothing you run there is restricted. This is logged.\nApprove the OS prompt to continue (your account password; UAC on Windows). Ctrl+C cancels:\n", limit)
	err := c.Auth(context.Background(), c.Out)
	if err == nil {
		st.wrong = 0
		return c.grant(limit, warn)
	}
	if errors.Is(err, ErrNoAuth) {
		c.unavailable()
		return false
	}
	// A failed or cancelled OS prompt counts: three in all, across every su, close the terminal.
	st.wrong++
	if st.wrong >= maxWrong {
		c.emit("terminal.su_denied", map[string]string{"reason": "locked"})
		fmt.Fprintf(c.Out, "Authentication failed %d times: closing the terminal. Open it again to start over.\n", maxWrong)
		st.closed = true
		return true
	}
	c.emit("terminal.su_denied", map[string]string{"reason": "auth"})
	fmt.Fprintln(c.Out, "Authentication failed: still in the restricted prompt.")
	return false
}

// unavailable: no OS password prompt here, so no admin shell. It is logged but never counts toward the three tries.
func (c Config) unavailable() {
	c.emit("terminal.su_denied", map[string]string{"reason": "unavailable"})
	fmt.Fprintln(c.Out, "su is not available here: this machine has no OS password prompt for it, and without the account password there is no full shell.")
}

// grant logs the grant and runs the full shell for limit, warning warn before the end.
func (c Config) grant(limit, warn time.Duration) (closeTerminal bool) {
	// Fail closed: a grant nobody can see is not granted.
	if err := c.emitErr("terminal.su_granted", map[string]string{"minutes": fmt.Sprint(int(limit / time.Minute))}); err != nil {
		fmt.Fprintln(c.Out, "su refused: the audit log cannot be written, so nothing was started.")
		return false
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- c.RunShell(ctx, c.Root) }()
	warnAt, endAt := c.After(limit-warn), c.After(limit)
	for {
		select {
		case <-warnAt:
			fmt.Fprintf(c.Out, "\r\n! full shell ends in %s: save your work\r\n", warn)
			warnAt = nil
		case <-endAt:
			cancel()
			<-done
			c.emit("terminal.su_expired", map[string]string{"how": "ended"})
			fmt.Fprint(c.Out, "\r\n— full shell time is up; back in the restricted prompt (type su to start again) —\r\n")
			return false
		case <-done:
			c.emit("terminal.su_expired", map[string]string{"how": "exited"})
			fmt.Fprintln(c.Out, "Back in the restricted prompt.")
			return false
		}
	}
}

func (c Config) emit(kind string, extra map[string]string) { _ = c.emitErr(kind, extra) }

func (c Config) emitErr(kind string, extra map[string]string) error {
	if c.Emit == nil {
		return nil
	}
	d := map[string]string{"session": c.Session, "ticket": c.Ticket}
	for k, v := range extra {
		d[k] = v
	}
	return c.Emit(kind, d)
}

// Three failed passwords in all, across every su in this terminal, close the terminal: a blind guesser gets three tries.
// A pass starts the count again.
const maxWrong = 3

// suState is what the prompt remembers between su commands.
type suState struct {
	wrong  int
	closed bool // the third failed password ended the terminal
}
