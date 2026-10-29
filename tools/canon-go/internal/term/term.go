// Package term is the restricted prompt behind the board's Terminal button (t-57ab). The cockpit daemon runs it as
// `canon-go daemon term` in a pty. It is a convenience boundary, not a sandbox: it reads files inside the project, runs
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
	"math"
	"os"
	"os/exec"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"canon/internal/settings"
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
	// RunOnTerminal runs one program as the foreground of the user's real terminal (tkt send-issue --launch needs one for
	// claude --cloud); nil: not available here (Windows has no runner yet, t-57ab).
	RunOnTerminal func(ctx context.Context, path string, args []string, dir string) error
	// Auth asks the OS for the account password; nil, or ErrNoAuth, means su is unavailable.
	Auth    func(ctx context.Context, out io.Writer) error
	Limit   time.Duration  // how long su lasts
	Warn    time.Duration  // how long before the end it warns
	Rows    func() int     // the terminal's height, for paging cat; nil or 0 means 24
	RawMode func() func()  // switches the terminal to key-by-key input for the prompt line (Tab completion); returns the undo, or nil when In is not a terminal
	st      *suState       // what su remembers between commands (set by Run)
	intr    chan os.Signal // SIGINTs caught while a command ran (set by Run): a command that was interrupted shows nothing more

	// Paging is terminal.paging (t-dba0): "auto" (the screen's height; "" means the same), "off" (never pause) or a number of lines.
	// The paging command changes it for this Terminal only.
	Paging string
	pg     *string // the live value (set by Run from Paging)
}

// readOnlyTkt are the tkt subcommands that only read. runTkt are the ones that change a ticket or post to GitHub, which the board
// already offers as buttons behind a confirmation: they run here without su, each audited (terminal.tkt, the subcommand name only).
// Everything else, including any command added to tkt later and merge-pr (it runs the PR's code here), needs su.
var (
	readOnlyTkt = map[string]bool{"current": true, "ls": true, "show": true, "why": true, "github-doctor": true, "github-status": true}
	runTkt      = map[string]bool{"create": true, "start": true, "demo": true, "close": true, "reopen": true, "archive": true, "send-issue": true, "import-issue": true, "open-pr": true, "import-results": true}
)

// suFlags are refused on every tkt subcommand without su: --test runs any command and --body-file reads any file.
var suFlags = []string{"--test", "--body-file"}

func suFlag(args []string) string {
	for _, a := range args {
		for _, f := range suFlags {
			if a == f || strings.HasPrefix(a, f+"=") {
				return f
			}
		}
	}
	return ""
}

