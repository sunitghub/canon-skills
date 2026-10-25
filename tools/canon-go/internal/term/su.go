package term

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Defaults for su: ten minutes, with a warning half a minute before the end.
const (
	DefaultLimit = 10 * time.Minute
	DefaultWarn  = 30 * time.Second
)

// su asks for a random word and, only when it is typed back, runs the full shell for Limit. The typed word stops a pasted
// or scripted "su" from confirming itself: the word is unknown until it is printed. The timer lives here, in the same
// process as the prompt, so there is no token to steal.
func (c Config) su(rd *bufio.Reader) (closeTerminal bool) {
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
	if c.Auth != nil {
		fmt.Fprintf(c.Out, "Full shell mode lasts %s, then you drop back to this prompt.\nNothing you run there is restricted. This is logged.\nEnter your account password to continue (Ctrl+C cancels):\n", limit)
		err := c.Auth(context.Background(), c.Out)
		if err == nil {
			st.wrong = 0
			return c.grant(limit, warn)
		}
		if !errors.Is(err, ErrNoAuth) {
			// A failed or cancelled OS prompt counts like a wrong word: three in all close the terminal.
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
		fmt.Fprintln(c.Out, "This machine has no OS password prompt for su, so a typed word is used instead.")
	}
	word := c.Word()
	fmt.Fprintf(c.Out, "Full shell mode lasts %s, then you drop back to this prompt.\nNothing you run there is restricted. This is logged.\nType %s to continue (Enter cancels): ", limit, word)
	for {
		ans, err := rd.ReadString('\n')
		ans = strings.TrimSpace(ans)
		if ans == "" {
			reason := "empty"
			if err != nil {
				reason = "eof"
			}
			c.emit("terminal.su_denied", map[string]string{"reason": reason})
			fmt.Fprintln(c.Out, "Cancelled: still in the restricted prompt.")
			return false
		}
		if subtle.ConstantTimeCompare([]byte(ans), []byte(word)) == 1 {
			break
		}
		st.wrong++
		if st.wrong >= maxWrong {
			// The third wrong answer closes the terminal; the log says so.
			c.emit("terminal.su_denied", map[string]string{"reason": "locked"})
			fmt.Fprintf(c.Out, "Wrong %d times: closing the terminal. Open it again to start over.\n", maxWrong)
			st.closed = true
			return true
		}
		c.emit("terminal.su_denied", map[string]string{"reason": "wrong"})
		fmt.Fprintf(c.Out, "Wrong, %d left. Type %s again (Enter cancels): ", maxWrong-st.wrong, word)
	}
	st.wrong = 0
	return c.grant(limit, warn)
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

// Three wrong answers in all, across every su in this terminal, close the terminal: the word is short, so a blind
// guesser gets three tries, not thousands. A right answer starts the count again.
const maxWrong = 3

// suState is what the prompt remembers between su commands.
type suState struct {
	wrong  int
	closed bool // the third wrong answer ended the terminal
}

const (
	firstAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ"        // a capital first, no I or O
	wordAlphabet  = "abcdefghjkmnpqrstuvwxyz23456789" // then lower case and digits, no look-alikes
)

// RandomWord is the word su asks for: a capital letter and four more characters, about 25 bits. Enough because the
// word only has to defeat an answer given without seeing it, and wrong answers are logged and locked out.
func RandomWord() string {
	b := make([]byte, 5)
	if _, err := rand.Read(b); err != nil {
		panic(err) // no randomness, no su: a panic ends the prompt, which is the safe outcome
	}
	out := make([]byte, 5)
	out[0] = firstAlphabet[int(b[0])%len(firstAlphabet)]
	for i := 1; i < 5; i++ {
		out[i] = wordAlphabet[int(b[i])%len(wordAlphabet)]
	}
	return string(out)
}
