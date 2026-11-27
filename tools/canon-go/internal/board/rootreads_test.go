package board

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// t-f172: the five repo-controlled files are read only through rootLoc or readTicketFile, never a bare os.ReadFile, which
// follows a link out of the project and blocks on a FIFO. This guard covers the scan sites the behavior tests cannot reach
// without worktree fixtures (branch divergence, live docs, worktree holds, the merge list). Protects /api/tickets and /api/handoff.
func TestNoBareReadsOfRepoFiles(t *testing.T) {
	names := map[string]bool{"HANDOFF.md": true, ".worktreeinclude": true, "ticket.md": true, ".cockpit-cwd": true, "AGENTS.md": true}
	files, _ := filepath.Glob("*.go")
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range file.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			named, read := "", token.NoPos
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				switch n := n.(type) {
				case *ast.BasicLit:
					if s, err := strconv.Unquote(n.Value); err == nil && names[s] {
						named = s
					}
				case *ast.CallExpr:
					if sel, ok := n.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "ReadFile" {
						if x, ok := sel.X.(*ast.Ident); ok && x.Name == "os" {
							read = n.Pos()
						}
					}
				}
				return true
			})
			if named != "" && read.IsValid() {
				t.Errorf("%s: %s names %s and calls os.ReadFile: read it through rootLoc or readTicketFile", fset.Position(read), fn.Name.Name, named)
			}
		}
	}
}
