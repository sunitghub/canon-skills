// Package walk is the pipeline walker (t-2bfe, slice 1 of t-6a4d): it reads the resolved pipeline (`pipeline.sh resolve
// --full`, the one reader of pipeline.yaml) and a ticket folder, and says which node is next and which earlier node was
// passed over. A node's preconditions are every earlier ON node's `produces` (derived from the order, never stored), and
// a `produces` names an internal/artifact rule. Anything it cannot read is an error, never "holds".
package walk

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"

	"canon/internal/artifact"
)

// Node is one row of `pipeline.sh resolve --full`: the 11 original columns, then produces and note ("-" = none).
type Node struct {
	Order, ID, Kind, On, Locked, Group, When, Prompt, Reason, SkipOn, Only, Produces, Note string
}

const (
	columns  = 13
	maxNodes = 200 // pipeline.sh's own cap
	maxLine  = 4096
)

var (
	orderRe = regexp.MustCompile(`^[0-9]+$`)
	idRe    = regexp.MustCompile(`^[a-z][a-z0-9-]{0,39}$`)
)

// Parse reads the resolved pipeline in run order. Empty input, a short or long row, or a value outside its shape is an
// error: a failed resolve must never read as a pipeline with nothing to check.
func Parse(r io.Reader) ([]Node, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, maxLine), maxLine)
	var out []Node
	n := 0
	for sc.Scan() {
		n++
		if len(out) >= maxNodes {
			return nil, fmt.Errorf("pipeline line %d: more than %d nodes", n, maxNodes)
		}
		f := strings.Split(sc.Text(), "\t")
		if len(f) != columns {
			return nil, fmt.Errorf("pipeline line %d: %d columns, want %d (pipeline.sh resolve --full)", n, len(f), columns)
		}
		nd := Node{f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12]}
		switch {
		case !orderRe.MatchString(nd.Order):
			return nil, fmt.Errorf("pipeline line %d: order %q is not a number", n, nd.Order)
		case !idRe.MatchString(nd.ID):
			return nil, fmt.Errorf("pipeline line %d: bad node id %q", n, nd.ID)
		case nd.On != "on" && nd.On != "off":
			return nil, fmt.Errorf("pipeline line %d: node %s: on/off is %q", n, nd.ID, nd.On)
		case nd.Produces != "-" && !artifact.Produces(nd.Produces):
			return nil, fmt.Errorf("pipeline line %d: node %s produces %q, not a rule a node may produce", n, nd.ID, nd.Produces)
		}
		out = append(out, nd)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("pipeline line %d: %w", n+1, err)
	}
	if len(out) == 0 {
		return nil, errors.New("no pipeline on stdin (pipeline.sh resolve --full printed nothing)")
	}
	return out, nil
}

// Ticket is what a ticket's options change in the chain: Lite (`demo: true`) and Manual (`manual: true`).
type Ticket struct{ Demo, Manual bool }

// ReadTicket reads dir/ticket.md's options. A missing frontmatter, or a `demo`/`manual` line the schema refuses (a
// duplicate, not true or false), is an error: a guess could switch a check off. Other fields are not this walk's business.
func ReadTicket(dir string) (Ticket, error) {
	p := filepath.Join(dir, "ticket.md")
	ls, err := artifact.ReadLines(p)
	if err != nil {
		return Ticket{}, err
	}
	fs, _ := artifact.Frontmatter(ls)
	option := map[int]bool{}
	for _, f := range fs {
		option[f.Line] = f.Key == "demo" || f.Key == "manual"
	}
	for _, f := range artifact.Check("ticket.md", []byte(strings.Join(ls, "\n")), "") {
		if f.Rule == "ticket.frontmatter" || (option[f.Line] && (f.Rule == "ticket.key-duplicate" || f.Rule == "ticket.flag")) {
			f.Path = p
			return Ticket{}, errors.New(f.String())
		}
	}
	var t Ticket
	for _, f := range fs {
		v := strings.TrimSpace(f.Raw) == "true"
		switch f.Key {
		case "demo":
			t.Demo = v
		case "manual":
			t.Manual = v
		}
	}
	return t, nil
}

// Active says whether a node is ON for this ticket: on in the project's pipeline, not skipped by the ticket's options,
// and, for a node with `only:`, the ticket has that option. A value it does not know is an error.
func Active(n Node, t Ticket) (bool, error) {
	if n.On == "off" {
		return false, nil
	}
	if n.SkipOn != "-" {
		for _, o := range strings.Split(n.SkipOn, ",") {
			switch o {
			case "lite":
				if t.Demo {
					return false, nil
				}
			case "manual":
				if t.Manual {
					return false, nil
				}
			default:
				return false, fmt.Errorf("node %s: skip_on %q", n.ID, n.SkipOn)
			}
		}
	}
	switch n.Only {
	case "-":
		return true, nil
	case "manual":
		return t.Manual, nil
	}
	return false, fmt.Errorf("node %s: only %q", n.ID, n.Only)
}

