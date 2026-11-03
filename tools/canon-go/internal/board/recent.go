// recent.go — t-2db7: a project's recent stage events (plan approved, gate verdicts, closed, sent, imported, merged) from the
// activity log, for `sprint recent` and a generated block in the main checkout's HANDOFF.md. The block has its own markers, outside
// the narrative's, and is replaced whole; everything else in the file stays byte-identical. A missing HANDOFF.md is never created.
//
//	canon-go recent --project <root> [--n N]                     the lines, newest first
//	canon-go recent --project <root> [--n N] --handoff <file>    rewrite that file's block (insert it when absent)
//	canon-go recent --strip                                       stdin with the block removed, to stdout (merge-pr's check)
package board

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"canon/internal/events"
)

const (
	recentBegin = "<!-- canon:recent:BEGIN -->"
	recentEnd   = "<!-- canon:recent:END -->"
)

// recentKinds are the stage events the block shows; each renders as one phrase.
var recentKinds = map[string]func(d map[string]string) string{
	"plan.approved": func(d map[string]string) string { return "plan approved" + paren(d["tier"]) },
	"gate.finished": func(d map[string]string) string {
		s := d["role"] + " " + orDash(d["verdict"])
		return s + paren(d["model"])
	},
	"sprint.completed":        func(map[string]string) string { return "sprint completed" },
	"github.sent":             func(d map[string]string) string { return "sent to GitHub" + hashN(d["issue"], "issue") },
	"github.results_imported": func(d map[string]string) string { return "cloud results imported" + hashN(d["pr"], "PR") },
	"github.merged":           func(d map[string]string) string { return "merged" + hashN(d["pr"], "PR") },
	"branch.merged":           func(d map[string]string) string { return "merged here" + paren(d["branch"]) }, // t-2906
}

func paren(s string) string {
	if s == "" {
		return ""
	}
	return " (" + s + ")"
}
func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
func hashN(n, what string) string {
	if n == "" {
		return ""
	}
	return " (" + what + " #" + n + ")"
}

type recentLine struct {
	at   time.Time
	seq  int // log order: two events in the same millisecond keep it, newest first
	text string
}

// recentLines are the project's last n stage events, newest first: events whose project is root, a live worktree of it, or a
// folder in <root>-worktrees/ (belongsTo, the Machines node's rule).
func recentLines(home, root string, n int) []string {
	live := map[string]bool{}
	for _, e := range registeredWorktrees(root) {
		live[resolvedOrAbs(fmt.Sprint(e["path"]))] = true
	}
	var all []recentLine
	read := map[string]bool{}
	seq := 0
	for _, p := range events.DayFiles(home) {
		day := strings.TrimSuffix(filepath.Base(p), ".gz")
		if read[day] { // a day with a .gz twin, same lines
			continue
		}
		read[day] = true
		events.EachIn(p, func(ev events.Event) {
			seq++
			render, ok := recentKinds[ev.Kind]
			if !ok || !belongsTo(ev.Project, root, live) {
				return
			}
			t := ev.Data["ticket"]
			if t == "" {
				t = "-"
			}
			all = append(all, recentLine{ev.TS, seq, fmt.Sprintf("%s · %s · %s", ev.TS.Local().Format("01-02 15:04"), t, render(ev.Data))})
		})
	}
	sort.Slice(all, func(i, j int) bool {
		if !all[i].at.Equal(all[j].at) {
			return all[i].at.After(all[j].at)
		}
		return all[i].seq > all[j].seq
	})
	if len(all) > n {
		all = all[:n]
	}
	out := make([]string, len(all))
	for i, l := range all {
		out[i] = l.text
	}
	return out
}

// recentBlock is the block, marker to marker, with nl as the line ending.
func recentBlock(lines []string, nl string) string {
	var b strings.Builder
	b.WriteString(recentBegin + nl + "## Recent activity" + nl + nl)
	b.WriteString("_Written by canon from the activity log at plan approval, sprint close and merge; edits here are replaced._" + nl + nl)
	if len(lines) == 0 {
		b.WriteString("- No stage recorded yet." + nl)
	}
	for _, l := range lines {
		b.WriteString("- " + l + nl)
	}
	b.WriteString(recentEnd + nl)
	return b.String()
}

