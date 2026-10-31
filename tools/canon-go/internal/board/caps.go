// caps.go — the cap meter (t-19bb). tools/caps.tsv is the one table of capped files and their limits; the units are defined here,
// once, so a test, `sprint` and the board read the same number on every OS (t-0d96: `du` gave the same zip two sizes).
//
//	sprint-check caps [--json] [--table <file>] <name|path> [path]   one row: "<name>: <used> of <limit> <unit>, <N> left" (exit 0),
//	                                                                ", over by <M>" (exit 1); a bad table, file or block exits 2
//	sprint-check caps --list [--table <file>]                       every row with its current use; always exits 0 unless the table is bad
//
// A name or path with no row prints "not capped" and exits 0; a row whose file is absent (a consumer project lacks canon's own
// files) prints "not present" (with --json: {"name","capped":false} and {"name","present":false,"path"}). A caller that enforces
// a cap must require the "left"/"over by" line, never read exit 0 alone as within the cap. --list is information: it exits 0 even
// over a cap. It never edits a file and never raises a cap.
package board

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type capRow struct {
	Name, Path, Unit, Marker string
	Limit                    int64
}

// capUnits maps a unit to the word printed after the numbers.
var capUnits = map[string]string{"words": "words", "block-lines": "lines", "kb": "KB", "files": "files"}

var errCapAbsent = errors.New("not present")

// loadCaps reads the table: `name<TAB>path<TAB>limit<TAB>unit<TAB>marker`, '#' comments and blank lines skipped; path "-" means
// the caller gives it, marker "-" means none (only block-lines needs one).
func loadCaps(file string) ([]capRow, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var rows []capRow
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := sc.Text() // bufio.ScanLines already drops a CRLF line's \r
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		c := strings.Split(line, "\t")
		if len(c) != 5 {
			return nil, fmt.Errorf("%s:%d: want 5 tab-separated columns, got %d", file, n, len(c))
		}
		limit, err := strconv.ParseInt(c[2], 10, 64)
		if err != nil || limit <= 0 {
			return nil, fmt.Errorf("%s:%d: limit %q is not a positive whole number", file, n, c[2])
		}
		if _, ok := capUnits[c[3]]; !ok {
			return nil, fmt.Errorf("%s:%d: unknown unit %q", file, n, c[3])
		}
		if c[3] == "block-lines" && c[4] == "-" {
			return nil, fmt.Errorf("%s:%d: block-lines needs a marker", file, n)
		}
		rows = append(rows, capRow{Name: c[0], Path: c[1], Limit: limit, Unit: c[3], Marker: c[4]})
	}
	return rows, sc.Err()
}

// capWords counts fields separated by ASCII whitespace, as `wc -w` does in the C locale (strings.Fields would also split on
// Unicode spaces such as NBSP and move a cap).
func capWords(b []byte) int64 {
	var n int64
	in := false
	for _, c := range b {
		if c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' {
			in = false
		} else if !in {
			in = true
			n++
		}
	}
	return n
}

// capBlockLines counts the lines strictly between "<!-- <marker>:BEGIN -->" and the next "<!-- <marker>:END -->".
func capBlockLines(b []byte, marker string) (int64, error) {
	begin, end := "<!-- "+marker+":BEGIN -->", "<!-- "+marker+":END -->"
	var n int64
	in, closed := false, false
	for _, l := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		if !in {
			in = strings.Contains(l, begin)
			continue
		}
		if strings.Contains(l, end) {
			closed = true
			break
		}
		n++
	}
	if !closed {
		return 0, fmt.Errorf("no %s ... %s block", begin, end)
	}
	return n, nil
}

// capTree sums the bytes of every regular file under p (symlinks cost nothing, folders cost nothing: never disk blocks) and counts
// them. A folder it cannot read is an error, never a smaller number.
func capTree(p string) (bytes, files int64, err error) {
	err = filepath.WalkDir(p, func(path string, d fs.DirEntry, werr error) error {
		if werr != nil {
			return werr
		}
		if !d.Type().IsRegular() {
			return nil
		}
		info, ierr := d.Info()
		if ierr != nil {
			return ierr
		}
		bytes += info.Size()
		files++
		return nil
	})
	return bytes, files, err
}

func measureCap(r capRow, target string) (int64, error) {
	st, err := os.Stat(target)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, errCapAbsent
	} else if err != nil {
		return 0, err
	}
	if r.Unit == "kb" || r.Unit == "files" {
		if real, err := filepath.EvalSymlinks(target); err == nil { // a path that is a link measures what it points at
			target = real
		}
		b, f, err := capTree(target)
		if r.Unit == "files" {
			return f, err
		}
		return (b + 1023) / 1024, err
	}
	if st.IsDir() {
		return 0, fmt.Errorf("%s is a folder; unit %s needs a file", target, r.Unit)
	}
	b, err := os.ReadFile(target)
	if err != nil {
		return 0, err
	}
	if r.Unit == "words" {
		return capWords(b), nil
	}
	return capBlockLines(b, r.Marker)
}

