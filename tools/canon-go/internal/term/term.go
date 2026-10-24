// Package term is the restricted prompt behind the board's Terminal button (t-57ab). The cockpit daemon runs it as
// `cockpit-daemon term` in a pty. It is a convenience boundary, not a sandbox: it reads files inside the project, runs
// read-only tkt commands, and gives a full shell only after `su` (see su.go).
//
// There is no shell here: each command is an argument list, and a line with a shell metacharacter is refused rather
// than interpreted. Anything not listed is refused by name, so a new command is never allowed by accident.
package term

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"
)

// Config is everything Run needs; tests replace the shell, the clock and the event writer.
type Config struct {
	Root            string // project root; ls and cat never leave it
	In              io.Reader
	Out             io.Writer
	Session, Ticket string
	Tkt             string // the tkt binary; "" looks it up on PATH
	// Emit writes one audit event (kind, data); the session and ticket fields are added by the caller of Emit.
	Emit func(kind string, data map[string]string) error
	// RunShell runs the full shell until it exits or ctx ends (then it must stop the whole process group). nil: su is unavailable.
	RunShell func(ctx context.Context, root string) error
	After    func(time.Duration) <-chan time.Time
	Word     func() string
	Limit    time.Duration // how long su lasts
	Warn     time.Duration // how long before the end it warns
	Rows     func() int    // the terminal's height, for paging cat; nil or 0 means 24
	st       *suState      // what su remembers between commands (set by Run)
}

// readOnlyTkt is the whole list of tkt subcommands the restricted prompt runs. Everything else, including any command
// added to tkt later, needs su.
var readOnlyTkt = map[string]bool{"current": true, "ls": true, "show": true, "why": true, "github-doctor": true, "github-status": true}

