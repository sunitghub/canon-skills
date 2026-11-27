package board

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"canon/internal/events"
	"canon/internal/settings"
)

// githubCLI is `sprint-check github on|off|status [<dir>]`, reached as `canon github …` (t-393e). on/off add or remove the
// project's main checkout in the install-wide github.restricted_projects; status says which, and whether a token is stored,
// never the token. It writes only $CANON_HOME/settings.json: never git config, gh, Keychain or a credentials file.
func githubCLI(args []string, stdout, stderr io.Writer) int {
	usage := "usage: canon github on | off | status [<dir>]   (Cockpit claude sessions in the project get only its own GitHub token)"
	if len(args) < 1 || len(args) > 2 || (args[0] != "on" && args[0] != "off" && args[0] != "status") {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	dir := "."
	if len(args) == 2 {
		dir = args[1]
	}
	root, err := mainCheckout(dir)
	if err != nil {
		fmt.Fprintf(stderr, "canon github: %v\n", err)
		return 1
	}
	home := events.Home()
	roots, err := settings.RestrictedRoots(home)
	if err != nil {
		fmt.Fprintf(stderr, "canon github: %v (fix or remove the file; meanwhile every Cockpit claude session is restricted)\n", err)
		return 1
	}
	idx := -1
	for i, r := range roots {
		if settings.SameFolder(r, root) {
			idx = i
			break
		}
	}
	switch args[0] {
	case "status":
		fmt.Fprintf(stdout, "project: %s\n", root)
		if idx < 0 {
			fmt.Fprintln(stdout, "restricted GitHub access: off")
			return 0
		}
		fmt.Fprintln(stdout, "restricted GitHub access: on")
		_, state, reason := settings.GitHubToken(root)
		switch state {
		case settings.GitHubTokenOK:
			fmt.Fprintln(stdout, "token: stored")
		case settings.GitHubNoToken:
			fmt.Fprintln(stdout, "token: none")
		default:
			fmt.Fprintf(stdout, "token: error (%s)\n", reason)
		}
		fmt.Fprintln(stdout, "To store or replace the token (you type it at the prompt; use a fine-grained token for this project's repositories):")
		fmt.Fprintf(stdout, "  security add-generic-password -U -s %s -a %s -w\n", settings.KeychainService, shellQuote(root))
		return 0
	case "on":
		if idx >= 0 {
			fmt.Fprintf(stdout, "restricted GitHub access is already on for %s\n", root)
			return 0
		}
		roots = append(roots, root)
	case "off":
		if idx < 0 {
			fmt.Fprintf(stdout, "restricted GitHub access is already off for %s\n", root)
			return 0
		}
		roots = append(roots[:idx:idx], roots[idx+1:]...)
	}
	if err := os.MkdirAll(home, 0o700); err != nil {
		fmt.Fprintln(stderr, "canon github: cannot create the canon folder")
		return 1
	}
	list := make([]any, len(roots))
	for i, r := range roots {
		list[i] = r
	}
	if _, err := settings.InstallSet(home).SetLocal(settings.GitHubKey, list); err != nil {
		fmt.Fprintf(stderr, "canon github: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "restricted GitHub access: %s for %s (new Cockpit claude sessions; restart a running one)\n", args[0], root)
	if args[0] == "on" {
		fmt.Fprintf(stdout, "Next: canon github status %s (stores the token)\n", shellQuote(root))
	}
	return 0
}

// mainCheckout is the main working tree of the repository dir is in: the parent of git's common dir, so a linked worktree
// names the same project the daemon spawns sessions for.
func mainCheckout(dir string) (string, error) {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		return "", fmt.Errorf("%s is not in a git repository", dir)
	}
	common := strings.TrimRight(string(out), "\r\n")
	if filepath.Base(common) != ".git" {
		return "", fmt.Errorf("%s has no main working tree (bare repository)", dir)
	}
	return filepath.Dir(filepath.Clean(common)), nil
}