type capResult struct {
	Name  string `json:"name"`
	Used  int64  `json:"used"`
	Limit int64  `json:"limit"`
	Unit  string `json:"unit"`
	Left  int64  `json:"left"`
	Over  bool   `json:"over"`
}

func (c capResult) line() string {
	if c.Over {
		return fmt.Sprintf("%s: %d of %d %s, over by %d", c.Name, c.Used, c.Limit, c.Unit, c.Used-c.Limit)
	}
	return fmt.Sprintf("%s: %d of %d %s, %d left", c.Name, c.Used, c.Limit, c.Unit, c.Left)
}

// capsCLI is `sprint-check caps`; see the header.
func capsCLI(args []string, stdout, stderr io.Writer) int {
	asJSON, list, table := false, false, ""
	var rest []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			asJSON = true
		case a == "--list":
			list = true
		case a == "--table" && i+1 < len(args):
			i++
			table = args[i]
		case strings.HasPrefix(a, "--"):
			fmt.Fprintf(stderr, "caps: unknown option %s\n", a)
			return 2
		default:
			rest = append(rest, a)
		}
	}
	if (list && len(rest) != 0) || (!list && (len(rest) < 1 || len(rest) > 2)) {
		fmt.Fprintln(stderr, "usage: sprint-check caps [--json] [--table <file>] <name|path> [path] | caps --list [--table <file>]")
		return 2
	}
	if table == "" {
		root := cliCanonRoot()
		if root == "" {
			fmt.Fprintln(stderr, "caps: no canon install found; pass --table <file>")
			return 2
		}
		table = filepath.Join(root, "tools", "caps.tsv")
	}
	rows, err := loadCaps(table)
	if err != nil {
		fmt.Fprintln(stderr, "caps:", err)
		return 2
	}
	project := ""
	if wd, err := os.Getwd(); err == nil {
		project = findProjectRoot(wd)
	}
	if list {
		for _, r := range rows {
			if r.Path == "-" {
				fmt.Fprintf(stdout, "%s: %d %s (the caller gives the path)\n", r.Name, r.Limit, capUnits[r.Unit])
				continue
			}
			res, err := runCap(r, filepath.Join(project, r.Path))
			switch {
			case errors.Is(err, errCapAbsent):
				fmt.Fprintf(stdout, "%s: not present (%s)\n", r.Name, r.Path)
			case err != nil:
				fmt.Fprintf(stdout, "%s: cannot be measured: %v\n", r.Name, err)
			default:
				fmt.Fprintln(stdout, res.line())
			}
		}
		return 0
	}
	row, ok := findCapRow(rows, rest[0], project)
	if !ok {
		if asJSON { // slices t-cc88/t-c990 parse --json: every outcome is JSON there
			b, _ := json.Marshal(map[string]any{"name": rest[0], "capped": false})
			fmt.Fprintln(stdout, string(b))
		} else {
			fmt.Fprintf(stdout, "%s: not capped\n", rest[0])
		}
		return 0
	}
	target := filepath.Join(project, row.Path)
	if len(rest) == 2 {
		target = rest[1]
	} else if row.Path == "-" {
		fmt.Fprintf(stderr, "caps: %s needs a path (the table leaves it to the caller)\n", row.Name)
		return 2
	}
	res, err := runCap(row, target)
	if errors.Is(err, errCapAbsent) {
		if asJSON {
			b, _ := json.Marshal(map[string]any{"name": row.Name, "present": false, "path": target})
			fmt.Fprintln(stdout, string(b))
		} else {
			fmt.Fprintf(stdout, "%s: not present (%s)\n", row.Name, target)
		}
		return 0
	} else if err != nil {
		fmt.Fprintf(stderr, "caps: %s: %v\n", row.Name, err)
		return 2
	}
	if asJSON {
		b, _ := json.Marshal(res)
		fmt.Fprintln(stdout, string(b))
	} else {
		fmt.Fprintln(stdout, res.line())
	}
	if res.Over {
		return 1
	}
	return 0
}

func runCap(r capRow, target string) (capResult, error) {
	used, err := measureCap(r, target)
	if err != nil {
		return capResult{}, err
	}
	return capResult{Name: r.Name, Used: used, Limit: r.Limit, Unit: capUnits[r.Unit], Left: r.Limit - used, Over: used > r.Limit}, nil
}

// findCapRow matches a row by name, else by its path (as given, or relative to the project root).
func findCapRow(rows []capRow, arg, project string) (capRow, bool) {
	for _, r := range rows {
		if r.Name == arg {
			return r, true
		}
	}
	abs := resolvedOrAbs(arg) // symlinks resolved on both sides: macOS's /var is /private/var
	for _, r := range rows {
		if r.Path != "-" && (filepath.Clean(arg) == filepath.Clean(r.Path) || abs == resolvedOrAbs(filepath.Join(project, r.Path))) {
			return r, true
		}
	}
	return capRow{}, false
}
