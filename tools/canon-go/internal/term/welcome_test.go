package term

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Protects the welcome from lying: every tkt line is labelled the way the prompt really treats it, every read-only tkt
// command is listed, every command that needs su is a real tkt subcommand, and the other lines name real commands.
func TestWelcomeMatchesThePrompt(t *testing.T) {
	subs := tktHelp(t)
	real := map[string]bool{}
	for _, s := range subs {
		real[s] = true
	}
	listedRO := map[string]bool{}
	for _, e := range welcomeEntries {
		w := strings.Fields(e.cmd)
		if w[0] != "tkt" {
			switch w[0] {
			case "help", "clear", "pwd", "ls", "cat", "su", "exit":
				if e.su {
					t.Errorf("%q cannot need su", e.cmd)
				}
			default:
				t.Errorf("%q is not a command of this prompt", e.cmd)
			}
			continue
		}
		sub := w[1]
		switch {
		case sub == "--help":
			if e.su {
				t.Errorf("tkt --help runs here")
			}
		case e.su:
			if readOnlyTkt[sub] || runTkt[sub] {
				t.Errorf("%q says it needs su but the prompt runs it", e.cmd)
			}
			if !real[sub] {
				t.Errorf("%q is not a tkt command (see tkt --help)", e.cmd)
			}
		default:
			if !readOnlyTkt[sub] && !runTkt[sub] {
				t.Errorf("%q says you can run it but the prompt refuses it", e.cmd)
			}
			listedRO[sub] = true
		}
	}
	for _, ro := range append(ReadOnlyTkt(), RunTkt()...) {
		if !listedRO[ro] {
			t.Errorf("tkt %q runs here without su and is not in the welcome", ro)
		}
	}
}

// Protects what the user sees: the welcome opens the prompt and comes back on help, with the name and both sections.
func TestWelcomeOnStartAndHelp(t *testing.T) {
	root, _ := project(t)
	out := run(t, Config{Root: root}, "help\nexit\n")
	if n := strings.Count(out, "Welcome to "+Name); n != 2 {
		t.Errorf("the welcome should show at the start and on help, shown %d times", n)
	}
	for _, want := range []string{"You can run", "Needs su (type su first, then the OS approval)", "tkt create [title] -d <desc> -p <0-4>", "tkt send-issue <id> [--dry-run] [--launch]", "tkt import-issue <issue number>"} {
		if !strings.Contains(out, want) {
			t.Errorf("the welcome lacks %q:\n%s", want, out)
		}
	}
	if strings.Index(out, "You can run") > strings.Index(out, "Needs su") {
		t.Error("the commands you can run come first")
	}
}

// Protects cat's paging: a long file stops after a screenful, Enter shows the next, q stops; a short file shows at once.
func TestCatPages(t *testing.T) {
	root, _ := project(t)
	var long strings.Builder
	for i := 1; i <= 12; i++ {
		fmt.Fprintf(&long, "line%02d\n", i)
	}
	if err := os.WriteFile(filepath.Join(root, "long.zzz"), []byte(long.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "short.zzz"), []byte("a\nb\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Config{Root: root, Rows: func() int { return 6 }} // 5 lines a page
	out := run(t, cfg, "cat long.zzz\n\nq\nexit\n")
	if !strings.Contains(out, "line05\n") || !strings.Contains(out, "(7 lines left)") || strings.Index(out, "line06") < strings.Index(out, "(7 lines left)") {
		t.Errorf("the first page should stop after 5 lines:\n%s", out)
	}
	if !strings.Contains(out, "line10") || strings.Contains(out, "line11") {
		t.Errorf("Enter should show the next page and q should stop before line11:\n%s", out)
	}
	if n := strings.Count(out, "-- more"); n != 2 {
		t.Errorf("want 2 prompts, got %d:\n%s", n, out)
	}
	// Short files are not paged; end of input at the prompt stops too; a missing Rows means 24 lines a page.
	if out := run(t, cfg, "cat short.zzz\nexit\n"); strings.Contains(out, "-- more") {
		t.Errorf("a short file should not be paged:\n%s", out)
	}
	if out := run(t, cfg, "cat long.zzz\n"); !strings.Contains(out, "(7 lines left)") || strings.Contains(out, "line06") {
		t.Errorf("end of input at the prompt should stop:\n%s", out)
	}
	if out := run(t, Config{Root: root}, "cat long.zzz\nexit\n"); strings.Contains(out, "-- more") || !strings.Contains(out, "line12") {
		t.Errorf("12 lines fit in the default 24:\n%s", out)
	}
	tiny := Config{Root: root, Rows: func() int { return 2 }} // never fewer than 5 lines a page
	if out := run(t, tiny, "cat long.zzz\nq\nexit\n"); !strings.Contains(out, "line05\n") || strings.Contains(out, "line06") {
		t.Errorf("a tiny terminal should still page 5 lines:\n%s", out)
	}
}

// tkt --help runs in the restricted prompt (read-only), through the real tkt path.
func TestTktHelpRuns(t *testing.T) {
	root, _ := project(t)
	fake := filepath.Join(t.TempDir(), "tkt")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\necho \"ran:$*\"\n"), 0o755); err != nil {
		t.Skip("cannot write a stand-in tkt")
	}
	if out := run(t, Config{Root: root, Tkt: fake}, "tkt --help\nexit\n"); !strings.Contains(out, "ran:--help") {
		t.Errorf("tkt --help should run:\n%s", out)
	}
}
