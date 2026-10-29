// Command canon-go is canon's one Go program (t-bdb0): the board server and the Cockpit daemon, chosen by the first argument.
package main

import (
	"os"

	"canon/internal/board"
	"canon/internal/daemon"
)

// version and commit are the build stamps: -ldflags "-X main.version=... -X main.commit=..." (release builds stamp only commit).
// daemonKey is the daemon part's source key (tools/src-key.sh `daemon`), stamped by every release and fetch-daemon build: the
// board compares it with the running daemon's to flag a stale daemon. An unstamped `go build` leaves it empty.
var version, commit, daemonKey = "dev", "dev", ""

func main() { os.Exit(run(os.Args[1:])) }

// mode picks the program from the first argument only: `daemon` or `board`, anything else (nothing, a port, --version, a
// helper word) is the board, as the old sprint-check binary took it. Never argv[0] or the file's name: os.Executable and
// symlinks make those unreliable, and Windows has no good links.
func mode(args []string) (string, []string) {
	if len(args) > 0 && (args[0] == "daemon" || args[0] == "board") {
		return args[0], args[1:]
	}
	return "board", args
}

func run(args []string) int {
	m, rest := mode(args)
	if m == "daemon" {
		return daemon.Run(version, commit, daemonKey, rest)
	}
	return board.Run(version, commit, daemonKey, rest)
}
