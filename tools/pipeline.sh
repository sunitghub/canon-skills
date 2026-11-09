#!/usr/bin/env bash
# pipeline.sh — the sprint pipeline's one reader (t-00e0). canon's default is skills/sprint/pipeline.yaml; a project may hold
# only what differs in <project>/canon-config/pipeline.yaml.
#   pipeline.sh resolve [--project <dir>] [--full]   one line per node in run order: <order> <id> <kind> <on|off> <locked|open>
#                                                    (--full: tab separated, order id kind on|off locked|open group when prompt reason; "-" = none)
#   pipeline.sh ids                                  the default's node ids, one per line
#   pipeline.sh check [--project <dir>]              validate; prints "pipeline: ok (N nodes)"
# The project file: `extends: canon-default` (required), `off: [a, b]` (or a `  - a` block list), `wrapup-order: [a, b, c]` (or a block
# list): a permutation of the nodes marked `group: wrapup`, nothing else. Nothing is executed or evaluated from either file: they are read
# by awk as plain text, every line must match a shape listed here and in the default's header, and an id must be [a-z][a-z0-9-]*.
# A refusal exits 2 with one line naming the file, the line and the problem (a locked node, an unknown node, a bad shape). A project with
# no file gets canon's default. A symlink, a binary file or one over 64 KB is refused.

set -euo pipefail
export LC_ALL=C