// ReadOnlyTkt lists the allowed tkt subcommands, sorted (tests compare it with `tkt --help`).
func ReadOnlyTkt() []string {
	out := make([]string, 0, len(readOnlyTkt))
	for k, ok := range readOnlyTkt {
		if ok {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

const shellChars = "|&;<>$`(){}*?[]\\'\""

// Name is what the terminal calls itself in its welcome.
const Name = "Canon Console"

// entry is one line of the welcome. A tkt entry with su set must name a command the restricted prompt refuses; one
// without must name a command it runs (a test keeps the list and the allowlist from drifting apart).
type entry struct {
	cmd, desc string
	su        bool
}

var welcomeEntries = []entry{
	{"help", "show this list", false},
	{"ls [path]", "list files with sizes and dates", false},
	{"cat <file>", "show a file a page at a time, with colours for code", false},
	{"tkt current", "show the active ticket", false},
	{"tkt ls [--status=X]", "list tickets", false},
	{"tkt show <id>", "show one ticket", false},
	{"tkt why <file>", "which tickets touched a file", false},
	{"tkt github-status <id>", "where a ticket stands on GitHub", false},
	{"tkt github-doctor", "check that GitHub is ready (gh, origin)", false},
	{"tkt --help", "every tkt command, including the rarely needed ones", false},
	{"su", "a full shell for 10 minutes (asks for a word; 3 wrong answers close the terminal)", false},
	{"exit", "leave", false},
	{"tkt create [title] -d <desc> -p <0-4>", "create a ticket and print its id", true},
	{"tkt start <id>", "set it in progress and mark it ACTIVE", true},
	{"tkt demo <id> [on|off]", "mark a ticket for the light (demo) close", true},
	{"tkt close <id>", "close a ticket", true},
	{"tkt reopen <id>", "open a closed ticket again", true},
	{"tkt archive <id>", "hide a ticket from the board columns", true},
	{"tkt send-issue <id> [--dry-run] [--launch]", "post the ticket as a GitHub issue (--launch also starts a cloud session)", true},
	{"tkt import-issue <issue number>", "rebuild a ticket from a send-issue issue", true},
	{"tkt open-pr <id>", "open the PR a cloud session did not", true},
	{"tkt import-results <id>", "bring a cloud session's results back", true},
	{"tkt merge-pr <id>", "merge a ticket's PR after its checks", true},
}

func welcome() string {
	var b strings.Builder
	line := func(e entry) { fmt.Fprintf(&b, "  %-44s %s\n", e.cmd, e.desc) }
	fmt.Fprintf(&b, "\x1b[1mWelcome to %s\x1b[0m\nA restricted prompt for this project. There is no shell here: type one of these commands.\n\n", Name)
	b.WriteString("You can run\n")
	for _, e := range welcomeEntries {
		if !e.su {
			line(e)
		}
	}
	b.WriteString("\nNeeds su (type su first, then the word it shows)\n")
	for _, e := range welcomeEntries {
		if e.su {
			line(e)
		}
	}
	b.WriteString("\nAnything else needs su too; tkt --help lists the rest.\n")
	return b.String()
}

// Run is the prompt loop; it returns the exit status.
func Run(cfg Config) int {
	if cfg.After == nil {
		cfg.After = time.After
	}
	if cfg.st == nil {
		cfg.st = &suState{}
	}
	rd := bufio.NewReader(cfg.In)
	fmt.Fprint(cfg.Out, welcome())
	for {
		fmt.Fprint(cfg.Out, "$ ")
		line, err := rd.ReadString('\n')
		line = strings.TrimSpace(line)
		if line != "" {
			if cfg.dispatch(line, rd) {
				if cfg.st.closed {
					return 1
				}
				return 0
			}
		}
		if err != nil {
			return 0
		}
	}
}

// dispatch runs one line; it reports whether the prompt should end.
func (c Config) dispatch(line string, rd *bufio.Reader) bool {
	if i := strings.IndexAny(line, shellChars); i >= 0 {
		fmt.Fprintf(c.Out, "not supported here (no shell): %s\n", string(line[i]))
		return false
	}
	f := strings.Fields(line)
	switch f[0] {
	case "exit":
		return true
	case "help":
		fmt.Fprint(c.Out, welcome())
	case "ls":
		c.ls(f[1:])
	case "cat":
		c.cat(f[1:], rd)
	case "tkt":
		c.tkt(f[1:])
	case "su":
		return c.su(rd)
	default:
		fmt.Fprintf(c.Out, "not allowed here: %s   allowed: help, ls, cat, tkt, su, exit\n", Visible(f[0]))
	}
	return false
}

// ls always prints the long form (mode, size, date, name); -l and -a are accepted because every entry is listed anyway.
func (c Config) ls(args []string) {
	var paths []string
	for _, a := range args {
		if strings.HasPrefix(a, "-") && len(a) > 1 && strings.Trim(a[1:], "la") == "" {
			continue
		}
		paths = append(paths, a)
	}
	if len(paths) > 1 || (len(paths) == 1 && strings.HasPrefix(paths[0], "-")) {
		fmt.Fprintln(c.Out, "usage: ls [path]   (always the long form; no other options here)")
		return
	}
	arg := "."
	if len(paths) == 1 {
		arg = paths[0]
	}
	real, err := confine(c.Root, arg)
	if err != nil {
		fmt.Fprintf(c.Out, "ls: %v\n", err)
		return
	}
	fi, err := os.Stat(real)
	if err != nil {
		fmt.Fprintf(c.Out, "ls: %v\n", cleanErr(err))
		return
	}
	if !fi.IsDir() {
		fmt.Fprintln(c.Out, longLine(fi, fi.Name()))
		return
	}
	ents, err := os.ReadDir(real)
	if err != nil {
		fmt.Fprintf(c.Out, "ls: %v\n", cleanErr(err))
		return
	}
	lines := make([]string, 0, len(ents))
	for _, e := range ents {
		info, err := e.Info()
		if err != nil {
			continue
		}
		n := e.Name()
		if e.IsDir() {
			n += "/"
		}
		lines = append(lines, longLine(info, n))
	}
	for _, l := range lines { // os.ReadDir already sorts by name
		fmt.Fprintln(c.Out, l)
	}
}

// longLine is one ls -l row without owner or link count: mode, size, modified time, name.
func longLine(fi os.FileInfo, name string) string {
	return fmt.Sprintf("%s %7s %s  %s", fi.Mode().String(), humanSize(fi.Size()), fi.ModTime().Format("Jan _2 15:04"), Visible(name))
}

func humanSize(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%c", float64(n)/float64(div), "KMGT"[exp])
}

func (c Config) cat(args []string, rd *bufio.Reader) {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		fmt.Fprintln(c.Out, "usage: cat <file>...   (no options here)")
		return
	}
	for _, a := range args {
		src, name, err := readFile(c.Root, a)
		if err != nil {
			fmt.Fprintf(c.Out, "cat: %v\n", err)
			continue
		}
		src = strings.ReplaceAll(src, "\r\n", "\n") // a Windows-authored file is not shown with a symbol on every line
		c.page(Highlight(name, Visible(src)), rd)
	}
}

func (c Config) tkt(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(c.Out, "usage: tkt <command>   read-only here: "+strings.Join(ReadOnlyTkt(), ", "))
		return
	}
	if !readOnlyTkt[args[0]] && args[0] != "--help" {
		fmt.Fprintf(c.Out, "not allowed here: tkt %s   (it can change things: type su first)\n", args[0])
		return
	}
	bin := c.Tkt
	if bin == "" {
		bin = "tkt"
	}
	cmd := exec.Command(bin, args...)
	cmd.Dir = c.Root
	// tkt prints ticket text, which can come from an imported issue: show it the way cat shows a file, line by line.
	vw := &visibleWriter{w: c.Out}
	cmd.Stdout, cmd.Stderr = vw, vw
	err := cmd.Run()
	vw.flush()
	if err != nil {
		if _, ok := err.(*exec.ExitError); !ok {
			fmt.Fprintf(c.Out, "tkt: %v\n", err)
		}
	}
}

func cleanErr(err error) string {
	if os.IsNotExist(err) {
		return "no such file or directory"
	}
	if os.IsPermission(err) {
		return "permission denied"
	}
	return "cannot read"
}

// page shows text a screenful at a time: Enter for the next page, q to stop. Text that fits is shown at once.
func (c Config) page(text string, rd *bufio.Reader) {
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	rows := 24
	if c.Rows != nil {
		if r := c.Rows(); r > 0 {
			rows = r
		}
	}
	size := rows - 1
	if size < 5 {
		size = 5
	}
	for len(lines) > 0 {
		n := size
		if n > len(lines) {
			n = len(lines)
		}
		fmt.Fprintln(c.Out, strings.Join(lines[:n], "\n"))
		lines = lines[n:]
		if len(lines) == 0 {
			return
		}
		fmt.Fprintf(c.Out, "\x1b[0m-- more: Enter for the next page, q to stop (%d lines left) -- ", len(lines))
		ans, err := rd.ReadString('\n')
		if err != nil || strings.EqualFold(strings.TrimSpace(ans), "q") {
			fmt.Fprintln(c.Out)
			return
		}
	}
}

// visibleWriter passes text through Visible a whole line at a time (so a character split across two writes is not
// damaged) and keeps nothing back after flush.
type visibleWriter struct {
	w   io.Writer
	buf []byte
	mu  sync.Mutex
}

func (v *visibleWriter) Write(p []byte) (int, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.buf = append(v.buf, p...)
	for {
		i := bytes.IndexByte(v.buf, '\n')
		if i < 0 {
			break
		}
		if _, err := io.WriteString(v.w, Visible(string(v.buf[:i+1]))); err != nil {
			return 0, err
		}
		v.buf = v.buf[i+1:]
	}
	return len(p), nil
}

func (v *visibleWriter) flush() {
	v.mu.Lock()
	defer v.mu.Unlock()
	if len(v.buf) > 0 {
		_, _ = io.WriteString(v.w, Visible(string(v.buf)))
		v.buf = nil
	}
}