// RunTkt lists the subcommands that run without su and change things, sorted.
func RunTkt() []string {
	out := make([]string, 0, len(runTkt))
	for k := range runTkt {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

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
	{"help", "show this list (a lone ? does too)", false},
	{"clear", "clear the screen (cls does too)", false},
	{"pwd", "show the project folder this prompt is in", false},
	{"ls [path]", "list files with sizes and dates", false},
	{"cat <file>", "show a file a page at a time, with colours for code", false},
	{"paging [auto|off|<lines>]", "show or set when output pauses (this one only)", false},
	{"tkt current", "show the active ticket", false},
	{"tkt ls [--status=X]", "list tickets", false},
	{"tkt show <id>", "show one ticket", false},
	{"tkt why <file>", "which tickets touched a file", false},
	{"tkt github-status <id>", "where a ticket stands on GitHub", false},
	{"tkt github-doctor", "check that GitHub is ready (gh, origin)", false},
	{"tkt --help", "every tkt command, including the rarely needed ones", false},
	{"tkt create [title] -d <desc> -p <0-4>", "create a ticket and print its id", false},
	{"tkt start <id>", "set it in progress and mark it ACTIVE", false},
	{"tkt demo <id> [on|off]", "mark a ticket for the light (demo) close", false},
	{"tkt close <id>", "close a ticket", false},
	{"tkt reopen <id>", "open a closed ticket again", false},
	{"tkt archive <id>", "hide a ticket from the board columns", false},
	{"tkt send-issue <id> [--dry-run] [--launch]", "post it as a GitHub issue (--launch: cloud session)", false},
	{"tkt import-issue <issue number>", "rebuild a ticket from a send-issue issue", false},
	{"tkt open-pr <id>", "open the PR a cloud session did not", false},
	{"tkt import-results <id>", "bring a cloud session's results back", false},
	{"su", "a full shell for 10 min (OS approval; 3 fails close)", false},
	{"exit", "leave", false},
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
	b.WriteString("\nNeeds su (type su first, then the OS approval)\n")
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
	if cfg.pg == nil {
		p := cfg.Paging
		cfg.pg = &p
	}
	rd := bufio.NewReader(cfg.In)
	fmt.Fprint(cfg.Out, welcome())
	// A Ctrl-C while a command runs is a SIGINT to this whole foreground group. Catching it keeps the prompt alive while the
	// command (which gets the default action on exec) stops; ignoring it would be inherited by tkt and leave it unstoppable.
	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, os.Interrupt)
	defer signal.Stop(sigc)
	cfg.intr = sigc
	var hist []string
	for {
		fmt.Fprint(cfg.Out, "$ ")
		line, err := cfg.readLine(rd, &hist)
		line = strings.TrimSpace(line)
		if line != "" {
			hist = append(hist, line)
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
	if line == "?" { // the one place a ? is not a glob
		fmt.Fprint(c.Out, welcome())
		return false
	}
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
	case "pwd":
		fmt.Fprintln(c.Out, Visible(c.Root))
	case "clear", "cls":
		fmt.Fprint(c.Out, "\x1b[H\x1b[2J\x1b[3J")
	case "ls":
		c.ls(f[1:], rd)
	case "cat":
		c.cat(f[1:], rd)
	case "tkt":
		c.tkt(f[1:], rd)
	case "paging":
		c.paging(f[1:])
	case "su":
		return c.su(rd)
	default:
		fmt.Fprintf(c.Out, "not allowed here: %s   allowed: help, ls, cat, pwd, paging, tkt, su, clear, exit\n", Visible(f[0]))
	}
	return false
}

// ls always prints the long form (mode, size, date, name); -l and -a are accepted because every entry is listed anyway.
func (c Config) ls(args []string, rd *bufio.Reader) {
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
	c.page(strings.Join(lines, "\n"), rd) // os.ReadDir already sorted them by name
}

// longLine is one ls -l row without owner or link count: mode, size, modified time, name.
func longLine(fi os.FileInfo, name string) string {
	return fmt.Sprintf("%s %7s %s  %s", fi.Mode().String(), humanSize(fi.Size()), fi.ModTime().Format("Jan _2 15:04"), colorName(fi.Mode(), Visible(name)))
}

// colorName paints a name the way GNU ls does by default: folders bold blue, links cyan, executables green, the rest plain.
// name is already Visible, so it carries no escape of its own.
func colorName(m os.FileMode, name string) string {
	code := ""
	switch {
	case m.IsDir():
		code = "1;34"
	case m&os.ModeSymlink != 0:
		code = "36"
	case m.IsRegular() && m&0o111 != 0:
		code = "32"
	}
	if code == "" {
		return name
	}
	return "\x1b[" + code + "m" + name + "\x1b[0m"
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

func (c Config) tkt(args []string, rd *bufio.Reader) {
	if len(args) == 0 {
		fmt.Fprintln(c.Out, "usage: tkt <command>   read-only here: "+strings.Join(ReadOnlyTkt(), ", "))
		return
	}
	if !readOnlyTkt[args[0]] && !runTkt[args[0]] && args[0] != "--help" {
		fmt.Fprintf(c.Out, "not allowed here: tkt %s   (it can change things: type su first)\n", args[0])
		return
	}
	if f := suFlag(args); f != "" {
		fmt.Fprintf(c.Out, "not allowed here: tkt %s %s   (it can run a command or read any file: type su first)\n", args[0], f)
		return
	}
	if runTkt[args[0]] {
		// Fail closed, as su_granted: a command nobody can see in the log is not run. The name only: arguments are issue text, titles, paths.
		if err := c.emitErr("terminal.tkt", map[string]string{"sub": args[0]}); err != nil {
			fmt.Fprintln(c.Out, "tkt refused: the audit log cannot be written, so nothing was run.")
			return
		}
	}
	bin := c.Tkt
	if bin == "" {
		bin = "tkt"
	}
	if args[0] == "send-issue" && hasArg(args, "--launch") {
		c.launch(bin, args)
		return
	}
	cmd := exec.Command(bin, args...)
	cmd.Dir = c.Root
	// tkt prints ticket text, which can come from an imported issue: show it the way cat shows a file, line by line.
	select { // forget a Ctrl-C from before this command
	case <-c.intr:
	default:
	}
	// A slow, long listing (tkt ls takes seconds) pages as it streams: when a page is full the writer waits for a key, so tkt
	// itself waits on its pipe, and q stops it.
	pw := &pageWriter{c: c, rd: rd, size: c.pageSize()}
	vw := &visibleWriter{w: pw}
	cmd.Stdout, cmd.Stderr = vw, vw
	pw.cmd = cmd
	err := cmd.Run()
	vw.flush()
	select {
	case <-c.intr:
		fmt.Fprintln(c.Out, "^C")
		return
	default:
	}
	if err != nil {
		if _, ok := err.(*exec.ExitError); !ok {
			fmt.Fprintf(c.Out, "tkt: %v\n", err)
		}
	}
}

func hasArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

// launch runs tkt send-issue --launch on the user's own terminal, not through the pager's pipe: claude --cloud refuses to
// start unless stdin and stdout are a terminal.
func (c Config) launch(bin string, args []string) {
	if c.RunOnTerminal == nil {
		fmt.Fprintln(c.Out, "tkt send-issue --launch needs a full terminal, which this Terminal cannot give on Windows yet.\nPaste the same line in PowerShell or Git Bash in the project folder instead.")
		return
	}
	path, err := exec.LookPath(bin)
	if err != nil {
		fmt.Fprintf(c.Out, "tkt: %v\n", err)
		return
	}
	select { // forget a Ctrl-C from before this command
	case <-c.intr:
	default:
	}
	if err := c.RunOnTerminal(context.Background(), path, args, c.Root); err != nil {
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
	size := c.pageSize()
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
		fmt.Fprintf(c.Out, "\x1b[0m-- more: Enter or space for the next page, q or Ctrl-C to stop (%d lines left) -- ", len(lines))
		if c.pageKey(rd) {
			return
		}
	}
}

// paging shows the setting, or changes it for this Terminal only (nothing is saved: the Paging control on the rail does that).
func (c Config) paging(args []string) {
	cur := c.pagingValue()
	if len(args) == 0 {
		fmt.Fprintf(c.Out, "paging: %s   (paging auto|off|<%d-%d lines> changes it for this Terminal; the rail's Paging control saves it)\n", cur, settings.MinPaging, settings.MaxPaging)
		return
	}
	if len(args) > 1 {
		fmt.Fprintln(c.Out, "usage: paging [auto|off|<lines>]")
		return
	}
	a := args[0]
	if a == "on" {
		a = "auto"
	}
	v := any(a)
	if n, err := strconv.Atoi(a); err == nil {
		v = n
	}
	norm, err := settings.ProjectSet("").Schema["terminal.paging"].Validate(v)
	if err != nil {
		fmt.Fprintf(c.Out, "paging: %q is not a setting. usage: paging [auto|off|<lines>]   (lines %d to %d; on means auto)\n", a, settings.MinPaging, settings.MaxPaging)
		return
	}
	*c.pg = fmt.Sprint(norm)
	fmt.Fprintf(c.Out, "paging: %s (this Terminal only)\n", *c.pg)
}

// pagingValue is the live setting: "auto", "off" or a number of lines as text.
func (c Config) pagingValue() string {
	p := c.Paging
	if c.pg != nil {
		p = *c.pg
	}
	if p == "" {
		return "auto"
	}
	return p
}

// pageSize is how many lines fit a screen: the terminal's height less the prompt line, never under 5. terminal.paging off means
// never pause (a size no text reaches); a number means that many lines.
func (c Config) pageSize() int {
	switch p := c.pagingValue(); p {
	case "auto":
	case "off":
		return math.MaxInt32
	default:
		if n, err := strconv.Atoi(p); err == nil && n >= settings.MinPaging && n <= settings.MaxPaging {
			return n
		}
	}
	rows := 24
	if c.Rows != nil {
		if r := c.Rows(); r > 0 {
			rows = r
		}
	}
	if rows-1 < 5 {
		return 5
	}
	return rows - 1
}

// pageWriter prints whole lines and, once a page is full, asks for a key before the next line. A stop key ends the
// command it is paging and drops what is still to come.
type pageWriter struct {
	c       Config
	rd      *bufio.Reader
	cmd     *exec.Cmd
	size, n int
	stopped bool
}

func (p *pageWriter) Write(b []byte) (int, error) {
	if p.stopped {
		return len(b), nil
	}
	for _, line := range strings.SplitAfter(string(b), "\n") {
		if line == "" {
			continue
		}
		if p.n >= p.size {
			fmt.Fprint(p.c.Out, "\x1b[0m-- more: Enter or space for the next page, q or Ctrl-C to stop -- ")
			if p.c.pageKey(p.rd) {
				p.stopped = true
				if p.cmd != nil && p.cmd.Process != nil {
					_ = p.cmd.Process.Kill()
				}
				return len(b), nil
			}
			p.n = 0
		}
		fmt.Fprint(p.c.Out, line)
		p.n++
	}
	return len(b), nil
}

// pageKey waits at the "more" prompt and says whether to stop. On a terminal it takes one key (Enter or space goes on;
// q, Ctrl-C or Ctrl-D stop) and wipes the prompt; otherwise it reads a line and stops on q.
func (c Config) pageKey(rd *bufio.Reader) bool {
	if c.RawMode != nil {
		if restore := c.RawMode(); restore != nil {
			defer restore()
			for {
				b, err := rd.ReadByte()
				if err != nil {
					fmt.Fprint(c.Out, "\r\x1b[K")
					return true
				}
				switch b {
				case '\r', '\n', ' ':
					fmt.Fprint(c.Out, "\r\x1b[K")
					return false
				case 'q', 'Q', 0x03, 0x04:
					fmt.Fprint(c.Out, "\r\x1b[K")
					return true
				case 0x1b:
					readEscape(rd)
				}
			}
		}
	}
	ans, err := rd.ReadString('\n')
	if err != nil || strings.EqualFold(strings.TrimSpace(ans), "q") {
		fmt.Fprintln(c.Out)
		return true
	}
	return false
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
