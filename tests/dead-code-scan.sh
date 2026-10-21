#!/usr/bin/env bash
# dead-code-scan (t-271a) — tools/dead-code-scan.sh, the scan behind skills/dead-code-cleanup, on a fixture repo with
# one symbol per case: dead Bash in an extensionless shebang script (its only other mentions in a doc, a CHANGELOG and a
# comment), a Bash helper called through `source`, a test-only caller, an over-export, an export used in its own file
# that a test also imports (live: the test needs the export), unexported
# Go, Go in main.go, Python, and a .rs file it must list as skipped. Also: tools/upkeep-run hands the headless dispatch
# exactly that scan command. Protects the shipped dead-code-cleanup scan and `upkeep-run dead-code-cleanup`.

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
EOF
cat > tools/lib.sh <<'EOF'
lib_helper() { :; }
test_only_fn() { :; }
EOF
cat > tests/t.sh <<'EOF'
source ../tools/lib.sh
test_only_fn
helper_in_test() { :; }
used_test_helper() { :; }
used_test_helper
EOF
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
cat > pkg/a.go <<'EOF'
package pkg

func unusedLower() {}
func usedLower()   {}
func Exported()    { usedLower() }
EOF
printf 'package pkg\n\nvar _ = Exported\n' > pkg/b.go
printf 'package pkg\n\nfunc TestThing(t *T) {}\n' > pkg/a_test.go
cat > cmd/main.go <<'EOF'
package main

func main()           {}
func helperInMain()   {}
func ExportedInMain() {}
EOF
printf 'def py_dead():\n    pass\n\ndef _private():\n    pass\n' > app/util.py
printf 'fn x() {}\n' > src/lib.rs
git add -A

out="$(bash "$SCAN")"
got="$(grep -v '^#' <<<"$out" | awk -F'\t' '{ print $1, $3, $5 }' | sort)"
want="$(sort <<'EOF'
DEAD ensure_file -
DEAD helper_in_test -
DEAD unusedLower -
DEAD helperInMain -
DEAD ExportedInMain entry
DEAD py_dead -
TESTONLY test_only_fn -
TESTONLY tested -
OVEREXP rowFor -
EOF
)"
assert_eq "$want" "$got" "dead-code-scan: candidate rows"
assert_contains "$out" "$(printf 'DEAD\ttools/build:3\tensure_file\tsh')" "dead-code-scan: file:line and lang"
assert_contains "$out" "$(printf 'TESTONLY\ttools/lib.sh:2\ttest_only_fn\tsh\t-\ttests/t.sh')" "dead-code-scan: test-only refs name the test file"
assert_contains "$out" "# scanned: js,py,go,sh" "dead-code-scan: scanned languages"
assert_contains "$out" "# skipped: .rs=1" "dead-code-scan: an unscanned source language is named, with its file count"

# A pathspec narrows the scope, references included: outside static/, the test that imports `tested` is not seen.
scoped="$(bash "$SCAN" static)"
assert_eq "$(printf 'DEAD tested\nOVEREXP rowFor\nOVEREXP ownAndTest')" "$(grep -v '^#' <<<"$scoped" | awk -F'\t' '{ print $1, $3 }')" "dead-code-scan: pathspec scope"

# Outside a git repo: refuse, never scan an unbounded path.
mkdir "$W/plain"
set +e; err="$(cd "$W/plain" && bash "$SCAN" 2>&1)"; code=$?; set -e
assert_eq "2" "$code" "dead-code-scan: exit code outside a git repo"
assert_contains "$err" "not a git repository" "dead-code-scan: says why it refused"

# upkeep-run gives the headless dispatch exactly this install's scan command, and no generic Bash.
U="$W/upkeep-root"
mkdir -p "$U/skills/dead-code-cleanup" "$W/fakebin"
cp "$ROOT/skills/dead-code-cleanup/SKILL.md" "$U/skills/dead-code-cleanup/"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/claude-args.log"\nexit 0\n' "$W" > "$W/fakebin/claude"
chmod +x "$W/fakebin/claude"
PATH="$W/fakebin:$PATH" "$ROOT/tools/upkeep-run" dead-code-cleanup --root "$U" >/dev/null 2>&1 || true
assert_file_exists "$W/claude-args.log"
grep -qxF "Bash(bash $ROOT/tools/dead-code-scan.sh)" "$W/claude-args.log" || fail "upkeep-run: scan command not in --allowedTools"
[[ "$(grep -c '^Bash(bash' "$W/claude-args.log")" == 1 ]] || fail "upkeep-run: more than the one scan command allowed"
grep -qF "Run its scanner as exactly this command, with no arguments: bash $ROOT/tools/dead-code-scan.sh" "$W/claude-args.log" \
  || fail "upkeep-run: prompt does not name the scan command"

echo "dead-code-scan: ok"
