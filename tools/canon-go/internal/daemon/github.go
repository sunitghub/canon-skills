package daemon

import (
	"fmt"
	"os"
	"strings"

	"canon/internal/events"
	"canon/internal/settings"
)

// Restricted GitHub access (t-393e). A project in github.restricted_projects gets claude sessions with no ambient GitHub login:
// no gh login (an empty GH_CONFIG_DIR), no git credential helper from any config level, no SSH, and only that project's own
// token from Keychain. This stops the agent USING the user's account by default; it is not containment: a same-user agent
// can still read ~/.git-credentials or the Keychain itself (docs/sprint-check.md says so).

// githubAccess is one restricted session's GitHub setup. token is never logged, put in argv or emitted.
type githubAccess struct {
	state, reason, token, ghDir string
}

// ghSSHRefuse is GIT_SSH_COMMAND: git runs it through sh with the ssh arguments appended, so the function ignores them.
const ghSSHRefuse = `canon_ssh_off() { echo "canon: SSH is off in this session (github.restricted_projects, t-393e)" >&2; exit 1; }; canon_ssh_off`

// ghCredHelper answers git's `get` with the session's GH_TOKEN; store and erase do nothing. printf, not echo: sh's echo expands
// backslash escapes, so a token holding `\n` would add its own protocol lines (t-393e break-it).
const ghCredHelper = `!f() { test "$1" = get || return 0; printf 'username=x-access-token\npassword=%s\n' "$GH_TOKEN"; }; f` // #nosec G101 -- a git helper that prints $GH_TOKEN at run time; no secret in source

// ghNoToken is GH_TOKEN when the session has no token: gh reads its Keychain login even with an empty GH_CONFIG_DIR (seen with gh
// 2.103.3: `gh auth token` still printed it), and a set GH_TOKEN wins over that. GitHub refuses it as bad credentials.
const ghNoToken = "canon-no-token" // canon:allow-secret: a fixed placeholder GitHub rejects, not a credential

// githubAccessFor is the GitHub setup of a claude session in projectRoot: nil when the project is not opted in. A settings
// file canon cannot read restricts with state error. It fails only when the session's gh folder cannot be made: starting
// without it would hand the session the user's own gh login.
func githubAccessFor(projectRoot string) (*githubAccess, error) {
	restricted, serr := settings.GitHubRestricted(events.Home(), projectRoot)
	if !restricted {
		return nil, nil
	}
	dir, err := os.MkdirTemp("", "canon-gh-")
	if err != nil {
		return nil, fmt.Errorf("cannot create the session's gh folder (github.restricted_projects): %w", err)
	}
	ga := &githubAccess{ghDir: dir}
	if serr != nil {
		ga.state, ga.reason = settings.GitHubError, "settings unreadable: "+settings.ClipReason(serr.Error())
		return ga, nil
	}
	ga.token, ga.state, ga.reason = settings.GitHubToken(projectRoot)
	return ga, nil
}

// githubStripped are the inherited variables a restricted session drops: tokens, SSH agent and askpass routes, and any
// command-line git config, which would come after (and so beat) the session's own.
var githubStripped = map[string]bool{
	"GH_TOKEN": true, "GITHUB_TOKEN": true, "GH_ENTERPRISE_TOKEN": true, "GITHUB_ENTERPRISE_TOKEN": true,
	"SSH_AUTH_SOCK": true, "GIT_ASKPASS": true, "SSH_ASKPASS": true, "GIT_SSH": true, "GIT_SSH_COMMAND": true,
	"GIT_CONFIG_PARAMETERS": true, "GIT_CONFIG_COUNT": true, "GH_CONFIG_DIR": true, "GIT_TERMINAL_PROMPT": true,
}

// githubEnv is env with ga applied. The empty credential.helper resets the helper list built from the system, global and local
// files (env config comes last); the github.com helper follows only when there is a token. ~/.gitconfig is kept (user.name).
func githubEnv(env []string, ga *githubAccess) []string {
	out := make([]string, 0, len(env)+16)
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if githubStripped[name] || strings.HasPrefix(name, "GIT_CONFIG_KEY_") || strings.HasPrefix(name, "GIT_CONFIG_VALUE_") {
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "GH_CONFIG_DIR="+ga.ghDir, "GIT_TERMINAL_PROMPT=0", "GIT_SSH_COMMAND="+ghSSHRefuse)
	// Empty values reset: core.askPass would answer the prompt GIT_TERMINAL_PROMPT=0 refuses; an extraheader is a stored
	// Authorization header (actions/checkout writes the github.com form). A path-scoped extraheader beats the reset (docs say so).
	cfg := [][2]string{{"credential.helper", ""}, {"core.askPass", ""}, {"http.extraheader", ""}, {"http.https://github.com/.extraheader", ""}}
	tok := ghNoToken
	if ga.token != "" {
		cfg = append(cfg, [2]string{"credential.https://github.com.helper", ghCredHelper})
		tok = ga.token
	}
	for i, kv := range cfg {
		out = append(out, fmt.Sprintf("GIT_CONFIG_KEY_%d=%s", i, kv[0]), fmt.Sprintf("GIT_CONFIG_VALUE_%d=%s", i, kv[1]))
	}
	return append(out, fmt.Sprintf("GIT_CONFIG_COUNT=%d", len(cfg)), "GH_TOKEN="+tok)
}

// notice is the line a restricted session's scrollback starts with.
func (ga *githubAccess) notice() string {
	msg := "restricted to this project's token from Keychain (" + settings.KeychainService + ")"
	switch ga.state {
	case settings.GitHubNoToken:
		msg = "restricted; no token is stored for this project, so GitHub is refused. See: canon github status"
	case settings.GitHubError, settings.GitHubUnsupported:
		msg = "restricted; GitHub is refused (" + ga.reason + ")"
	}
	return "\r\n[canon] GitHub: " + msg + "\r\n"
}
