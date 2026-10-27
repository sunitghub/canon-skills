package term

import (
	"flag"
	"fmt"
	"io"
	"os"

	"canon/internal/events"
	"canon/internal/settings"
)

// Main runs the restricted prompt for the daemon: `cockpit-daemon term --session <id> --ticket <id> --project <root>`.
// It works in the current directory, which the daemon set to the session's checkout.
func Main(args []string) int {
	fs := flag.NewFlagSet("term", flag.ContinueOnError)
	session := fs.String("session", "", "session id (events)")
	ticket := fs.String("ticket", "", "scratch id (events)")
	project := fs.String("project", "", "project root (events)")
	limit := fs.Duration("limit", DefaultLimit, "how long su lasts (can only be shortened)")
	warn := fs.Duration("warn", DefaultWarn, "how long before the end su warns")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *limit <= 0 || *limit > DefaultLimit {
		*limit = DefaultLimit
	}
	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, "term:", err)
		return 1
	}
	if *project == "" {
		*project = root
	}
	home := events.Home()
	cfg := Config{
		Paging: projectPaging(*project, os.Stderr),
		Root:   root, In: os.Stdin, Out: os.Stdout,
		Session: *session, Ticket: *ticket,
		Emit: func(kind string, data map[string]string) error {
			return events.Emit(home, kind, "daemon", *project, data)
		},
		RunShell:      RealShell,
		RunOnTerminal: RunOnTerminal,
		Auth:          osAuth,
		Limit:         *limit,
		Warn:          *warn,
		Rows:          terminalRows,
		RawMode:       func() func() { return rawMode(int(os.Stdin.Fd())) },
	}
	return Run(cfg)
}

// projectPaging is terminal.paging from the project's own settings files (t-dba0): "auto", "off" or a number of lines. A malformed
// file is said on errOut and the default is used, so a broken file never stops the Terminal.
func projectPaging(project string, errOut io.Writer) string {
	res, err := settings.ProjectSet(project).Load()
	if err != nil {
		fmt.Fprintf(errOut, "term: %v (using the default paging)\n", err)
		return "auto"
	}
	return fmt.Sprint(res.Values["terminal.paging"].V)
}