// stripRecent removes the block (its markers included) and one blank line right after it: the exact inverse of setRecent's insert.
func stripRecent(text string) string {
	i := strings.Index(text, recentBegin)
	if i < 0 {
		return text
	}
	j := strings.Index(text[i:], recentEnd)
	if j < 0 {
		return text
	}
	end := i + j + len(recentEnd)
	for _, nl := range []string{"\r\n", "\n"} {
		if strings.HasPrefix(text[end:], nl) {
			end += len(nl)
			if strings.HasPrefix(text[end:], nl) {
				end += len(nl)
			}
			break
		}
	}
	return text[:i] + text[end:]
}

// setRecent puts the block in text: in place of an old one, else above the narrative's BEGIN marker (one blank line after it), else
// at the end. The line ending follows the file's own.
func setRecent(text string, lines []string) string {
	nl := "\n"
	if strings.Contains(text, "\r\n") {
		nl = "\r\n"
	}
	block := recentBlock(lines, nl)
	if i := strings.Index(text, recentBegin); i >= 0 {
		if j := strings.Index(text[i:], recentEnd); j >= 0 {
			end := i + j + len(recentEnd)
			if strings.HasPrefix(text[end:], nl) {
				end += len(nl)
			}
			return text[:i] + block + text[end:]
		}
	}
	if i := strings.Index(text, "<!-- canon:handoff:BEGIN -->"); i >= 0 {
		return text[:i] + block + nl + text[i:]
	}
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += nl
	}
	return text + block
}

// writeHandoff rewrites file's block; a missing file is left missing (canon never creates a HANDOFF.md), and a link or non-regular
// file is refused. Written through a temp file in the same folder and renamed, keeping the mode.
func writeHandoff(file string, lines []string) error {
	fi, err := os.Lstat(file)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", file)
	}
	old, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	next := setRecent(string(old), lines)
	if next == string(old) {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(file), ".handoff-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(next); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), fi.Mode().Perm()); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), file)
}

// handoffBlockOnly: the checkout's HANDOFF.md differs from HEAD's copy only in canon's Recent activity block (and line endings),
// so a worktree picker never warns that main has uncommitted work canon itself wrote (t-2db7 review). Only an unstaged change.
func handoffBlockOnly(dir, xy string) bool {
	if xy != " M" {
		return false
	}
	work, err := os.ReadFile(filepath.Join(dir, "HANDOFF.md"))
	if err != nil {
		return false
	}
	head, _, err := gitOutIn(dir, 10*time.Second, "show", "HEAD:HANDOFF.md")
	if err != nil {
		return false
	}
	lf := func(s string) string { return strings.ReplaceAll(s, "\r\n", "\n") }
	return lf(stripRecent(string(work))) == lf(stripRecent(head))
}

func recentCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("recent", flag.ContinueOnError)
	fs.SetOutput(stderr)
	project := fs.String("project", "", "")
	n := fs.String("n", "10", "")
	handoff := fs.String("handoff", "", "")
	strip := fs.Bool("strip", false, "")
	usage := "usage: canon-go recent --project <root> [--n N] [--handoff <HANDOFF.md>] | recent --strip < HANDOFF.md"
	if err := fs.Parse(args); err != nil || fs.NArg() > 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	if *strip {
		var buf bytes.Buffer
		if _, err := io.Copy(&buf, stdin); err != nil {
			fmt.Fprintln(stderr, "canon-go recent --strip:", err)
			return 1
		}
		io.WriteString(stdout, stripRecent(buf.String()))
		return 0
	}
	count, err := strconv.Atoi(*n)
	if *project == "" || err != nil || count < 1 || count > 100 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	lines := recentLines(events.Home(), resolvedOrAbs(*project), count)
	if *handoff != "" {
		if err := writeHandoff(*handoff, lines); err != nil {
			fmt.Fprintln(stderr, "canon-go recent:", err)
			return 1
		}
		return 0
	}
	if len(lines) == 0 {
		fmt.Fprintln(stdout, "No stage recorded yet.")
	}
	for _, l := range lines {
		fmt.Fprintln(stdout, l)
	}
	return 0
}
