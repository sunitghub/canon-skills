// Command cockpit-daemon runs canon's cockpit daemon (t-8020: one module, two binaries).
package main

import (
	"os"

	"canon/internal/daemon"
)

// version and commit are the build stamps: -ldflags "-X main.version=... -X main.commit=..." (release builds stamp only commit).
var version, commit = "dev", "dev"

func main() { os.Exit(daemon.Run(version, commit, os.Args[1:])) }
