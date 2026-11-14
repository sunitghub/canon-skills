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

# A newline is encoded (two paths that differ only by one never merge); no argument and an empty path give an empty key (safe under set -u).
[[ "$(canon_path_key $'/a\n/b')" == '/a%0A/b' ]] || fail "path-forms: a newline in a path must be encoded as %0A, got '$(canon_path_key $'/a\n/b')'"
[[ "$(canon_path_key $'/a/\n/b')" != "$(canon_path_key $'/a\n/b')" ]] || fail "path-forms: two paths that differ only by a newline got one key"
( set -u; canon_path_key >/dev/null 2>&1 ) || fail "path-forms: canon_path_key with no argument aborts under set -u"
[[ -z "$(canon_path_key)" ]] || fail "path-forms: canon_path_key with no argument printed something"

# t-c8c6: canon_same_folder, the comparison callers use (tools/canon's Windows update check, uninstall's project list). The string fallback:
# every two corpus inputs (none of them exist here) are the same folder exactly when their keys are equal.
ins=(); keys=()
while IFS=$'\t' read -r input key note; do [[ -z "$input" || "$input" == \#* ]] && continue; ins+=("$input"); keys+=("$key"); done < "$corpus"
same=0 diff=0
for ((i = 0; i < ${#ins[@]}; i++)); do for ((j = i + 1; j < ${#ins[@]}; j++)); do
  [[ "${keys[$i]}" == "${keys[$j]}" || "$j" == $((i + 1)) ]] || continue   # every same-key pair, and each row against the next (one awk pair each)
  if canon_same_folder "${ins[$i]}" "${ins[$j]}"; then got=same; else got=diff; fi
  if [[ "${keys[$i]}" == "${keys[$j]}" ]]; then want=same; same=$((same + 1)); else want=diff; diff=$((diff + 1)); fi
  [[ "$got" == "$want" ]] || fail "path-forms: canon_same_folder '${ins[$i]}' '${ins[$j]}' gave $got, want $want"
done; done
[[ "$same" -ge 5 && "$diff" -ge 20 ]] || fail "path-forms: the pair check ran $same same / $diff different pairs, too few"
canon_same_folder 'C:\Users\x\.canon' '/c/Users/x/.canon' || fail "path-forms: the drive spellings of one missing folder are not the same folder"
! canon_same_folder 'C:\Users\x\.canon' '/c/Users/y/.canon' || fail "path-forms: two folders were the same folder by spelling"
! canon_same_folder '' '' || fail "path-forms: two empty paths were the same folder"
! canon_same_folder '/a' '' || fail "path-forms: a path and an empty one were the same folder"
# The identity step: a folder and a symlink to it (no string rule makes them equal) are the same; a sibling is not.
mkdir -p "$tmp/real/sub" "$tmp/other"; ln -s "$tmp/real" "$tmp/link"
canon_same_folder "$tmp/real" "$tmp/link" || fail "path-forms: a folder and its symlink are not the same folder (identity step)"
canon_same_folder "$tmp/real/sub" "$tmp/link/sub/" || fail "path-forms: the same folder through a symlink with a trailing slash is not the same folder"
! canon_same_folder "$tmp/real" "$tmp/other" || fail "path-forms: two real folders were the same folder"
canon_same_folder "$tmp/real//gone" "$tmp/real/gone/" || fail "path-forms: a missing folder's two spellings are not the same folder (key fallback)"

# --- sprint token-spend: git lists the worktree as C:/Users/x/wt, the events name it C:\Users\x\wt (JSON-escaped), the transcript's cwd is /c/Users/x/wt.
proj="$(make_project)"; root="$(cd "$proj" && pwd -P)"
cfg="$(mktemp -d)"; chome="$(mktemp -d)"; shim="$(mktemp -d)"
real_git="$(command -v git)"
escwt="C:/Users/x/esc"$'\033'"[2Jdir"   # a worktree name with a control byte, as a hostile folder name could carry
export CLAUDE_CONFIG_DIR="$cfg" CANON_HOME="$chome" SHIM_ROOT="$root" REAL_GIT="$real_git" SHIM_ESCWT="$escwt"
mkdir -p "$chome/events"
cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
# prints a Windows-style worktree list (C:/...) the way git for Windows does; every other call is the real git
case "$*" in
  *"worktree list --porcelain"*)
    printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/main\n\n' "$SHIM_ROOT"
    printf 'worktree C:/Users/x/wt\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/feat\n\n'
    printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/esc\n\n' "$SHIM_ESCWT"
    printf 'worktree C:/Users/x/w4\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/w4\n\n'   # a fourth: the path list shows at most three
    exit 0 ;;
esac
exec "$REAL_GIT" "$@"
SH
chmod +x "$shim/git"
ev='C:\\Users\\x\\wt'   # as a JSON string holds C:\Users\x\wt
{ printf '{"schema":1,"ts":"2026-10-02T14:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-wtsp"}}\n' "$ev"
  printf '{"schema":1,"ts":"2026-10-02T14:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-wtsp"}}\n' "$ev"
  printf '{"schema":1,"ts":"2026-10-02T15:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-wtdup"}}\n' "$ev"   # a second sprint in the SAME folder
  printf '{"schema":1,"ts":"2026-10-02T15:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-wtdup"}}\n' "$ev"; } > "$chome/events/2026-10-02.jsonl"
turn() { printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"%s","type":"message","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":20}},"timestamp":"2026-10-02T%s.000Z","cwd":"%s"}\n' "$1" "$2" "$3"; }
tdir="$cfg/projects/C--Users-x-wt"; mkdir -p "$tdir"   # Claude Code names the folder after the native path: every non-alphanumeric byte becomes -

turn msg_wt1 14:10:00 '/c/Users/x/wt' > "$tdir/w.jsonl"
out="$(cd "$proj" && PATH="$shim:$PATH" "$SPRINT" token-spend --ticket t-wtsp 2>&1)"
[[ "$out" != *"No transcript turns"* && "$out" != *"No completed sprint"* ]] || fail "path-forms: token-spend lost a sprint whose three sources spell the folder three ways: $out"
[[ -n "$(printf '%s\n' "$out" | awk '$1 == "t-wtsp"')" ]] || fail "path-forms: no t-wtsp row: $out"

# When nothing matches, the message prints each source's raw spelling beside the keys, so a spelling bug in ONE source names itself.
{ turn msg_wt2 14:11:00 '/c/Users/x/zzz'; turn msg_wt3 14:12:00 '/c/Users/x/yyy'; } > "$tdir/w.jsonl"
out="$(cd "$proj" && PATH="$shim:$PATH" "$SPRINT" token-spend --ticket t-wtsp 2>&1)"
assert_contains "$out" "No transcript turns inside these sprints"
assert_contains "$out" 'raw spellings: cwd /c/Users/x/zzz, /c/Users/x/yyy; matched event project C:\\Users\\x\\wt; path list '   # two cwds joined, two sprints in one folder listed once
assert_contains "$out" "C:/Users/x/wt"

# Every raw spelling on that line is cleaned: a control byte in a kept event project or in the path list reaches the terminal as ?.
evesc='C:\\Users\\x\\esc'$'\033''[2Jdir'   # JSON-escaped backslashes, as the first event project
{ printf '{"schema":1,"ts":"2026-10-03T14:00:00.000Z","kind":"sprint.started","project":"%s","data":{"ticket":"t-wesc"}}\n' "$evesc"
  printf '{"schema":1,"ts":"2026-10-03T14:30:00.000Z","kind":"sprint.completed","project":"%s","data":{"ticket":"t-wesc"}}\n' "$evesc"; } > "$chome/events/2026-10-03.jsonl"
out="$(cd "$proj" && PATH="$shim:$PATH" "$SPRINT" token-spend --ticket t-wesc 2>&1)"
assert_contains "$out" "No transcript turns inside these sprints"
[[ "$out" != *$'\033'* ]] || fail "path-forms: a control byte from an event project or the path list reached the terminal: $(printf '%s' "$out" | tr '\033' '#')"
assert_contains "$out" 'matched event project C:\\Users\\x\\wt, C:\\Users\\x\\esc?[2Jdir; path list '   # the folder once, then the cleaned one
assert_contains "$out" ', C:/Users/x/wt, C:/Users/x/esc?[2Jdir'               # the path list, joined and cleaned
[[ "$out" != *"C:/Users/x/w4"* ]] || fail "path-forms: the raw path list shows more than three entries: $out"

printf 'path-forms: ok\n'
