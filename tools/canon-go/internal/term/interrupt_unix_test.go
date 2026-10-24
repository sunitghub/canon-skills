//go:build !windows

package term

import (
	"bytes"
	"io"
	"os"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// Protects the session against a Ctrl-C while a command runs: the SIGINT goes to the whole foreground group, and the
// prompt must carry on (it used to end the Terminal).
func TestPromptSurvivesInterrupt(t *testing.T) {
	root, _ := project(t)
	pr, pw := io.Pipe()
	var out bytes.Buffer
	var mu sync.Mutex
	done := make(chan int, 1)
	go func() { done <- Run(Config{Root: root, In: pr, Out: &lockedWriter{&mu, &out}}) }()
	time.Sleep(200 * time.Millisecond)
	if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	pw.Write([]byte("?\nexit\n"))
	if code := <-done; code != 0 {
		t.Fatalf("Run returned %d", code)
	}
	mu.Lock()
	defer mu.Unlock()
	if strings.Count(out.String(), "Welcome to Canon Console") != 2 {
		t.Errorf("the prompt should still answer after a SIGINT:\n%s", out.String())
	}
}

type lockedWriter struct {
	mu *sync.Mutex
	b  *bytes.Buffer
}

func (w *lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}
