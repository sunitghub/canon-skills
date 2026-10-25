package term

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// project builds a small project plus a file outside it, and returns both folders.
func project(t *testing.T) (root, outside string) {
	t.Helper()
	base := t.TempDir()
	root, outside = filepath.Join(base, "proj"), filepath.Join(base, "outside")
	for _, d := range []string{root, outside, filepath.Join(root, "sub"), filepath.Join(root, ".git")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	w := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	w(filepath.Join(root, "a.go"), "package main\n\nfunc main() {}\n")
	w(filepath.Join(root, "sub", "b.md"), "# title\n")
	w(filepath.Join(root, ".env"), "SECRET=1\n")
	w(filepath.Join(root, ".env.local"), "SECRET=2\n")
	w(filepath.Join(root, ".git", "config"), "[core]\n")
	w(filepath.Join(outside, "secret.txt"), "outside\n")
	if runtime.GOOS != "windows" {
		must := func(err error) {
			if err != nil {
				t.Fatal(err)
			}
		}
		must(os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(root, "link-out")))
		must(os.Symlink(outside, filepath.Join(root, "dir-out")))
		must(os.Symlink(filepath.Join(root, "a.go"), filepath.Join(root, "link-in")))
		must(os.Symlink(filepath.Join(root, ".git", "config"), filepath.Join(root, "link-git")))
		must(os.Symlink(filepath.Join(root, ".env"), filepath.Join(root, "link-env")))
	}
	return root, outside
}

// Protects ls and cat: nothing outside the project, no .git, no .env*, by any spelling or link.
func TestConfine(t *testing.T) {
	root, outside := project(t)
	cases := []struct{ arg, wantErr string }{
		{"a.go", ""},
		{"sub/b.md", ""},
		{"./sub/../a.go", ""},
		{".", ""},
		{"sub", ""},
		{filepath.Join(root, "a.go"), ""},
		{"..", "outside this project"},
		{"../outside/secret.txt", "outside this project"},
		{"sub/../../outside/secret.txt", "outside this project"},
		{filepath.Join(outside, "secret.txt"), "outside this project"},
		{"/etc/passwd", "outside this project"},
		{".git", ".git folder"},
		{".git/config", ".git folder"},
		{".env", ".env files"},
		{".env.local", ".env files"},
		{"nope.txt", "no such file"},
		{".ENV", ".env files"}, // any letter case: macOS and Windows file systems ignore it
		{".Env.local", ".env files"},
		{".GIT/config", ".git folder"},
		{"sub/.Git", ".git folder"},
		{"sub\\.ENV", ".env files"}, // a Windows separator
		{"a.go\x00x", "not allowed"},
	}
	if runtime.GOOS != "windows" {
		cases = append(cases, []struct{ arg, wantErr string }{
			{"link-in", ""},
			{"link-out", "outside this project"},
			{"dir-out", "outside this project"},
			{"dir-out/secret.txt", "outside this project"},
			{"link-git", ".git folder"},
			{"link-env", ".env files"},
		}...)
	}
	for _, c := range cases {
		_, err := confine(root, c.arg)
		switch {
		case c.wantErr == "" && err != nil:
			t.Errorf("confine(%q): unexpected error %v", c.arg, err)
		case c.wantErr != "" && (err == nil || !strings.Contains(err.Error(), c.wantErr)):
			t.Errorf("confine(%q) = %v, want an error containing %q", c.arg, err, c.wantErr)
		}
	}
}

// Protects cat's limits: regular files only, a size cap, no binary.
func TestReadFile(t *testing.T) {
	root, _ := project(t)
	big := filepath.Join(root, "big.txt")
	if err := os.WriteFile(big, bytes.Repeat([]byte("x"), maxFile+1), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin.dat"), []byte("ab\x00cd"), 0o644); err != nil {
		t.Fatal(err)
	}
	for arg, want := range map[string]string{"big.txt": "over 1 MB", "bin.dat": "binary file", "sub": "not a regular file"} {
		if _, _, err := readFile(root, arg); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("readFile(%q) = %v, want %q", arg, err, want)
		}
	}
	src, name, err := readFile(root, "a.go")
	if err != nil || name != "a.go" || !strings.Contains(src, "func main") {
		t.Errorf("readFile(a.go) = %q, %q, %v", src, name, err)
	}
}

