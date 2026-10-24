package term

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"fmt"
	"strings"
	"time"
)

// Defaults for su: five minutes, with a warning half a minute before the end.
const (
	DefaultLimit = 5 * time.Minute
	DefaultWarn  = 30 * time.Second
)

// su asks for a random word and, only when it is typed back, runs the full shell for Limit. The typed word stops a pasted
// or scripted "su" from confirming itself: the word is unknown until it is printed. The timer lives here, in the same
// process as the prompt, so there is no token to steal.
func (c Config) su(rd *bufio.Reader) {
	if c.RunShell == nil {
		fmt.Fprintln(c.Out, "su is not available here yet")
		return
	}
	limit, warn := c.Limit, c.Warn
	if limit <= 0 {
		limit = DefaultLimit
	}
	if warn <= 0 || warn >= limit {
		warn = DefaultWarn
	}
	word := c.Word()
	c.emit("terminal.su_prompted", nil)
	fmt.Fprintf(c.Out, "Full shell mode lasts %s, then you drop back to this prompt.\nNothing you run there is restricted. This is logged.\nType %s to continue (Enter cancels): ", limit, word)
	ans, err := rd.ReadString('\n')
	ans = strings.TrimSpace(ans)
	reason := ""
	switch {
	case ans == "" && err != nil:
		reason = "eof"
	case ans == "":
		reason = "empty"
	case subtle.ConstantTimeCompare([]byte(ans), []byte(word)) != 1:
		reason = "wrong"
	}
	if reason != "" {
		c.emit("terminal.su_denied", map[string]string{"reason": reason})
		fmt.Fprintln(c.Out, "Cancelled: still in the restricted prompt.")
		return
	}
	// Fail closed: a grant nobody can see is not granted.
	if err := c.emitErr("terminal.su_granted", map[string]string{"minutes": fmt.Sprint(int(limit / time.Minute))}); err != nil {
		fmt.Fprintln(c.Out, "su refused: the audit log cannot be written, so nothing was started.")
		return
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
			return
		case <-done:
			c.emit("terminal.su_expired", map[string]string{"how": "exited"})
			fmt.Fprintln(c.Out, "Back in the restricted prompt.")
			return
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

const wordAlphabet = "abcdefghjkmnpqrstuvwxyz23456789" // no look-alikes

// RandomWord is the word su asks for: two groups of four characters, about 39 bits.
func RandomWord() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic(err) // no randomness, no su: a panic ends the prompt, which is the safe outcome
	}
	out := make([]byte, 0, 9)
	for i, x := range b {
		if i == 4 {
			out = append(out, '-')
		}
		out = append(out, wordAlphabet[int(x)%len(wordAlphabet)])
	}
	return string(out)
}
