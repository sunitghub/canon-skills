package main

import (
	"bytes"
	"os"
	"os/exec"
	"slices"
	"strings"
	"testing"
)

// allowedInternalImports is canon-go's package graph: each internal package and the internal packages it may import.
// A deliberate new edge or a new package is one line here, in the same diff, so the reviewer sees it (t-ca0e). Each
// port from tools/sprint and tools/tkt lands as its own package with a row, never a file inside board or daemon.
var allowedInternalImports = map[string][]string{
	"board":      {"artifact", "common", "events", "machine", "settings", "transcript", "walk"},
	"daemon":     {"common", "events", "settings", "term", "transcript"}, // settings: t-393e github.restricted_projects
	"term":       {"events", "settings"},
	"events":     {"machine", "settings"},
	"artifact":   {},
	"common":     {},
	"machine":    {},
	"settings":   {},
	"transcript": {},
	"walk":       {"artifact"},
}

const internalPrefix = "canon/internal/"

const boundaryPattern = "./internal/..."

// TestInternalImportBoundary protects the release binary's build (a board<->daemon cycle would block it) and keeps
// each package small and separately testable. It lists the graph once per release GOOS: a `_windows.go` file's import
// is invisible to a darwin or linux `go list`. Test imports count too: a board test importing daemon is the same edge.
func TestInternalImportBoundary(t *testing.T) {
	for _, goos := range []string{"darwin", "linux", "windows"} {
		checkInternalImports(t, goos)
	}
}

func checkInternalImports(t *testing.T, goos string) {
	t.Helper()
	cmd := exec.Command("go", "list", "-f", "{{.ImportPath}} {{join .Imports \" \"}} {{join .TestImports \" \"}} {{join .XTestImports \" \"}}", boundaryPattern)
	cmd.Dir = "../.."
	cmd.Env = append(os.Environ(), "GOOS="+goos)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("GOOS=%s go list %s failed: %v\n%s", goos, boundaryPattern, err, stderr.String())
	}
	seen := 0
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || !strings.HasPrefix(fields[0], internalPrefix) {
			continue
		}
		seen++
		pkg := strings.TrimPrefix(fields[0], internalPrefix)
		allowed, ok := allowedInternalImports[pkg]
		if !ok {
			t.Errorf("GOOS=%s: package %s has no row: add it to allowedInternalImports in cmd/canon-go/importboundary_test.go", goos, fields[0])
			continue
		}
		for _, imp := range fields[1:] {
			if !strings.HasPrefix(imp, internalPrefix) {
				continue
			}
			if !slices.Contains(allowed, strings.TrimPrefix(imp, internalPrefix)) {
				t.Errorf("GOOS=%s: %s imports %s, which its row does not allow: edit allowedInternalImports in cmd/canon-go/importboundary_test.go", goos, fields[0], imp)
			}
		}
	}
	if seen == 0 {
		t.Fatalf("GOOS=%s go list %s listed no %s package\n%s", goos, boundaryPattern, internalPrefix, stderr.String())
	}
}