// Protects the terminal from file content: no control character reaches it, so a file cannot move the cursor, set the
// window title, or draw a fake su prompt.
func TestVisible(t *testing.T) {
	in := "a\x1b[2J\x1b]0;pwned\x07b\rc\x7fd\u0085e\n\tf"
	out := Visible(in)
	for _, r := range out {
		if r == '\n' || r == '\t' {
			continue
		}
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			t.Fatalf("control character %U left in %q", r, out)
		}
	}
	if !strings.Contains(out, "\u241b[2J") || !strings.Contains(out, "\n\tf") {
		t.Errorf("Visible = %q: ESC should show as U+241B and newline and tab stay", out)
	}
}

// Protects the time limit: a lexer that takes longer than the limit is dropped and the file is shown plain.
func TestHighlightTimeoutShowsPlain(t *testing.T) {
	old := highlightLimit
	highlightLimit = time.Nanosecond
	t.Cleanup(func() { highlightLimit = old })
	src := strings.Repeat("package main\n\nfunc f() { println(\"x\") }\n", 20000)
	if got := Highlight("big.go", src); got != src {
		t.Errorf("a lexer past its limit should leave the text plain (got %d bytes, want %d)", len(got), len(src))
	}
}

func TestHighlight(t *testing.T) {
	if got := Highlight("a.go", "package main\n"); !strings.Contains(got, "\x1b[") || !strings.Contains(got, "package") {
		t.Errorf("a Go file should be coloured, got %q", got)
	}
	if got := Highlight("notes.unknownext", "hello\n"); got != "hello\n" {
		t.Errorf("an unknown type should stay plain, got %q", got)
	}
}

// run drives the prompt with the given input and returns what it printed.
func run(t *testing.T, cfg Config, input string) string {
	t.Helper()
	var out bytes.Buffer
	cfg.In, cfg.Out = strings.NewReader(input), &out
	if code := Run(cfg); code != 0 {
		t.Fatalf("Run returned %d", code)
	}
	return out.String()
}

