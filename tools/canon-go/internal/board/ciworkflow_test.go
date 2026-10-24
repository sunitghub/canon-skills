package board

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-04f4: "Set up CI gate" pins the workflow's canon checkout to this install's release tag, and writes nothing when it
// cannot (no release version, or a template without exactly one placeholder).
func TestWriteCIWorkflowPinsCanonRef(t *testing.T) {
	oldRoot, oldTmpl, oldTools, oldVer := projectRoot, canonGateTmpl, toolsDir, version
	defer func() { projectRoot, canonGateTmpl, toolsDir, version = oldRoot, oldTmpl, oldTools, oldVer }()
	install := t.TempDir()
	toolsDir = filepath.Join(install, "tools")
	os.MkdirAll(toolsDir, 0o755)
	canonGateTmpl = filepath.Join(toolsDir, "canon-gate-template.yml")
	dest := func() string { return filepath.Join(projectRoot, ".github", "workflows", "canon-gate.yml") }
	setup := func(tmpl, ver string) {
		projectRoot = t.TempDir()
		os.WriteFile(canonGateTmpl, []byte(tmpl), 0o644)
		os.Remove(filepath.Join(install, "VERSION"))
		if ver != "" {
			os.WriteFile(filepath.Join(install, "VERSION"), []byte(ver+"\n"), 0o644)
		}
		version = "dev"
	}

	setup("ref: __CANON_REF__ # pinned\n", "0.17.0")
	if out := writeCIWorkflow(); out["ok"] != true {
		t.Fatalf("released install: %v", out)
	}
	if b, _ := os.ReadFile(dest()); string(b) != "ref: v0.17.0 # pinned\n" {
		t.Fatalf("written workflow = %q", b)
	}

	for _, ver := range []string{"", "dev", "0.17", "0.17.0-rc1", "v0.17.0"} {
		setup("ref: __CANON_REF__\n", ver)
		out := writeCIWorkflow()
		if out["ok"] != false || !strings.Contains(out["reason"].(string), "no release version") {
			t.Fatalf("version %q: %v, want a refusal", ver, out)
		}
		if _, err := os.Stat(dest()); err == nil {
			t.Fatalf("version %q: a workflow was written", ver)
		}
	}

	for _, tmpl := range []string{"ref: main\n", "ref: __CANON_REF__\nref: __CANON_REF__\n"} {
		setup(tmpl, "0.17.0")
		out := writeCIWorkflow()
		if out["ok"] != false || !strings.Contains(out["reason"].(string), "placeholders, want 1") {
			t.Fatalf("template %q: %v, want a refusal", tmpl, out)
		}
		if _, err := os.Stat(dest()); err == nil {
			t.Fatalf("template %q: a workflow was written", tmpl)
		}
	}
}
