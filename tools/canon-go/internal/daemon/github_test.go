package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"canon/internal/settings"
)

// t-393e tests. Prod path: the daemon's spawn of every Cockpit claude session (sessionEnv, githubAccessFor, spawn's notice).

// stubSecurity points settings.SecurityBin at a script that records its argv in the returned file and runs body.
func stubSecurity(t *testing.T, body string) (argvFile string) {
	t.Helper()
	dir := t.TempDir()
	argvFile = filepath.Join(dir, "argv")
	bin := filepath.Join(dir, "security")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + argvFile + "'\n" + body + "\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old, oldOS, oldTO := settings.SecurityBin, settings.GitHubGOOS, settings.KeychainTimeout
	settings.SecurityBin, settings.GitHubGOOS = bin, "darwin"
	t.Cleanup(func() { settings.SecurityBin, settings.GitHubGOOS, settings.KeychainTimeout = old, oldOS, oldTO })
	return argvFile
}

// optIn writes a CANON_HOME whose settings list root (or holds raw, when raw is not empty).
func optIn(t *testing.T, root, raw string) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	if raw == "" {
		raw = `{"github":{"restricted_projects":["` + root + `"]}}`
	}
	if err := os.WriteFile(filepath.Join(home, "settings.json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

func envValue(env []string, name string) (string, bool) {
	for _, kv := range env {
		if k, v, _ := strings.Cut(kv, "="); k == name {
			return v, true
		}
	}
	return "", false
}

var inherited = []string{
	"PATH=/bin", "HOME=/h", "GH_TOKEN=amb1", "GITHUB_TOKEN=amb2", "GH_ENTERPRISE_TOKEN=amb3", "GITHUB_ENTERPRISE_TOKEN=amb4",
	"SSH_AUTH_SOCK=/tmp/agent", "GIT_ASKPASS=/a", "SSH_ASKPASS=/b", "GIT_SSH=/c", "GIT_SSH_COMMAND=ssh -i k",
	"GIT_CONFIG_PARAMETERS='credential.helper'='store'", "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=credential.helper",
	"GIT_CONFIG_VALUE_0=store", "GIT_CONFIG_KEY_7=x.y", "GIT_CONFIG_VALUE_7=z", "GH_CONFIG_DIR=/real/gh", "GIT_TERMINAL_PROMPT=1",
}

// Opted out (ga nil), a claude session's env is exactly the pre-t-393e one: the daemon env, COCKPIT_*, prompt suggestions off.
func TestSessionEnvGitHubOptedOutUnchanged(t *testing.T) {
	got := sessionEnv("claude", "t-ab12", "sid1", inherited, nil)
	want := append(append([]string{}, inherited...), "COCKPIT_TICKET=t-ab12", "COCKPIT_AGENT=claude", "COCKPIT_SESSION=sid1", "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("opted-out env changed:\n got %q\nwant %q", got, want)
	}
}

// pi, copilot and term get the same env opted in as opted out (their own follow-up rows).
func TestSessionEnvGitHubOtherKindsUnchanged(t *testing.T) {
	ga := &githubAccess{state: settings.GitHubTokenOK, token: "tok", ghDir: "/x"}
	for _, kind := range []string{"pi", "copilot", "term"} {
		if a, b := sessionEnv(kind, "t-ab12", "sid1", inherited, ga), sessionEnv(kind, "t-ab12", "sid1", inherited, nil); !reflect.DeepEqual(a, b) {
			t.Errorf("%s: env differs when opted in:\n%q\n%q", kind, a, b)
		}
	}
}

func TestSessionEnvGitHubStripsAndSets(t *testing.T) {
	for _, tok := range []string{"", "tok_abc"} {
		ga := &githubAccess{token: tok, ghDir: "/s/gh"}
		env := sessionEnv("claude", "t-ab12", "sid1", inherited, ga)
		for _, kv := range env {
			if strings.Contains(kv, "amb") || strings.Contains(kv, "store") || strings.HasPrefix(kv, "GIT_CONFIG_KEY_7") ||
				strings.HasPrefix(kv, "SSH_AUTH_SOCK=") || strings.HasPrefix(kv, "GIT_ASKPASS=") || strings.HasPrefix(kv, "SSH_ASKPASS=") ||
				strings.HasPrefix(kv, "GIT_SSH=") || strings.HasPrefix(kv, "GIT_CONFIG_PARAMETERS=") || strings.HasPrefix(kv, "GIT_CONFIG_GLOBAL=") {
				t.Errorf("token %q: inherited %q kept", tok, kv)
			}
		}
		for name, want := range map[string]string{"GH_CONFIG_DIR": "/s/gh", "GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": ghSSHRefuse, "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "", "PATH": "/bin", "HOME": "/h"} {
			if v, ok := envValue(env, name); !ok || v != want {
				t.Errorf("token %q: %s = %q (set %v), want %q", tok, name, v, ok, want)
			}
		}
		count, _ := envValue(env, "GIT_CONFIG_COUNT")
		gh, hasGH := envValue(env, "GH_TOKEN")
		if tok == "" && (count != "1" || hasGH) {
			t.Errorf("no token: GIT_CONFIG_COUNT=%q GH_TOKEN set=%v, want 1 and unset", count, hasGH)
		}
		if tok != "" && (count != "2" || gh != tok) {
			t.Errorf("token: GIT_CONFIG_COUNT=%q GH_TOKEN=%q, want 2 and %q", count, gh, tok)
		}
	}
}

// Real git: every credential level is planted (system, global incl. a github.com-scoped helper, the repo's local `store`
// with a ~/.git-credentials entry); with the session env git sees only the session token, or none. Prod path: git auth in an
// opted-in session.
func TestGitHubEnvRealGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	w := t.TempDir()
	home, repo := filepath.Join(w, "home"), filepath.Join(w, "repo")
	for _, d := range []string{home, repo} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(w, "system"), "[credential]\n\thelper = \"!f() { echo password=PLANTED_SYSTEM; }; f\"\n")
	write(filepath.Join(home, ".gitconfig"), "[user]\n\tname = Planted Name\n[credential \"https://github.com\"]\n\thelper = \"!f() { echo password=PLANTED_GLOBAL; }; f\"\n")
	write(filepath.Join(home, ".git-credentials"), "https://u:PLANTED_STORE@github.com\n") // canon:allow-secret: a planted fake credential the test proves git never returns
	base := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "GIT_CONFIG_SYSTEM=" + filepath.Join(w, "system"), "GIT_TERMINAL_PROMPT=0"}
	git := func(env []string, stdin string, args ...string) (string, string, error) {
		c := exec.Command("git", args...)
		c.Dir, c.Env, c.Stdin = repo, env, strings.NewReader(stdin)
		var out, errb strings.Builder
		c.Stdout, c.Stderr = &out, &errb
		err := c.Run()
		return out.String(), errb.String(), err
	}
	if _, e, err := git(base, "", "init", "-q"); err != nil {
		t.Fatalf("git init: %v %s", err, e)
	}
	if _, e, err := git(base, "", "config", "credential.helper", "store"); err != nil {
		t.Fatalf("git config: %v %s", err, e)
	}
	fill := "protocol=https\nhost=github.com\n\n"
	if out, _, _ := git(base, fill, "credential", "fill"); !strings.Contains(out, "PLANTED_") {
		t.Fatalf("baseline: the planted helpers answer nothing, so the test proves nothing: %q", out)
	}
	for _, tok := range []string{"SESSION_TOK", ""} {
		env := githubEnv(base, &githubAccess{token: tok, ghDir: filepath.Join(w, "gh")})
		out, errOut, err := git(env, fill, "credential", "fill")
		if strings.Contains(out, "PLANTED_") {
			t.Errorf("token %q: an ambient helper answered: %q", tok, out)
		}
		if tok != "" && (err != nil || !strings.Contains(out, "password=SESSION_TOK\n")) {
			t.Errorf("with a token: %v %q %q, want password=SESSION_TOK", err, out, errOut)
		}
		if tok == "" && (err == nil || strings.Contains(out, "password=")) {
			t.Errorf("no token: git returned a password: %v %q", err, out)
		}
		if name, _, _ := git(env, "", "config", "user.name"); strings.TrimSpace(name) != "Planted Name" {
			t.Errorf("token %q: user.name = %q, want the global one kept", tok, name)
		}
		_, errOut, err = git(env, "", "ls-remote", "ssh://git@example.invalid/x.git")
		if err == nil || !strings.Contains(errOut, "canon: SSH is off in this session") {
			t.Errorf("token %q: ssh remote not refused by canon: %v %q", tok, err, errOut)
		}
	}
}