// Protects the restricted prompt's command set: ls and cat work in the project, everything else is refused by name, and
// a line with a shell metacharacter is refused whole.
func TestPromptCommands(t *testing.T) {
	root, _ := project(t)
	cfg := Config{Root: root}
	out := run(t, cfg, "help\nls\ncat a.go\ncat .env\ncat ../outside/secret.txt\nrm -rf x\ncat a.go | cat\nls -R\n?\nexit\ncat a.go\n")
	for _, want := range []string{
		"Welcome to Canon Console", "Needs su",
		" a.go\n", " \x1b[1;34msub/\x1b[0m\n",
		"package",
		"cat: .env files are never shown",
		"cat: outside this project",
		"not allowed here: rm",
		"not supported here (no shell): |",
		"usage: ls [path]",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if strings.Count(out, "package") != 1 {
		t.Errorf("exit should stop the prompt: the cat after it must not run:\n%s", out)
	}
	if strings.Contains(out, "SECRET") || strings.Contains(out, "outside\n") {
		t.Errorf("a refused file's content leaked:\n%s", out)
	}
}

// Protects against a file spoofing the terminal: ESC in a file never reaches the output.
func TestCatNeverEmitsFileEscapes(t *testing.T) {
	root, _ := project(t)
	if err := os.WriteFile(filepath.Join(root, "evil.txt"), []byte("hi\x1b]0;pwned\x07\x1b[2Jfake$ \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := run(t, Config{Root: root}, "cat evil.txt\nexit\n")
	// chroma adds its own colour codes (ESC [ ... m); after removing those, nothing may be left.
	rest := regexp.MustCompile("\x1b\\[[0-9;]*m").ReplaceAllString(out, "")
	if strings.ContainsRune(rest, 0x1b) || strings.ContainsRune(rest, 0x07) {
		t.Errorf("a control character from the file reached the terminal: %q", out)
	}
	if !strings.Contains(out, "\u241b") {
		t.Errorf("the escape should show as a symbol: %q", out)
	}
}

var helpCmdRe = regexp.MustCompile(`(?m)^  ([a-z][a-z-]*)\b`)

// tktHelp reads the real tkt's subcommands.
func tktHelp(t *testing.T) []string {
	t.Helper()
	tkt := filepath.Join("..", "..", "..", "tkt")
	if _, err := os.Stat(tkt); err != nil || runtime.GOOS == "windows" {
		t.Skip("tools/tkt not available here")
	}
	out, err := exec.Command("bash", tkt, "--help").CombinedOutput()
	if err != nil {
		t.Fatalf("tkt --help: %v\n%s", err, out)
	}
	var subs []string
	for _, m := range helpCmdRe.FindAllStringSubmatch(string(out), -1) {
		subs = append(subs, m[1])
	}
	return subs
}

// Protects the read-only promise: every tkt subcommand that is not on the list is refused, today and when one is added,
// and every name on the list still exists in tkt.
func TestTktAllowlistAgainstHelp(t *testing.T) {
	subs := tktHelp(t)
	if len(subs) < 10 {
		t.Fatalf("parsed only %d tkt subcommands from --help: %v", len(subs), subs)
	}
	root, _ := project(t)
	marker := filepath.Join(t.TempDir(), "ran")
	fake := filepath.Join(t.TempDir(), "tkt")
	script := "#!/bin/sh\necho \"$@\" >> " + marker + "\necho ran-$1\n"
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, s := range subs {
		have[s] = true
	}
	for _, ro := range ReadOnlyTkt() {
		if !have[ro] {
			t.Errorf("read-only tkt %q is not in tkt --help any more", ro)
		}
	}
	cfg := Config{Root: root, Tkt: fake}
	for _, s := range subs {
		_ = os.Remove(marker)
		out := run(t, cfg, "tkt "+s+" x\nexit\n")
		_, ran := os.Stat(marker)
		if readOnlyTkt[s] {
			if ran != nil || !strings.Contains(out, "ran-"+s) {
				t.Errorf("tkt %s is read-only and should run, got:\n%s", s, out)
			}
		} else if ran == nil || !strings.Contains(out, "not allowed here: tkt "+s) {
			t.Errorf("tkt %s changes things and must be refused, got:\n%s", s, out)
		}
	}
	// A subcommand that does not exist yet is refused too.
	_ = os.Remove(marker)
	if out := run(t, cfg, "tkt brand-new-write-command\nexit\n"); !strings.Contains(out, "not allowed here: tkt brand-new-write-command") {
		t.Errorf("an unknown tkt subcommand must be refused:\n%s", out)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Errorf("an unknown tkt subcommand ran")
	}
}

// fakeSu is a su setup with a controllable clock and a shell that blocks until it is told to stop.
type fakeSu struct {
	mu      sync.Mutex
	events  []string
	started chan struct{}
	stop    chan struct{}
	waits   []time.Duration
	chans   []chan time.Time
	emitErr error
	auth    []error // what each OS prompt answers, in order; an empty queue passes
	ctxErr  error
	shells  int
}

func newFakeSu() *fakeSu { return &fakeSu{started: make(chan struct{}, 4), stop: make(chan struct{})} }

func (f *fakeSu) cfg(root string) Config {
	return Config{
		Root: root, Session: "sid", Ticket: "s-ab12",
		Auth: func(context.Context, io.Writer) error {
			f.mu.Lock()
			defer f.mu.Unlock()
			if len(f.auth) == 0 {
				return nil
			}
			e := f.auth[0]
			f.auth = f.auth[1:]
			return e
		},
		Emit: func(kind string, data map[string]string) error {
			f.mu.Lock()
			defer f.mu.Unlock()
			if kind == "terminal.su_granted" && f.emitErr != nil {
				return f.emitErr
			}
			e := kind
			for _, k := range []string{"reason", "how", "minutes"} {
				if v, ok := data[k]; ok {
					e += " " + k + "=" + v
				}
			}
			if data["session"] != "sid" || data["ticket"] != "s-ab12" {
				e += " BADFIELDS"
			}
			f.events = append(f.events, e)
			return nil
		},
		RunShell: func(ctx context.Context, root string) error {
			f.mu.Lock()
			f.shells++
			f.mu.Unlock()
			f.started <- struct{}{}
			select {
			case <-ctx.Done():
				f.mu.Lock()
				f.ctxErr = ctx.Err()
				f.mu.Unlock()
			case <-f.stop:
			}
			return nil
		},
		After: func(d time.Duration) <-chan time.Time {
			f.mu.Lock()
			defer f.mu.Unlock()
			ch := make(chan time.Time, 1)
			f.waits, f.chans = append(f.waits, d), append(f.chans, ch)
			return ch
		},
		Limit: 5 * time.Minute, Warn: 30 * time.Second,
	}
}

func (f *fakeSu) log() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.events, "|")
}

// Protects the fail-closed rule: when su_granted cannot be written, no shell starts.
func TestSuFailsClosedWhenTheLogCannotBeWritten(t *testing.T) {
	root, _ := project(t)
	f := newFakeSu()
	f.emitErr = errors.New("disk full")
	close(f.stop) // a shell that starts anyway returns at once, so a broken guard fails the check below instead of hanging on the fake clock
	out := run(t, f.cfg(root), "su\nls\nexit\n")
	if f.shells != 0 {
		t.Fatal("a shell started although su_granted could not be logged")
	}
	if !strings.Contains(out, "su refused") || !strings.Contains(out, "a.go") {
		t.Errorf("a refusal should print its message and leave the prompt running (ls after it):\n%s", out)
	}
}

// Protects the ten minutes: a warning 30 s before the end, then the shell is stopped through its context and the
// prompt comes back; a shell that exits first is logged as exited.
func TestSuExpiry(t *testing.T) {
	root, _ := project(t)
	f := newFakeSu()
	cfg := f.cfg(root)
	out := &safeBuf{}
	pr, pw := newPipe()
	cfg.In, cfg.Out = pr, out
	done := make(chan int, 1)
	go func() { done <- Run(cfg) }()
	pw.WriteString("su\n")
	<-f.started
	waitFor(t, func() bool { f.mu.Lock(); defer f.mu.Unlock(); return len(f.chans) == 2 })
	if f.waits[0] != 4*time.Minute+30*time.Second || f.waits[1] != 5*time.Minute {
		t.Fatalf("timers %v, want 4m30s and 5m", f.waits)
	}
	f.chans[0] <- time.Now()
	waitFor(t, func() bool { return strings.Contains(out.String(), "full shell ends in") })
	f.chans[1] <- time.Now()
	waitFor(t, func() bool { return strings.Contains(out.String(), "time is up") })
	f.mu.Lock()
	ctxErr := f.ctxErr
	f.mu.Unlock()
	if !errors.Is(ctxErr, context.Canceled) {
		t.Errorf("the shell was not stopped through its context: %v", ctxErr)
	}
	if got := f.log(); got != "terminal.su_prompted|terminal.su_granted minutes=5|terminal.su_expired how=ended" {
		t.Errorf("events %q", got)
	}
	// Back in the restricted prompt: a shell command is refused again, and su can start another ten minutes.
	pw.WriteString("rm x\nexit\n")
	if code := <-done; code != 0 {
		t.Errorf("Run returned %d", code)
	}
	if !strings.Contains(out.String(), "not allowed here: rm") {
		t.Errorf("the prompt did not come back restricted:\n%s", out.String())
	}

	g := newFakeSu()
	close(g.stop)
	run(t, g.cfg(root), "su\nexit\n")
	if got := g.log(); got != "terminal.su_prompted|terminal.su_granted minutes=5|terminal.su_expired how=exited" {
		t.Errorf("a shell that exits first: events %q", got)
	}
}

// Without a shell runner (Windows today) su says so and starts nothing.
func TestSuUnavailable(t *testing.T) {
	root, _ := project(t)
	out := run(t, Config{Root: root}, "su\nls\nexit\n")
	if !strings.Contains(out, "su is not available") || !strings.Contains(out, "a.go") {
		t.Errorf("su should say so and leave the prompt running (ls after it):\n%s", out)
	}
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	for i := 0; i < 400; i++ {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting")
}

// safeBuf is a buffer one goroutine writes while the test reads.
type safeBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *safeBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *safeBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

type pipeW struct{ *io.PipeWriter }

func (p pipeW) WriteString(s string) { _, _ = p.Write([]byte(s)) }

func newPipe() (io.Reader, pipeW) { r, w := io.Pipe(); return r, pipeW{w} }

// su asks the OS for the account password and never for a word: a pass starts the shell, a failure is su_denied
// reason=auth, three failures close the terminal, and no provider means su is unavailable (no fallback, no shell).
func TestSuUsesOSAuth(t *testing.T) {
	root, _ := project(t)
	fail := errors.New("Authentication failed")
	for _, c := range []struct {
		name, input, events string
		auth                []error
		noAuth              bool // Config.Auth is nil
		shells              int
		code                int    // Run's exit status: 1 only when the terminal is closed
		say                 string // what the user is told
	}{
		{"pass", "su\nexit\n", "terminal.su_prompted|terminal.su_granted minutes=5|terminal.su_expired how=exited", nil, false, 1, 0, "Approve the OS prompt"},
		{"fail", "su\nexit\n", "terminal.su_prompted|terminal.su_denied reason=auth", []error{fail}, false, 0, 0, "Authentication failed: still in the restricted prompt."},
		{"three fails", "su\nsu\nsu\nexit\n", "terminal.su_prompted|terminal.su_denied reason=auth|terminal.su_prompted|terminal.su_denied reason=auth|terminal.su_prompted|terminal.su_denied reason=locked", []error{fail, fail, fail}, false, 0, 1, "closing the terminal"},
		{"no provider", "su\nexit\n", "terminal.su_prompted|terminal.su_denied reason=unavailable", []error{ErrNoAuth}, false, 0, 0, "su is not available here"},
		{"no Auth at all", "su\nexit\n", "terminal.su_prompted|terminal.su_denied reason=unavailable", nil, true, 0, 0, "su is not available here"},
	} {
		f := newFakeSu()
		close(f.stop)
		f.auth = c.auth
		cfg := f.cfg(root)
		if c.noAuth {
			cfg.Auth = nil
		}
		var buf bytes.Buffer
		cfg.In, cfg.Out = strings.NewReader(c.input), &buf
		code := Run(cfg)
		out := buf.String()
		if code != c.code || !strings.Contains(out, c.say) {
			t.Errorf("%s: exit %d, want %d; output lacks %q:\n%s", c.name, code, c.code, c.say, out)
		}
		if f.shells != c.shells || f.log() != c.events {
			t.Errorf("%s: shells=%d events %q, want %d %q", c.name, f.shells, f.log(), c.shells, c.events)
		}
		if strings.Contains(out, "to continue (Enter cancels)") {
			t.Errorf("%s: a typed word was asked for", c.name)
		}
	}
}

// authCommand picks the OS's own password prompt for the account: dscl on macOS, su to the same account on Linux, Windows
// sudo only when it is switched on; anything else, or no tool on PATH, or no account name, is no provider.
func TestAuthCommand(t *testing.T) {
	found := func(n string) (string, error) { return "/usr/bin/" + n, nil }
	missing := func(string) (string, error) { return "", errors.New("not found") }
	on, off := func() bool { return true }, func() bool { return false }
	for _, c := range []struct {
		goos, account, want string
		root                bool // running as root
		lookPath            func(string) (string, error)
		sudoOn              func() bool
	}{
		{"darwin", "sam", "/usr/bin/dscl . -authonly sam", false, found, on},
		{"linux", "sam", "/usr/bin/su -c true sam", false, found, on},
		{"windows", "sam", "/usr/bin/sudo cmd /c exit", false, found, on},
		{"windows", "sam", "", false, found, off},  // sudo is off in Settings: only UAC-less failure, so no provider
		{"darwin", "sam", "", false, missing, on},  // no dscl
		{"linux", "sam", "", false, missing, on},   // no su
		{"windows", "sam", "", false, missing, on}, // no sudo.exe
		{"darwin", "", "", false, found, on},       // no account name to check
		{"linux", "", "", false, found, on},
		{"freebsd", "sam", "", false, found, on},
		{"linux", "root", "", true, found, on},                                // su asks root for nothing: no check, so no provider
		{"darwin", "root", "/usr/bin/dscl . -authonly root", true, found, on}, // dscl asks for the password whoever runs it // su -c means something else there
	} {
		name, args, ok := authCommand(c.goos, c.account, c.root, c.lookPath, c.sudoOn)
		got := ""
		if ok {
			got = name + " " + strings.Join(args, " ")
		}
		if got != c.want {
			t.Errorf("%s/%q: got %q, want %q", c.goos, c.account, got, c.want)
		}
	}
	// A sudo alone is no provider on macOS or Linux: sudo -v passes silently for a NOPASSWD user.
	onlySudo := func(n string) (string, error) {
		if n == "sudo" {
			return "/usr/bin/sudo", nil
		}
		return "", errors.New("not found")
	}
	for _, goos := range []string{"darwin", "linux"} {
		if _, _, ok := authCommand(goos, "sam", false, onlySudo, on); ok {
			t.Errorf("%s must not fall back to sudo for the password check", goos)
		}
	}
}

// OSAuth runs the tool it finds on PATH with the account name: none means no provider (ErrNoAuth), a failing one is a
// denial, a passing one a grant.
func TestOSAuthRunsThePasswordTool(t *testing.T) {
	tool := map[string]string{"darwin": "dscl", "linux": "su"}[runtime.GOOS]
	if tool == "" {
		t.Skip("macOS and Linux only")
	}
	u, err := user.Current()
	if err != nil {
		t.Skip("no current user:", err)
	}
	args := ". -authonly " + u.Username
	if runtime.GOOS == "linux" {
		args = "-c true " + u.Username
	}
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	if err := OSAuth(context.Background(), io.Discard); !errors.Is(err, ErrNoAuth) {
		t.Fatalf("no %s on PATH: got %v, want ErrNoAuth", tool, err)
	}
	stub := filepath.Join(dir, tool)
	for _, c := range []struct {
		script string
		want   func(error) bool
	}{
		{"#!/bin/sh\n[ \"$*\" = \"" + args + "\" ] || exit 9\n", func(e error) bool { return e == nil }},
		{"#!/bin/sh\nexit 1\n", func(e error) bool { return e != nil && !errors.Is(e, ErrNoAuth) }},
	} {
		if err := os.WriteFile(stub, []byte(c.script), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := OSAuth(context.Background(), io.Discard); !c.want(err) {
			t.Errorf("%s stub %q: got %v", tool, c.script, err)
		}
	}
}

// A pass starts the count over: two failures, a pass, two more failures must not close the terminal.
func TestSuOSAuthPassResetsFailures(t *testing.T) {
	root, _ := project(t)
	f := newFakeSu()
	close(f.stop)
	cfg := f.cfg(root)
	f.auth = []error{errors.New("no"), errors.New("no"), nil, errors.New("no"), errors.New("no")}
	var buf bytes.Buffer
	cfg.In, cfg.Out = strings.NewReader("su\nsu\nsu\nsu\nsu\nexit\n"), &buf
	if code := Run(cfg); code != 0 {
		t.Fatalf("exit %d: the pass should have reset the failure count\n%s", code, buf.String())
	}
}

// The Windows switch for sudo: only 1-3 in `reg query`'s output is on; off, missing or garbled is off, so su is unavailable.
func TestSudoEnabledIn(t *testing.T) {
	reg := func(v string) string {
		return "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Sudo\r\n    Enabled    REG_DWORD    " + v + "\r\n\r\n"
	}
	for in, want := range map[string]bool{reg("0x0"): false, reg("0x1"): true, reg("0x3"): true, reg("0x4"): false, reg("zz"): false, "": false} {
		if got := sudoEnabledIn(in); got != want {
			t.Errorf("%q: got %v, want %v", in, got, want)
		}
	}
}