// Result is a walk: the earlier ON nodes whose `produces` fails, and the node to do now. Unwalked is true when Next has
// no `produces` of its own (the build): the close side is not walked yet (t-6a4d).
type Result struct {
	Missed   []Node
	Next     Node
	Unwalked bool
}

type checked struct {
	Node
	holds bool
}

// chain is the ticket's ON nodes in order, each checked when its id comes before stop ("" checks them all): `--at` never
// reads its own node's output or a later one's.
func chain(dir string, nodes []Node, stop string) ([]checked, error) {
	t, err := ReadTicket(dir)
	if err != nil {
		return nil, err
	}
	var out []checked
	read := true
	for _, n := range nodes {
		on, err := Active(n, t)
		if err != nil {
			return nil, err
		}
		if !on {
			continue
		}
		if n.ID == stop {
			read = false // this node and every later one are listed, never read
		}
		c := checked{Node: n}
		if n.Produces != "-" && read {
			if c.holds, err = artifact.Holds(dir, n.Produces); err != nil {
				return nil, fmt.Errorf("node %s: %w", n.ID, err)
			}
		}
		out = append(out, c)
	}
	return out, nil
}

// Walk finds the last ON node whose `produces` holds: every checked node before it that fails is missed, and the next
// node is the first checked one after it that fails, else the first unchecked one after it.
func Walk(dir string, nodes []Node) (Result, error) {
	c, err := chain(dir, nodes, "")
	if err != nil {
		return Result{}, err
	}
	last := -1
	for i, n := range c {
		if n.holds {
			last = i
		}
	}
	var r Result
	for _, n := range c[:last+1] {
		if n.Produces != "-" && !n.holds {
			r.Missed = append(r.Missed, n.Node)
		}
	}
	for _, n := range c[last+1:] {
		if n.Produces != "-" {
			r.Next = n.Node
			return r, nil
		}
	}
	if last+1 < len(c) {
		r.Next, r.Unwalked = c[last+1].Node, true
		return r, nil
	}
	return Result{}, errors.New("no ON node after the last one that holds")
}

// Before returns the ON nodes before id whose `produces` fails: what `sprint approve` refuses on. id must be ON.
func Before(dir string, nodes []Node, id string) ([]Node, error) {
	c, err := chain(dir, nodes, id)
	if err != nil {
		return nil, err
	}
	var missed []Node
	for _, n := range c {
		if n.ID == id {
			return missed, nil
		}
		if n.Produces != "-" && !n.holds {
			missed = append(missed, n.Node)
		}
	}
	return nil, fmt.Errorf("node %s is not ON in this pipeline for this ticket", id)
}

// hint is a node's note (with `<id>` filled in), else its prompt, else "-".
func hint(n Node, id string) string {
	switch {
	case n.Note != "-":
		return strings.ReplaceAll(n.Note, "<id>", id)
	case n.Prompt != "-":
		return n.Prompt
	}
	return "-"
}

// Run is `canon-go walk <ticket dir> [--at <node>]`, the pipeline on stdin. Exit 0: printed (or nothing missed before
// --at's node); 1: --at's node has a missed node before it; 2: unreadable input or usage.
func Run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	var dir, at string
	switch {
	case len(args) == 1 && !strings.HasPrefix(args[0], "-"):
		dir = args[0]
	case len(args) == 3 && !strings.HasPrefix(args[0], "-") && args[1] == "--at" && idRe.MatchString(args[2]):
		dir, at = args[0], args[2]
	default:
		fmt.Fprintln(stderr, "usage: canon-go walk <ticket dir> [--at <node id>]   (pipeline.sh resolve --full on stdin)")
		return 2
	}
	id := dir
	if abs, err := filepath.Abs(dir); err == nil {
		id = filepath.Base(abs)
	}
	nodes, err := Parse(stdin)
	if err == nil && at != "" {
		var missed []Node
		if missed, err = Before(dir, nodes, at); err == nil {
			for _, n := range missed {
				fmt.Fprintf(stdout, "missed: %s — %s\n", n.ID, hint(n, id))
			}
			if len(missed) > 0 {
				return 1
			}
			return 0
		}
	}
	if err == nil && at == "" {
		var r Result
		if r, err = Walk(dir, nodes); err == nil {
			for _, n := range r.Missed {
				fmt.Fprintf(stdout, "missed: %s — %s\n", n.ID, hint(n, id))
			}
			fmt.Fprintf(stdout, "next: %s (%s) — %s\n", r.Next.ID, r.Next.Kind, hint(r.Next, id))
			if r.Unwalked {
				fmt.Fprintln(stdout, "then: the close is not walked yet; follow skills/sprint/reference/complete-checklist.md (t-6a4d)")
			}
			return 0
		}
	}
	fmt.Fprintln(stderr, "walk:", err)
	return 2
}