_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$_SOURCE" ]; do
  _DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
  _SOURCE="$(readlink "$_SOURCE")"
  [[ "$_SOURCE" != /* ]] && _SOURCE="$_DIR/$_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SOURCE")" && pwd)"
DEFAULT_FILE="$SCRIPT_DIR/../skills/sprint/pipeline.yaml"
MAX_BYTES=65536

usage() { sed -n '2,12p' "$_SOURCE" | sed 's/^# \{0,1\}//'; }
die() { echo "pipeline: $*" >&2; exit 2; }

# read -d '' (not $(cat <<…)): bash 3.2 mis-parses a quote inside a heredoc in a command substitution; read returns 1 at EOF, hence || true
read -r -d '' PROG <<'AWK' || true
function fail(f, n, msg) { gsub(/[^ -~]/, "?", msg); printf "pipeline: %s: line %d: %s\n", f, n, msg > "/dev/stderr"; exit 2 }   # msg may echo hostile bytes (a bad id): printable ASCII only
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function okid(s) { return s ~ /^[a-z][a-z0-9-]*$/ && length(s) <= 40 }
function val(f, n, s,   v) {
  v = trim(s)
  if (v ~ /^"[^"]*"$/) return substr(v, 2, length(v) - 2)
  if (v ~ /["'#]/) fail(f, n, "a value with a quote or '#' must be one double-quoted string")
  return v
}
function readline(f, st,   rc) {
  rc = (getline line < f)
  if (rc < 0) { printf "pipeline: %s: cannot read\n", f > "/dev/stderr"; exit 2 }
  if (rc > 0) { st["n"]++; sub(/\r$/, "", line); if (length(line) > 400) fail(f, st["n"], "line over 400 characters"); if (st["n"] > 2000) fail(f, st["n"], "more than 2000 lines") }
  return rc
}
function parse_default(f,   st, innodes, k, idx, key, v, i) {
  st["n"] = 0; innodes = 0; N = 0
  while (readline(f, st) > 0) {
    ln = st["n"]
    if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) continue
    if (line == "nodes:") { if (innodes) fail(f, ln, "nodes: twice"); innodes = 1; continue }
    if (!innodes) fail(f, ln, "expected 'nodes:' first")
    if (line ~ /^  - id: /) {
      sub(/^  - id: /, "", line); v = val(f, ln, line)
      if (!okid(v)) fail(f, ln, "bad node id '" v "' (lowercase letters, digits and '-', starting with a letter)")
      if (v in SEEN) fail(f, ln, "node '" v "' listed twice")
      if (N >= 200) fail(f, ln, "more than 200 nodes")
      N++; ID[N] = v; SEEN[v] = N; continue
    }
    if (line ~ /^    [a-z]+: /) {
      if (N == 0) fail(f, ln, "a field before any '- id:'")
      k = line; sub(/^    /, "", k); idx = index(k, ": "); key = substr(k, 1, idx - 1); v = val(f, ln, substr(k, idx + 2))
      if (key !~ /^(kind|order|locked|reason|group|when|prompt)$/) fail(f, ln, "unknown field '" key "'")
      if ((N, key) in HAVE) fail(f, ln, "field '" key "' twice in node '" ID[N] "'")
      HAVE[N, key] = 1; F[N, key] = v; continue
    }
    fail(f, ln, "unsupported line (see the header of skills/sprint/pipeline.yaml)")
  }
  close(f)
  if (N == 0) fail(f, 0, "no nodes")
  for (i = 1; i <= N; i++) {
    if (!((i, "kind") in HAVE) || F[i, "kind"] !~ /^(step|gate|agent|you)$/) fail(f, 0, "node '" ID[i] "' needs kind: step, gate, agent or you")
    if (!((i, "order") in HAVE) || F[i, "order"] !~ /^[0-9]+$/) fail(f, 0, "node '" ID[i] "' needs a numeric order")
    if (F[i, "order"] in ORD) fail(f, 0, "nodes '" ORD[F[i, "order"]] "' and '" ID[i] "' share order " F[i, "order"])
    ORD[F[i, "order"]] = ID[i]
    if (!((i, "locked") in HAVE) || F[i, "locked"] !~ /^(true|false)$/) fail(f, 0, "node '" ID[i] "' needs locked: true or false")
    if (F[i, "locked"] == "true" && F[i, "reason"] == "") fail(f, 0, "locked node '" ID[i] "' needs a reason")
    if ((i, "group") in HAVE && F[i, "group"] != "wrapup") fail(f, 0, "node '" ID[i] "': group must be wrapup")
  }
}
function parse_override(f,   st, cur, v, body, parts, m, j, t) {
  st["n"] = 0; cur = ""; EXT = 0; NO = 0; NW = 0; SAWOFF = 0; SAWWO = 0
  while (readline(f, st) > 0) {
    ln = st["n"]
    if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) continue
    if (line ~ /^extends:/) {
      if (EXT) fail(f, ln, "extends twice")
      sub(/^extends:[ \t]*/, "", line)
      if (trim(line) != "canon-default") fail(f, ln, "extends must be canon-default")
      EXT = 1; cur = ""; continue
    }
    if (line ~ /^(off|wrapup-order):/) {
      key = line; sub(/:.*$/, "", key); body = line; sub(/^[a-z-]+:[ \t]*/, "", body); body = trim(body)
      if (key == "off") { if (SAWOFF) fail(f, ln, "off twice"); SAWOFF = 1 } else { if (SAWWO) fail(f, ln, "wrapup-order twice"); SAWWO = 1 }
      cur = ""
      if (body == "") { cur = key; continue }
      if (substr(body, 1, 1) != "[" || substr(body, length(body), 1) != "]") fail(f, ln, key " must be [id, id] or a '  - id' list")
      body = substr(body, 2, length(body) - 2)
      if (index(body, "[") || index(body, "]")) fail(f, ln, key " must be [id, id] or a '  - id' list")
      if (trim(body) == "") continue
      m = split(body, parts, ",")
      for (j = 1; j <= m; j++) { t = trim(parts[j]); if (!okid(t)) fail(f, ln, "bad node id '" t "'"); push(f, ln, key, t) }
      continue
    }
    if (line ~ /^  - / && cur != "") {
      t = line; sub(/^  - /, "", t); t = trim(t)
      if (!okid(t)) fail(f, ln, "bad node id '" t "'")
      push(f, ln, cur, t); continue
    }
    fail(f, ln, "unsupported line (extends: canon-default, off: [..], wrapup-order: [..])")
  }
  close(f)
  if (!EXT) fail(f, 0, "missing 'extends: canon-default'")
}
function push(f, ln, key, id) {
  if (!(id in SEEN)) fail(f, ln, "unknown node '" id "'")
  if (key == "off") {
    if (id in OFFSET) fail(f, ln, "node '" id "' listed twice in off")
    if (F[SEEN[id], "locked"] == "true") fail(f, ln, "node '" id "' is locked: " F[SEEN[id], "reason"])
    OFFSET[id] = 1; NO++
  } else {
    if (id in WOSET) fail(f, ln, "node '" id "' listed twice in wrapup-order")
    WOSET[id] = 1; NW++; WO[NW] = id
  }
}
BEGIN {
  dflt = ENVIRON["PIPE_DEFAULT"]; proj = ENVIRON["PIPE_PROJECT"]; full = ENVIRON["PIPE_FULL"]
  parse_default(dflt)
  if (proj != "") parse_override(proj)
  # sort node indexes by order
  for (i = 1; i <= N; i++) S[i] = i
  for (i = 1; i < N; i++) for (j = i + 1; j <= N; j++) if (F[S[j], "order"] + 0 < F[S[i], "order"] + 0) { t = S[i]; S[i] = S[j]; S[j] = t }
  if (NW > 0) {
    g = 0
    for (i = 1; i <= N; i++) if (F[S[i], "group"] == "wrapup") { g++; GSLOT[g] = i; GROUPSET[ID[S[i]]] = 1 }
    ok = (NW == g)
    for (i = 1; ok && i <= NW; i++) if (!(WO[i] in GROUPSET)) ok = 0
    if (!ok) {
      list = ""
      for (i = 1; i <= g; i++) list = list (i > 1 ? ", " : "") ID[S[GSLOT[i]]]
      printf "pipeline: %s: wrapup-order must list exactly: %s\n", proj, list > "/dev/stderr"; exit 2
    }
    for (i = 1; i <= g; i++) NEWIDX[i] = SEEN[WO[i]]
    for (i = 1; i <= g; i++) { SLOTORDER[i] = F[S[GSLOT[i]], "order"]; S[GSLOT[i]] = NEWIDX[i] }
    for (i = 1; i <= g; i++) OVERRIDEORDER[S[GSLOT[i]]] = SLOTORDER[i]
  }
  for (i = 1; i <= N; i++) {
    x = S[i]; id = ID[x]
    ord = (x in OVERRIDEORDER) ? OVERRIDEORDER[x] : F[x, "order"]
    on = (id in OFFSET) ? "off" : "on"
    lk = (F[x, "locked"] == "true") ? "locked" : "open"
    if (full != "") {
      grp = ((x, "group") in HAVE) ? F[x, "group"] : "-"; wh = ((x, "when") in HAVE) ? F[x, "when"] : "-"
      pr = ((x, "prompt") in HAVE) ? F[x, "prompt"] : "-"; rs = ((x, "reason") in HAVE) ? F[x, "reason"] : "-"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ord, id, F[x, "kind"], on, lk, grp, wh, pr, rs
    } else printf "%s %s %s %s %s\n", ord, id, F[x, "kind"], on, lk
  }
}
AWK

