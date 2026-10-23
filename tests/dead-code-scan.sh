#!/usr/bin/env bash
# dead-code-scan (t-271a) — tools/dead-code-scan.sh, the scan behind skills/dead-code-cleanup, on a fixture repo with
# one symbol per case: dead Bash in an extensionless shebang script (its only other mentions in a doc, a CHANGELOG and a
# comment), a Bash helper called through `source`, a test-only caller, an over-export, an export used in its own file
# that a test also imports (live: the test needs the export), unexported
# Go and Go init, Go in main.go, Python, test files outside tests/, each entry-point pattern, CRLF and non-ASCII paths,
# and .cs/.rs files it must list as skipped; plus a pathspec, an empty scope and a run from a subdirectory.
# Protects the shipped dead-code-cleanup scan.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

SCAN="$ROOT/tools/dead-code-scan.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/dead-code-scan-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

R="$W/repo"
mkdir -p "$R"/{tools,tests,static,pkg,cmd,app,src,docs}
cd "$R"
git init -q .

cat > tools/build <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
ensure_file() { :; }
used_here() { :; }
used_here
# ensure_file is legacy
lib_helper x
dup_fn
EOF
cat > tools/lib.sh <<'EOF'
lib_helper() { :; }
test_only_fn() { :; }
dup_fn() { :; }
function kw_dead {
  :
}
EOF
cat > tests/t.sh <<'EOF'
source ../tools/lib.sh
test_only_fn
helper_in_test() { :; }
used_test_helper() { :; }
used_test_helper
EOF
printf 'test_only_fn\n' > tests/t2.sh
printf '#!/usr/bin/env python3\nnot_bash() {\n' > tools/pyrun
printf '# Changelog\n- ensure_file was kept\n' > CHANGELOG.md
printf 'Call ensure_file to make a file.\n' > docs/notes.md
cat > static/view.js <<'EOF'
export function rowFor(r) { return r; }
export function shared(x) { return x; }
export const tested = 1;
export function ownAndTest(x) { return x; }
const v = rowFor(ownAndTest(1));
EOF
printf "import { shared } from './view.js';\nshared(1);\n" > static/app.js
printf "import { tested, ownAndTest } from '../static/view.js';\n" > tests/view.test.js
printf 'export function idxDead() {}\n' > static/index.js
printf 'export function cliDead() {}\n' > static/cli.js
printf 'export function fmtTested() {}\n' > static/fmt.js
printf "import { fmtTested } from './fmt.js';\n" > static/fmt.spec.js
cat > pkg/a.go <<'EOF'
package pkg

func unusedLower() {}
func usedLower()   {}
func Exported()    { usedLower() }
func init()        {}
func goTestOnly()  {}
EOF
printf 'package pkg\n\nvar _ = Exported\n' > pkg/b.go
printf 'package pkg\n\nfunc TestThing(t *T) { goTestOnly() }\n' > pkg/a_test.go
cat > cmd/main.go <<'EOF'
package main

func main()           {}
func helperInMain()   {}
func ExportedInMain() {}
EOF
printf 'def py_dead():\n    pass\n\ndef _private():\n    pass\n\ndef py_tested():\n    pass\n\ndef py_tested2():\n    pass\n\nclass Helper:\n    pass\n\nh = Helper()\n' > app/util.py
printf 'py_tested()\n' > app/test_util.py
printf 'py_tested2()\n' > app/util2_test.py
printf 'def init_dead():\n    pass\n' > app/__init__.py
printf '#!/usr/bin/env python3\ndef run_dead():\n    pass\n' > app/run.py
printf 'class Main {}\n' > src/Main.cs
printf 'fn x() {}\n' > src/lib.rs
# A CRLF checkout (Git for Windows autocrlf) is still Bash; a non-ASCII path is still read.
printf '#!/usr/bin/env bash\r\ncrlf_dead() { :; }\r\n' > tools/crlf
cafe=$'static/caf\303\251'; mkdir -p "$cafe" && printf 'used_from_cafe\n' > "$cafe/call.sh"
# The same name declared twice: grep cannot tell the copies apart, so a call keeps both live.
printf 'used_from_cafe() { :; }\ndup_fn() { :; }\n' > tools/cafe-lib.sh
printf '#!/usr/bin/env bash\nnot_stdin() { :; }\n' > ./-   # a file named "-" is read, not stdin
git add -A

mkdir "$W/tmp"
out="$(TMPDIR="$W/tmp" bash "$SCAN")"
[[ -z "$(ls -A "$W/tmp")" ]] || fail "dead-code-scan: left a temp file behind"
assert_eq "$out" "$(cd tools && bash "$SCAN")" "dead-code-scan: same result from a subdirectory"
got="$(grep -v '^#' <<<"$out" | awk -F'\t' '{ print $1, $3, $5 }' | sort)"
want="$(sort <<'EOF'
DEAD ensure_file -
DEAD crlf_dead -
DEAD helper_in_test -
DEAD unusedLower -
DEAD helperInMain -
DEAD ExportedInMain entry
DEAD py_dead -
DEAD kw_dead -
DEAD not_stdin -
DEAD init_dead entry
DEAD run_dead entry
DEAD idxDead entry
DEAD cliDead entry
TESTONLY test_only_fn -
TESTONLY tested -
TESTONLY fmtTested -
TESTONLY goTestOnly -
TESTONLY py_tested -
TESTONLY py_tested2 -
OVEREXP rowFor -
EOF
)"
assert_eq "$want" "$got" "dead-code-scan: candidate rows"
assert_contains "$out" "$(printf 'DEAD\ttools/build:3\tensure_file\tsh\t-\t-\n')" "dead-code-scan: file:line and lang"
assert_contains "$out" "$(printf 'TESTONLY\ttools/lib.sh:2\ttest_only_fn\tsh\t-\ttests/t.sh tests/t2.sh\n')" "dead-code-scan: test-only refs name the test file"
assert_contains "$out" "# scanned: js,py,go,sh" "dead-code-scan: scanned languages"
assert_contains "$out" "# skipped: .cs=1 .rs=1" "dead-code-scan: an unscanned source language is named, with its file count"

# A pathspec narrows the scope, references included: outside static/, the test that imports `tested` is not seen.
scoped="$(bash "$SCAN" static)"
assert_eq "$(printf 'DEAD cliDead\nDEAD idxDead\nDEAD tested\nOVEREXP ownAndTest\nOVEREXP rowFor\nTESTONLY fmtTested')" \
  "$(grep -v '^#' <<<"$scoped" | awk -F'\t' '{ print $1, $3 }' | sort)" "dead-code-scan: pathspec scope"

# A scope with no source: no rows, and every summary line still printed.
assert_eq "$(printf '# scanned: none\n# skipped: none\n# checked: 0 declarations')" "$(bash "$SCAN" docs)" "dead-code-scan: empty scope"

# Outside a git repo: refuse, never scan an unbounded path.
mkdir "$W/plain"
set +e; err="$(cd "$W/plain" && bash "$SCAN" 2>&1)"; code=$?; set -e
assert_eq "2" "$code" "dead-code-scan: exit code outside a git repo"
assert_contains "$err" "not a git repository" "dead-code-scan: says why it refused"

echo "dead-code-scan: ok"
