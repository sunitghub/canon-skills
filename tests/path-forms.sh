#!/usr/bin/env bash
# tests/path-forms.sh — t-141a: one folder, several spellings (C:\x, C:/x, /c/x, case, separators), compared by KEY, never as raw text.
# Prod path: tools/platform-lib.sh `canon_path_key` (the one definition, also the awk text `canon_awk_pkey` that `sprint token-spend` matches a
# sprint's events to a transcript's cwd with). This file protects three things:
#   1. the corpus tests/fixtures/path-keys.tsv obeys its own rules, and its validator rejects a tab-to-spaces edit, a repeat, a padded field;
#   2. every corpus row (including the rows marked NOT handled) gives its key, and the key is a pure function: the same answer when `uname`
#      says Windows and `cygpath` is broken, so it can be tested on any OS (research report section 4.2);
#   3. `sprint token-spend` still finds a sprint when git lists the worktree as C:/..., the events name it C:\..., and the transcript's cwd is
#      /c/...: the guard t-134b's evaluator found missing (removing the path-list normalisation left every other test green on a Mac).
# A Windows-only symptom is reproduced here with the corpus before it is fixed. Run it once on a machine that is not a Mac as well.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$ROOT/tools/platform-lib.sh"

corpus="$ROOT/tests/fixtures/path-keys.tsv"

# validate_corpus <file> — prints each broken rule and returns 1: exactly two tabs per line, no field empty or padded with a space, every input unique,
# at least 25 rows. (A tab-to-spaces edit leaves one field and fails the first rule.)
validate_corpus() {
  awk -F'\t' '
    /^#/ || /^$/ { next }
    { rows++ }
    NF != 3 { print "line " NR ": " NF - 1 " tabs, want 2"; bad = 1; next }
    { for (i = 1; i <= 3; i++) if ($i == "" || $i ~ /^ / || $i ~ / $/) { print "line " NR ": field " i " is empty or padded with a space"; bad = 1 }
      if ($1 in SEEN) { print "line " NR ": input repeated: " $1; bad = 1 }
      SEEN[$1] = 1 }
    END { if (rows < 25) { print "only " rows " rows, want at least 25"; bad = 1 }; exit bad }
  ' "$1"
}

msg="$(validate_corpus "$corpus")" || fail "path-forms: the corpus breaks its own rules: $msg"

# The validator rejects what it must (a guard is proved by the inputs it refuses).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" "${proj:-}" "${cfg:-}" "${chome:-}" "${shim:-}"' EXIT
tab=$'\t'   # BSD sed does not read \t as a tab
for kind in spaces repeat padded empty; do
  case "$kind" in
    spaces) sed "8s/$tab/    /g" "$corpus" ;;                       # a tab-to-spaces edit of one row
    repeat) { cat "$corpus"; grep -v '^#' "$corpus" | sed -n 1p; } ;;   # the first input again
    padded) sed "8s/$tab/ $tab/" "$corpus" ;;                      # a space after the input
    empty)  sed "8s/${tab}[^${tab}]*${tab}/${tab}${tab}/" "$corpus" ;;       # an empty key
  esac > "$tmp/$kind.tsv"
  cmp -s "$corpus" "$tmp/$kind.tsv" && fail "path-forms: the '$kind' variant is identical to the corpus: the edit did nothing"
  if validate_corpus "$tmp/$kind.tsv" >/dev/null 2>&1; then fail "path-forms: the corpus validator accepted a '$kind' edit"; fi
done

# Every row gives its key.
rows=0
while IFS=$'\t' read -r input key note; do
  [[ -z "$input" || "$input" == \#* ]] && continue
  got="$(canon_path_key "$input")"
  [[ "$got" == "$key" ]] || fail "path-forms: canon_path_key '$input' gave '$got', want '$key' ($note)"
  rows=$((rows + 1))
done < "$corpus"
[[ "$rows" -ge 25 ]] || fail "path-forms: only $rows corpus rows ran"

# The key is a pure function: the same under a fake Windows (uname says MINGW, cygpath is broken, MSYS variables set).
stub="$tmp/stub"; mkdir -p "$stub"
printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$stub/uname"; printf '#!/bin/sh\necho BROKEN\nexit 3\n' > "$stub/cygpath"; chmod +x "$stub/uname" "$stub/cygpath"
while IFS=$'\t' read -r input key note; do
  [[ -z "$input" || "$input" == \#* ]] && continue
  got="$(PATH="$stub:$PATH" OSTYPE=msys MSYSTEM=MINGW64 MSYS_NO_PATHCONV=1 canon_path_key "$input")"
  [[ "$got" == "$key" ]] || fail "path-forms: canon_path_key depends on the OS or environment: '$input' gave '$got' under a fake Windows, want '$key'"
done < "$corpus"

# --- sprint token-spend: git lists the worktree as C:/Users/x/wt, the events name it C:\Users\x\wt (JSON-escaped), the transcript's cwd is /c/Users/x/wt.
proj="$(make_project)"; root="$(cd "$proj" && pwd -P)"
cfg="$(mktemp -d)"; chome="$(mktemp -d)"; shim="$(mktemp -d)"
real_git="$(command -v git)"
export CLAUDE_CONFIG_DIR="$cfg" CANON_HOME="$chome" SHIM_ROOT="$root" REAL_GIT="$real_git"
mkdir -p "$chome/events"
cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
# prints a Windows-style worktree list (C:/...) the way git for Windows does; every other call is the real git
case "$*" in
  *"worktree list --porcelain"*)
    printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/main\n\n' "$SHIM_ROOT"
    printf 'worktree C:/Users/x/wt\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/feat\n\n'
    exit 0 ;;
esac
exec "$REAL_GIT" "$@"
SH
chmod +x "$shim/git"
ev='C:\\Users\\x\\wt'   # as a JSON string holds C:\Users\x\wt
{ printf '{"schema":1,"ts":"2026-10-02T14:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-wtsp"}}\n' "$ev"
  printf '{"schema":1,"ts":"2026-10-02T14:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-wtsp"}}\n' "$ev"; } > "$chome/events/2026-10-02.jsonl"
turn() { printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"%s","type":"message","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":20}},"timestamp":"2026-10-02T%s.000Z","cwd":"%s"}\n' "$1" "$2" "$3"; }
tdir="$cfg/projects/C--Users-x-wt"; mkdir -p "$tdir"   # Claude Code names the folder after the native path: every non-alphanumeric byte becomes -

turn msg_wt1 14:10:00 '/c/Users/x/wt' > "$tdir/w.jsonl"
out="$(cd "$proj" && PATH="$shim:$PATH" "$SPRINT" token-spend --ticket t-wtsp 2>&1)"
[[ "$out" != *"No transcript turns"* && "$out" != *"No completed sprint"* ]] || fail "path-forms: token-spend lost a sprint whose three sources spell the folder three ways: $out"
[[ -n "$(printf '%s\n' "$out" | awk '$1 == "t-wtsp"')" ]] || fail "path-forms: no t-wtsp row: $out"

# When nothing matches, the message prints each source's raw spelling beside the keys, so a spelling bug in ONE source names itself.
turn msg_wt2 14:11:00 '/c/Users/x/zzz' > "$tdir/w.jsonl"
out="$(cd "$proj" && PATH="$shim:$PATH" "$SPRINT" token-spend --ticket t-wtsp 2>&1)"
assert_contains "$out" "No transcript turns inside these sprints"
assert_contains "$out" 'raw spellings: cwd /c/Users/x/zzz; event project C:\\Users\\x\\wt; path list '
assert_contains "$out" "C:/Users/x/wt"

printf 'path-forms: ok\n'