func TestGitHubTokenStates(t *testing.T) {
	root := t.TempDir()
	for _, c := range []struct{ body, state string }{
		{"exit 44", settings.GitHubNoToken},
		{"exit 51", settings.GitHubError},
		{"echo 'has space'", settings.GitHubError},
		{"echo ''", settings.GitHubNoToken},
		{"echo tok_ok", settings.GitHubTokenOK},
	} {
		argv := stubSecurity(t, c.body)
		tok, state, reason := settings.GitHubToken(root)
		if state != c.state {
			t.Errorf("%q: state %q (%s), want %q", c.body, state, reason, c.state)
		}
		if state == settings.GitHubError && reason == "" {
			t.Errorf("%q: error with no reason", c.body)
		}
		if (state == settings.GitHubTokenOK) != (tok == "tok_ok") {
			t.Errorf("%q: token %q", c.body, tok)
		}
		b, _ := os.ReadFile(argv)
		if want := "find-generic-password\n-s\ncanon-github\n-a\n" + root + "\n-w\n"; string(b) != want {
			t.Errorf("%q: security argv %q, want %q (keyed by the project root)", c.body, b, want)
		}
	}
	stubSecurity(t, "sleep 5")
	settings.KeychainTimeout = 200 * time.Millisecond
	if _, state, reason := settings.GitHubToken(root); state != settings.GitHubError || !strings.Contains(reason, "timed out") {
		t.Errorf("hung read: %q %q, want error timed out", state, reason)
	}
	stubSecurity(t, "echo tok_ok")
	settings.GitHubGOOS = "linux"
	if tok, state, _ := settings.GitHubToken(root); state != settings.GitHubUnsupported || tok != "" {
		t.Errorf("linux: %q %q, want unsupported and no token", state, tok)
	}
}