# project_file <dir>: the override path when the folder has one, else nothing; refuses a symlink, a binary or an oversized file
project_file() {
  local dir="$1" f size clean
  [[ -d "$dir" ]] || die "--project: not a folder: $dir"
  f="$dir/canon-config/pipeline.yaml"
  if [[ -L "$f" ]]; then die "$f: refusing a symlink"; fi
  [[ -e "$f" ]] || return 0
  [[ -f "$f" ]] || die "$f: not a regular file"
  [[ -r "$f" ]] || die "$f: not readable"
  size="$(wc -c < "$f" | tr -d ' ')"
  (( size <= MAX_BYTES )) || die "$f: over $MAX_BYTES bytes"
  clean="$(tr -d '\000' < "$f" | wc -c | tr -d ' ')"
  [[ "$clean" == "$size" ]] || die "$f: binary file (a NUL byte)"
  printf '%s\n' "$f"
}

run_resolve() {   # run_resolve <project dir or empty> <full flag or empty>
  local proj="" out rc=0
  [[ -f "$DEFAULT_FILE" ]] || die "canon's default pipeline is missing: $DEFAULT_FILE"
  if [[ -n "$1" ]]; then proj="$(project_file "$1")" || exit $?; fi
  out="$(PIPE_DEFAULT="$DEFAULT_FILE" PIPE_PROJECT="$proj" PIPE_FULL="$2" awk "$PROG" </dev/null)" || rc=$?
  (( rc == 0 )) || exit "$rc"
  printf '%s\n' "$out"
}

cmd="${1:-}"; [[ $# -gt 0 ]] && shift
project=""; full=""
case "$cmd" in
  resolve|check)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --project) [[ $# -ge 2 ]] || die "--project needs a folder"; project="$2"; shift 2 ;;
        --full) [[ "$cmd" == resolve ]] || die "--full is for resolve"; full=1; shift ;;
        *) die "unknown option $1" ;;
      esac
    done
    if [[ "$cmd" == resolve ]]; then run_resolve "$project" "$full"
    else out="$(run_resolve "$project" "")" || exit $?; echo "pipeline: ok ($(printf '%s\n' "$out" | wc -l | tr -d ' ') nodes)"; fi ;;
  ids)
    [[ $# -eq 0 ]] || die "ids takes no arguments"
    out="$(run_resolve "" "")" || exit $?
    printf '%s\n' "$out" | awk '{ print $2 }' ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
