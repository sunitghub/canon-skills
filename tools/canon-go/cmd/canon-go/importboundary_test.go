package main

import (
	"bytes"
	"os/exec"
	"slices"
	"strings"
	"testing"
)

// allowedInternalImports is canon-go's package graph: each internal package and the internal packages it may import.
// A deliberate new edge or a new package is one line here, in the same diff, so the reviewer sees it (t-ca0e). Each
// port from tools/sprint and tools/tkt lands as its own package with a row, never a file inside board or daemon.
var allowedInternalImports = map[string][]string{
	"board":      {"common", "events", "machine", "settings", "transcript"},
	"daemon":     {"common", "events", "term", "transcript"},
	"term":       {"events", "settings"},
	"events":     {"machine", "settings"},
	"common":     {},
	"machine":    {},
	"settings":   {},
	"transcript": {},
}

const internalPrefix = "canon/internal/"

var boundaryPattern = "./internal/..."

// TestInternalImportBoundary protects the release binary's build (a board<->daemon cycle would block it) and keeps
// each package small and separately testable.
func TestInternalImportBoundary(t *testing.T) {
	cmd := exec.Command("go", "list", "-f", "{{.ImportPath}} {{join .Imports \" \"}}", boundaryPattern)
	cmd.Dir = "../.."
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("go list %s failed: %v\n%s", boundaryPattern, err, stderr.String())
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
			t.Errorf("package %s has no row: add it to allowedInternalImports in cmd/canon-go/importboundary_test.go", fields[0])
			continue
		}
		for _, imp := range fields[1:] {
			if !strings.HasPrefix(imp, internalPrefix) {
				continue
			}
			dep := strings.TrimPrefix(imp, internalPrefix)
			if !slices.Contains(allowed, dep) {
				t.Errorf("%s imports %s, which its row does not allow: edit allowedInternalImports in cmd/canon-go/importboundary_test.go", fields[0], imp)
			}
		}
	}
	if seen == 0 {
		t.Fatalf("go list %s listed no %s package\n%s", boundaryPattern, internalPrefix, stderr.String())
	}
}
