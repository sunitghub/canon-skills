//go:build !windows

package term

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	gopty "github.com/aymanbagabas/go-pty"
)

// TestMain lets the test binary run the restricted prompt itself, so the end-to-end test below can put it on a real pty.
func TestMain(m *testing.M) {
	if os.Getenv("CANON_TERM_TEST_CHILD") == "1" {
		os.Exit(Main(os.Args[2:])) // os.Args[1] is "term", as the daemon strips it
	}
	os.Exit(m.Run())
}

// Protects the real thing on a real pty: the prompt, the typed word, a login shell that owns the terminal, no daemon
// secrets inside it, the warning, the end of the shell and its jobs, the restricted prompt coming back, and exactly the
// three audit events with the word in none of them.
func TestRealPtySession(t *testing.T) {
	root, _ := project(t)
	home := t.TempDir()
	p, err := gopty.New()
	if err != nil {
		t.Skip("no pty here:", err)
	}
	defer p.Close()
	c := p.Command(os.Args[0], "term", "--session", "sidx", "--ticket", "s-ab12", "--project", root, "--limit", "4s", "--warn", "2s")
	c.Dir = root
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=/bin/sh", "CANON_HOME=" + home, "CANON_TERM_TEST_CHILD=1", "ENV=", "PS1=sh$ "}
	c.Env = env
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	out := &safeBuf{}
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := p.Read(buf)
			if n > 0 {
				_, _ = out.Write(buf[:n])
			}
			if err != nil {
				return
			}
		}
	}()
	send := func(s string) { _, _ = p.Write([]byte(s)) }
	wait := func(re string, d time.Duration) string {
		t.Helper()
		r := regexp.MustCompile(re)
		end := time.Now().Add(d)
		for time.Now().Before(end) {
			if m := r.FindString(out.String()); m != "" {
				return m
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("timed out waiting for %q; output:\n%s", re, out.String())
		return ""
	}
	wait(`restricted`, 10*time.Second)
	send("ls\n")
	wait(`a\.go`, 5*time.Second)
	send("cat .env\n")
	wait(`never shown`, 5*time.Second)
	send("su\n")
	word := strings.TrimSuffix(strings.TrimPrefix(wait(`Type [A-Z][a-z2-9]{4} to continue`, 5*time.Second), "Type "), " to continue")
	send(word + "\n")
	time.Sleep(700 * time.Millisecond)
	send("echo shell-$((20+22))-${COCKPIT_TOKEN:-none}\n")
	wait(`shell-42-none`, 5*time.Second)
	send("sleep 300 &\n")
	time.Sleep(200 * time.Millisecond)
	send("echo bgpid=$!\n")
	var bg int
	for _, ch := range wait(`bgpid=\d+`, 5*time.Second)[6:] {
		bg = bg*10 + int(ch-'0')
	}
	wait(`full shell ends in`, 6*time.Second)
	wait(`time is up`, 6*time.Second)
	send("rm x\n")
	wait(`not allowed here: rm`, 5*time.Second)
	time.Sleep(300 * time.Millisecond)
	if st := procState(bg); st != "" && st != "Z" {
		t.Errorf("the background program (pid %d) is still running (state %s) after the shell ended", bg, st)
	} else if st == "" {
		if err := syscall.Kill(bg, 0); err == nil {
			t.Errorf("the background program (pid %d) is still alive", bg)
		}
	}
	send("exit\n")
	if err := c.Wait(); err != nil {
		t.Errorf("exit status: %v", err)
	}
	var events string
	files, _ := filepath.Glob(filepath.Join(home, "events", "*.jsonl"))
	for _, f := range files {
		b, _ := os.ReadFile(f)
		events += string(b)
	}
	kinds := regexp.MustCompile(`"kind":"(terminal\.[a-z_]+)"`).FindAllStringSubmatch(events, -1)
	var got []string
	for _, k := range kinds {
		got = append(got, k[1])
	}
	if strings.Join(got, " ") != "terminal.su_prompted terminal.su_granted terminal.su_expired" {
		t.Errorf("events %v\n%s", got, events)
	}
	if strings.Contains(events, word) {
		t.Error("the typed word is in the event log")
	}
}

// procState is the process state letter from /proc, or "" when there is no such process or no /proc (macOS).
func procState(pid int) string {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return ""
	}
	s := string(b)
	i := strings.LastIndex(s, ")")
	if i < 0 || i+2 >= len(s) {
		return ""
	}
	return string(s[i+2])
}

