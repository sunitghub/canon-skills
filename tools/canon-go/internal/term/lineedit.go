package term

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

const prompt = "$ "

// readLine reads one command line. On a terminal (RawMode set and working) it edits the line itself: Tab completes,
// Backspace, Ctrl-U and Ctrl-W delete, Ctrl-C drops the line, Ctrl-D on an empty line leaves, and Up and Down walk
// the history. Otherwise (a pipe, Windows) it reads a plain line. The terminal goes back to normal before the command runs.
func (c Config) readLine(rd *bufio.Reader, hist *[]string) (string, error) {
	if c.RawMode == nil {
		return rd.ReadString('\n')
	}
	restore := c.RawMode()
	if restore == nil {
		return rd.ReadString('\n')
	}
	defer restore()
	var buf []byte
	pos, draft := len(*hist), ""
	redraw := func() { fmt.Fprint(c.Out, "\r\x1b[K"+prompt+string(buf)) }
	for {
		b, err := rd.ReadByte()
		if err != nil {
			return string(buf), err
		}
		switch {
		case b == '\r' || b == '\n':
			fmt.Fprint(c.Out, "\r\n")
			return string(buf) + "\n", nil
		case b == 0x03:
			fmt.Fprint(c.Out, "^C\r\n")
			return "\n", nil
		case b == 0x04:
			if len(buf) == 0 {
				fmt.Fprint(c.Out, "\r\n")
				return "", io.EOF
			}
		case b == 0x7f || b == 0x08:
			if len(buf) > 0 {
				_, n := utf8.DecodeLastRune(buf)
				buf = buf[:len(buf)-n]
				redraw()
			}
		case b == 0x15:
			buf = buf[:0]
			redraw()
		case b == 0x17:
			s := strings.TrimRight(string(buf), " ")
			buf = []byte(s[:strings.LastIndex(s, " ")+1])
			redraw()
		case b == '\t':
			next, cands := c.complete(string(buf))
			switch {
			case next != string(buf):
				buf = []byte(next)
				redraw()
			case len(cands) > 1:
				fmt.Fprint(c.Out, "\r\n"+strings.Join(cands, "  ")+"\r\n")
				redraw()
			}
		case b == 0x1b:
			up, down := readEscape(rd)
			switch {
			case up && pos > 0:
				if pos == len(*hist) {
					draft = string(buf)
				}
				pos--
				buf = []byte((*hist)[pos])
				redraw()
			case down && pos < len(*hist):
				pos++
				if pos == len(*hist) {
					buf = []byte(draft)
				} else {
					buf = []byte((*hist)[pos])
				}
				redraw()
			}
		case b >= 0x20 && b != 0x7f:
			buf = append(buf, b)
			if b < 0x80 {
				fmt.Fprint(c.Out, string(rune(b)))
			} else {
				c.Out.Write([]byte{b})
			}
		}
	}
}

// readEscape consumes the rest of an escape sequence (arrow keys and the like) and says whether it was Up or Down.
func readEscape(rd *bufio.Reader) (up, down bool) {
	b, err := rd.ReadByte()
	if err != nil || (b != '[' && b != 'O') {
		return
	}
	for {
		b, err = rd.ReadByte()
		if err != nil {
			return
		}
		if b >= 0x40 && b <= 0x7e {
			return b == 'A', b == 'B'
		}
	}
}

var commandNames = []string{"cat", "clear", "cls", "exit", "help", "ls", "su", "tkt"}

// complete finishes the last word of line the way a shell does: the command, a read-only tkt subcommand, or a path for
// ls and cat inside the project (never .git or .env*, never outside it). It returns the line with the word completed as
// far as it is unambiguous, and the matches when more than one remains.
func (c Config) complete(line string) (string, []string) {
	words := strings.Fields(line)
	trailing := line == "" || strings.HasSuffix(line, " ")
	cur, n := "", len(words)
	if !trailing {
		cur, n = words[len(words)-1], len(words)-1
	}
	base := line[:len(line)-len(cur)]
	var toks, shown []string // full replacement words, and how each is listed
	switch {
	case n == 0:
		for _, k := range commandNames {
			if strings.HasPrefix(k, cur) {
				toks, shown = append(toks, k), append(shown, k)
			}
		}
	case words[0] == "tkt" && n == 1:
		for _, k := range ReadOnlyTkt() {
			if strings.HasPrefix(k, cur) {
				toks, shown = append(toks, k), append(shown, k)
			}
		}
	case words[0] == "ls" || words[0] == "cat":
		toks, shown = c.completePath(cur)
	}
	switch len(toks) {
	case 0:
		return line, nil
	case 1:
		if !strings.HasSuffix(toks[0], "/") {
			return base + toks[0] + " ", nil
		}
		return base + toks[0], nil
	}
	p := toks[0]
	for _, t := range toks[1:] {
		for !strings.HasPrefix(t, p) {
			p = p[:len(p)-1]
		}
	}
	return base + p, shown
}

// completePath lists the project entries that start with cur. Anything confine would refuse, any name that could not be
// typed at this prompt, and dotfiles unless cur asks for them are left out.
func (c Config) completePath(cur string) (toks, shown []string) {
	dir, part := "", cur
	if i := strings.LastIndex(cur, "/"); i >= 0 {
		dir, part = cur[:i+1], cur[i+1:]
	}
	arg := dir
	if arg == "" {
		arg = "."
	}
	real, err := confine(c.Root, arg)
	if err != nil {
		return
	}
	ents, err := os.ReadDir(real)
	if err != nil {
		return
	}
	for _, e := range ents {
		name := e.Name()
		if !strings.HasPrefix(name, part) || (strings.HasPrefix(name, ".") && !strings.HasPrefix(part, ".")) {
			continue
		}
		if name != Visible(name) || strings.ContainsAny(name, shellChars+" \t") {
			continue
		}
		if _, err := confine(c.Root, dir+name); err != nil {
			continue
		}
		if st, err := os.Stat(filepath.Join(real, name)); err == nil && st.IsDir() {
			name += "/"
		}
		toks, shown = append(toks, dir+name), append(shown, name)
	}
	sort.Strings(toks)
	sort.Strings(shown)
	return
}
