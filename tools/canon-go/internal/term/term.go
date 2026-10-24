// Package term is the restricted prompt behind the board's Terminal button (t-57ab). The cockpit daemon runs it as
// `cockpit-daemon term` in a pty. It is a convenience boundary, not a sandbox: it reads files inside the project, runs
// read-only tkt commands, and gives a full shell only after `su` (see su.go).
//
// There is no shell here: each command is an argument list, and a line with a shell metacharacter is refused rather
// than interpreted. Anything not listed is refused by name, so a new command is never allowed by accident.
package term

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// Config is everything Run needs; tests replace the shell, the clock and the event writer.
type Config struct {
	Root                     string // project root; ls and cat never leave it
	In                       io.Reader
	Out                      io.Writer
	Session, Ticket, Project string
	Tkt                      string // the tkt binary; "" looks it up on PATH
	// Emit writes one audit event (kind, data); the session and ticket fields are added by the caller of Emit.
	Emit func(kind string, data map[string]string) error
	// RunShell runs the full shell until it exits or ctx ends (then it must stop the whole process group). nil: su is unavailable.
	RunShell func(ctx context.Context, root string) error
	After    func(time.Duration) <-chan time.Time
	Word     func() string
	Limit    time.Duration // how long su lasts
	Warn     time.Duration // how long before the end it warns
}

// readOnlyTkt is the whole list of tkt subcommands the restricted prompt runs. Everything else, including any command
// added to tkt later, needs su.
var readOnlyTkt = map[string]bool{"current": true, "ls": true, "show": true, "why": true, "github-doctor": true, "github-status": true}

// ReadOnlyTkt lists the allowed tkt subcommands, sorted (tests compare it with `tkt --help`).
func ReadOnlyTkt() []string {
	out := make([]string, 0, len(readOnlyTkt))
	for k := range readOnlyTkt {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

const shellChars = "|&;<>$`(){}*?[]\\'\""

const banner = "canon terminal · restricted · allowed: help, ls, cat, tkt (read-only), su, exit"

const helpText = `ls [path]        list a folder inside this project
cat <file>...    show files, with colours for code
tkt <command>    read-only: current, ls, show, why, github-doctor, github-status
su               a full shell for 5 minutes (asks you to type a word)
exit             leave`

// Run is the prompt loop; it returns the exit status.
func Run(cfg Config) int {
	if cfg.After == nil {
		cfg.After = time.After
	}
	rd := bufio.NewReader(cfg.In)
	fmt.Fprintln(cfg.Out, banner)
	for {
		fmt.Fprint(cfg.Out, "$ ")
		line, err := rd.ReadString('\n')
		line = strings.TrimSpace(line)
		if line != "" {
			if cfg.dispatch(line, rd) {
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
		fmt.Fprintln(c.Out, helpText)
	case "ls":
		c.ls(f[1:])
	case "cat":
		c.cat(f[1:])
	case "tkt":
		c.tkt(f[1:])
	case "su":
		c.su(rd)
	default:
		fmt.Fprintf(c.Out, "not allowed here: %s   allowed: help, ls, cat, tkt, su, exit\n", f[0])
	}
	return false
}

func (c Config) ls(args []string) {
	if len(args) > 1 || (len(args) == 1 && strings.HasPrefix(args[0], "-")) {
		fmt.Fprintln(c.Out, "usage: ls [path]   (no options here)")
		return
	}
	arg := "."
	if len(args) == 1 {
		arg = args[0]
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
		fmt.Fprintln(c.Out, fi.Name())
		return
	}
	ents, err := os.ReadDir(real)
	if err != nil {
		fmt.Fprintf(c.Out, "ls: %v\n", cleanErr(err))
		return
	}
	names := make([]string, 0, len(ents))
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() {
			n += "/"
		}
		names = append(names, Visible(n))
	}
	sort.Strings(names)
	fmt.Fprintln(c.Out, strings.Join(names, "  "))
}

func (c Config) cat(args []string) {
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
		fmt.Fprint(c.Out, Highlight(name, Visible(src)))
		if !strings.HasSuffix(src, "\n") {
			fmt.Fprintln(c.Out)
		}
	}
}

func (c Config) tkt(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(c.Out, "usage: tkt <command>   read-only here: "+strings.Join(ReadOnlyTkt(), ", "))
		return
	}
	if !readOnlyTkt[args[0]] {
		fmt.Fprintf(c.Out, "not allowed here: tkt %s   (it can change things: type su first)\n", args[0])
		return
	}
	bin := c.Tkt
	if bin == "" {
		bin = "tkt"
	}
	cmd := exec.Command(bin, args...)
	cmd.Dir = c.Root
	cmd.Stdout, cmd.Stderr = c.Out, c.Out
	if err := cmd.Run(); err != nil {
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