// Protects the three tries on the real thing: three wrong answers end the process itself, with exit status 1, and the
// shell is never started.
func TestRealPtyThreeWrongAnswersClose(t *testing.T) {
	root, _ := project(t)
	home := t.TempDir()
	p, err := gopty.New()
	if err != nil {
		t.Skip("no pty here:", err)
	}
	defer p.Close()
	c := p.Command(os.Args[0], "term", "--session", "sidy", "--ticket", "s-ab12", "--project", root)
	c.Dir = root
	c.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=/bin/sh", "CANON_HOME=" + home, "CANON_TERM_TEST_CHILD=1"}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	out := &safeBuf{}
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := p.Read(buf)
			if n > 0 {
				_, _ = out.Write(buf[:n])
			}
			if err != nil {
				return
			}
		}
	}()
	waitFor(t, func() bool { return strings.Contains(out.String(), "Welcome to Canon Console") })
	for i := 0; i < 3; i++ {
		_, _ = p.Write([]byte("su\n"))
		waitFor(t, func() bool { return strings.Count(out.String(), "to continue (Enter cancels)") > i })
		_, _ = p.Write([]byte("Zz999\n"))
		_, _ = p.Write([]byte("\n")) // cancel any retry prompt so the next su starts clean
		if strings.Contains(out.String(), "closing the terminal") {
			break
		}
	}
	waitFor(t, func() bool { return strings.Contains(out.String(), "closing the terminal") })
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case err := <-done:
		if err == nil {
			t.Error("the closed terminal should exit with status 1")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the terminal did not close after three wrong answers")
	}
	files, _ := filepath.Glob(filepath.Join(home, "events", "*.jsonl"))
	var events string
	for _, f := range files {
		b, _ := os.ReadFile(f)
		events += string(b)
	}
	if strings.Contains(events, "su_granted") || !strings.Contains(events, `"reason":"locked"`) {
		t.Errorf("events:\n%s", events)
	}
}

// Protects the restricted prompt after a su shell that left the terminal in raw, no-echo mode and was then ended by the
// time limit: the prompt must get its modes back, or the next line would not be read as a line.
func TestRealPtyModesRestoredAfterShellKilled(t *testing.T) {
	root, _ := project(t)
	home := t.TempDir()
	p, err := gopty.New()
	if err != nil {
		t.Skip("no pty here:", err)
	}
	defer p.Close()
	c := p.Command(os.Args[0], "term", "--session", "sidm", "--ticket", "s-ab12", "--project", root, "--limit", "3s", "--warn", "1s")
	c.Dir = root
	c.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=/bin/sh", "CANON_HOME=" + home, "CANON_TERM_TEST_CHILD=1", "ENV=", "PS1=sh$ "}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	out := &safeBuf{}
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := p.Read(buf)
			if n > 0 {
				_, _ = out.Write(buf[:n])
			}
			if err != nil {
				return
			}
		}
	}()
	send := func(s string) { _, _ = p.Write([]byte(s)) }
	wait := func(re string, d time.Duration) string {
		t.Helper()
		r := regexp.MustCompile(re)
		end := time.Now().Add(d)
		for time.Now().Before(end) {
			if m := r.FindString(out.String()); m != "" {
				return m
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("timed out waiting for %q; output:\n%s", re, out.String())
		return ""
	}
	wait(`restricted`, 10*time.Second)
	send("su\n")
	word := strings.TrimSuffix(strings.TrimPrefix(wait(`Type [A-Z][a-z2-9]{4} to continue`, 5*time.Second), "Type "), " to continue")
	send(word + "\n")
	time.Sleep(700 * time.Millisecond)
	send("stty raw -echo -icrnl; sleep 100\n")
	wait(`time is up`, 8*time.Second)
	time.Sleep(300 * time.Millisecond)
	send("xqzjk") // echo is the visible mode: it was switched off in the shell and must be back on
	wait(`xqzjk`, 3*time.Second)
	send("\n")
	send("exit\n")
	_ = c.Wait()
}

// Protects cat against a file that is not a regular one: a FIFO would block the prompt forever on open.
func TestCatRefusesFifo(t *testing.T) {
	root, _ := project(t)
	if err := syscall.Mkfifo(filepath.Join(root, "pipe.txt"), 0o600); err != nil {
		t.Skip("no fifo here:", err)
	}
	done := make(chan error, 1)
	go func() { _, _, err := readFile(root, "pipe.txt"); done <- err }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Errorf("err = %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("cat blocked on a FIFO")
	}
}