func TestGitHubAccessForFailsClosed(t *testing.T) {
	root := t.TempDir()
	stubSecurity(t, "exit 44")
	t.Setenv("CANON_HOME", t.TempDir())
	if ga, err := githubAccessFor(root); ga != nil || err != nil {
		t.Fatalf("not opted in: %+v %v, want nil", ga, err)
	}
	for _, raw := range []string{"{not json", `{"github":{"restricted_projects":"relative/x"}}`} {
		optIn(t, root, raw)
		ga, err := githubAccessFor(root)
		if err != nil || ga == nil || ga.state != settings.GitHubError || !strings.Contains(ga.reason, "settings unreadable") {
			t.Fatalf("settings %q: %+v %v, want restricted with state error", raw, ga, err)
		}
		fi, err := os.Stat(ga.ghDir)
		if err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
			t.Fatalf("gh folder %q: %v %v", ga.ghDir, fi, err)
		}
		if ents, _ := os.ReadDir(ga.ghDir); len(ents) != 0 {
			t.Fatalf("gh folder not empty: %v", ents)
		}
		os.RemoveAll(ga.ghDir)
	}
	optIn(t, root, "")
	block := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(block, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", filepath.Join(block, "sub"))
	if ga, err := githubAccessFor(root); err == nil || !strings.Contains(err.Error(), "gh folder") {
		t.Fatalf("gh folder cannot be made: %+v %v, want an error naming it", ga, err)
	}
}

// A full spawn: the notice leads the scrollback, the event has the state only, the child gets GH_TOKEN, and the token is in no
// argv, debug log line or event. A gh-folder failure fails the spawn.
func TestSpawnGitHubRestricted(t *testing.T) {
	debugEnabled.Store(true)
	defer debugEnabled.Store(false)
	root := t.TempDir()
	initGitRepo(t, root)
	seedTicketDir(t, root, "t-ab12")
	home := optIn(t, root, "")
	const tok = "tok_PLANTED_393e"
	argv := stubSecurity(t, "echo "+tok)
	envFile := filepath.Join(t.TempDir(), "env")
	bin := filepath.Join(t.TempDir(), "agent")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nenv > '"+envFile+"'\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
	t.Cleanup(func() { killAllSessions(s) })
	se, err := s.spawn("t-ab12", root, root, "claude")
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}
	var env []byte
	for i := 0; i < 100 && len(env) == 0; i++ {
		time.Sleep(30 * time.Millisecond)
		env, _ = os.ReadFile(envFile)
	}
	if !strings.Contains(string(env), "GH_TOKEN="+tok+"\n") {
		t.Errorf("the child has no GH_TOKEN with the stored token")
	}
	se.mu.Lock()
	buf := string(se.buf)
	se.mu.Unlock()
	if !strings.HasPrefix(buf, "\r\n[canon] GitHub: restricted to this project's token") || strings.Count(buf, "[canon] GitHub:") != 1 {
		t.Errorf("scrollback does not start with one notice: %q", buf)
	}
	gh := se.ghDir
	s.killSession(se)
	ev, _ := os.ReadFile(filepath.Join(home, "events", time.Now().UTC().Format("2006-01-02")+".jsonl"))
	if !strings.Contains(string(ev), `"kind":"session.github"`) || !strings.Contains(string(ev), `"state":"token"`) {
		t.Errorf("no session.github event with state token: %s", ev)
	}
	dbg, _ := os.ReadFile(filepath.Join(root, ".tickets", "t-ab12", ".cockpit-debug.log"))
	if len(dbg) == 0 {
		t.Errorf("no debug log written, so the token check below proves nothing")
	}
	sa, _ := os.ReadFile(argv)
	for name, b := range map[string]string{"event": string(ev), "debug log": string(dbg), "agent argv": strings.Join(se.cmd.Args, " "), "security argv": string(sa)} {
		if strings.Contains(b, tok) {
			t.Errorf("the token is in the %s", name)
		}
	}
	for i := 0; i < 100; i++ {
		if _, err := os.Stat(gh); os.IsNotExist(err) {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if _, err := os.Stat(gh); !os.IsNotExist(err) {
		t.Errorf("the gh folder %s outlived the session", gh)
	}

	block := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(block, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", filepath.Join(block, "sub"))
	if se, err := s.spawn("t-ab12", root, root, "claude"); err == nil || !strings.Contains(err.Error(), "gh folder") {
		if se != nil {
			s.killSession(se)
		}
		t.Fatalf("spawn with no gh folder: %v, want an error naming it", err)
	}
}
