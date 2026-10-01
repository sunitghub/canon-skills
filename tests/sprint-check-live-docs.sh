#!/usr/bin/env bash
# sprint-check-live-docs (t-e78b, t-26f9) — for a ticket bound to a worktree, the board
# reads its sprint docs from that worktree's copy and (t-26f9) may write them there,
# guarded by the etag it read (base_hash), identically in server.py and main.go. The
# binding comes from the agent-writable .cockpit-cwd lock (or an in-progress worktree
# copy), so a lock naming anything but a registered worktree of this repo must be
# ignored, and every write is re-validated: allowlisted doc names compared raw, no
# symlinks, a size cap, atomic rename, never main's copy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "sprint-check-live-docs: python3/curl/git absent — skipped"
  exit 0
fi

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
GO_BIN=""
PIDS=()
TMP="$(mktemp -d)"
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
  [[ -n "$GO_BIN" ]] && rm -rf "$(dirname "$GO_BIN")"
  return 0
}
trap cleanup EXIT

if command -v go >/dev/null 2>&1; then
  GO_BIN="$(mktemp -d)/sprint-check-go-bin"
  (cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
fi

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
fm() { printf -- '---\nid: %s\nstatus: %s\ntype: task\npriority: 2\n---\n# %s\n' "$1" "$2" "$1"; }

run_checks() {
  local kind="$1" label="$2" repo wt port base
  repo="$TMP/$kind/proj"; wt="$TMP/$kind/proj-worktrees/sprint-t-lv01"
  mkdir -p "$repo/.tickets/t-lv01" "$repo/.tickets/t-lv02" "$TMP/$kind/outside/.tickets/t-lv01"
  git -C "$repo" init -q -b master
  git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
  fm t-lv01 open > "$repo/.tickets/t-lv01/ticket.md"
  printf '# Acceptance\n\n## Criteria\n\n- [ ]\n\n## Test Plan\n\n- [ ]\n' > "$repo/.tickets/t-lv01/acceptance.md"
  fm t-lv02 open > "$repo/.tickets/t-lv02/ticket.md"
  git -C "$repo" add -A && git -C "$repo" commit -q -m init
  git -C "$repo" worktree add -q -b sprint/t-lv01 "$wt"
  # The sprint's live, uncommitted edits in the worktree.
  printf '# Acceptance\n\n## Criteria\n\n- [ ] live criterion\n\n## Test Plan\n\n- [ ] live test\n' > "$wt/.tickets/t-lv01/acceptance.md"
  printf '# Plan\n\n## Approach\n\nlive approach\n' > "$wt/.tickets/t-lv01/plan.md"
  fm t-lv01 in_progress > "$wt/.tickets/t-lv01/ticket.md"
  # A decoy folder shaped like a worktree but NOT registered with git.
  fm t-lv01 in_progress > "$TMP/$kind/outside/.tickets/t-lv01/ticket.md"
  printf 'decoy\n' > "$TMP/$kind/outside/.tickets/t-lv01/plan.md"

  port="$(free_port)"
  if [[ "$kind" == py ]]; then
    SPRINT_CHECK_ROOT="$repo" CANON_HOME="$TMP/$kind/canon" COCKPIT_STATE_DIR="$TMP/$kind/ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_DIVERGENCE_TTL=0 \
      python3 "$SERVER_PY" "$port" >/dev/null 2>&1 &
  else
    SPRINT_CHECK_ROOT="$repo" CANON_HOME="$TMP/$kind/canon" COCKPIT_STATE_DIR="$TMP/$kind/ck" COCKPIT_DAEMON_BIN=/usr/bin/false SPRINT_CHECK_DIVERGENCE_TTL=0 SPRINT_CHECK_NO_BROWSER=1 \
      "$GO_BIN" "$port" >/dev/null 2>&1 &
  fi
  PIDS+=("$!"); disown "$!" 2>/dev/null || true
  base="http://127.0.0.1:$port"
  for _ in $(seq 1 50); do curl -s -o /dev/null "$base/api/git" && break; sleep 0.1; done

  tfield() { curl -s "$base/api/tickets" | python3 -c 'import json,sys; t={x["id"]:x for x in json.load(sys.stdin)}[sys.argv[1]]; print(json.dumps({k:t.get(k) for k in ("docs_from","acceptance_has_items","plan_has_approach")}, sort_keys=True))' "$1"; }
  getdoc() { curl -s "$base/api/doc/t-lv01/$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("content","").strip())' 2>/dev/null || echo 404; }

  # 1. In-progress worktree copy, no lock → bound via divergence.
  [[ "$(tfield t-lv01)" == '{"acceptance_has_items": true, "docs_from": {"branch": "sprint/t-lv01"}, "plan_has_approach": true}' ]] \
    || fail "$label: in-progress copy should overlay live docs, got $(tfield t-lv01)"
  [[ "$(tfield t-lv02)" == '{"acceptance_has_items": null, "docs_from": null, "plan_has_approach": null}' ]] \
    || fail "$label: unbound ticket must stay main's, got $(tfield t-lv02)"

  # 2. Lock to the worktree → bound; GET reads the live copy with an etag; POST is guarded by base_hash.
  echo "$wt" > "$repo/.tickets/t-lv01/.cockpit-cwd"
  getdoc plan.md | grep -q 'live approach' || fail "$label: GET plan.md should return the worktree copy"
  sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
  etag_of() { curl -s "$base/api/doc/t-lv01/$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("etag","<none>"))'; }
  post() { curl -s -o "$TMP/$kind/post.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "$2" "$base/api/doc/$1"; }
  pj() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$TMP/$kind/post.json" "$1"; }
  local mainf="$repo/.tickets/t-lv01/acceptance.md" wtf="$wt/.tickets/t-lv01/acceptance.md" code
  [[ "$(etag_of acceptance.md)" == "$(sha "$wtf")" ]] || fail "$label: etag must be sha256 of the worktree file's bytes"
  # A doc only main has: the text falls back to main's copy, but the etag describes the WORKTREE file ('absent').
  printf 'main research\n' > "$repo/.tickets/t-lv01/research.md"
  [[ "$(etag_of research.md)" == absent && "$(getdoc research.md)" == 'main research' ]] || fail "$label: a doc only main has must show main's text with etag 'absent'"
  local research_main; research_main="$(sha "$repo/.tickets/t-lv01/research.md")"
  local main_before wt_before; main_before="$(sha "$mainf")"; wt_before="$(sha "$wtf")"
  # 2a. Missing or wrong base_hash → 409 stale, nothing written.
  code="$(post t-lv01/acceptance.md '{"content":"board edit"}')"
  [[ "$code" == 409 && "$(pj code)" == stale ]] || fail "$label: POST without base_hash must be 409 stale, got $code $(cat "$TMP/$kind/post.json")"
  code="$(post t-lv01/acceptance.md '{"content":"board edit","base_hash":"deadbeef"}')"
  [[ "$code" == 409 && "$(pj code)" == stale ]] || fail "$label: a wrong base_hash must be 409 stale, got $code"
  [[ "$(sha "$mainf")" == "$main_before" && "$(sha "$wtf")" == "$wt_before" ]] || fail "$label: a stale POST changed a file"
  # 2b. The right base_hash writes the worktree copy only, atomically, and returns the new etag.
  code="$(post t-lv01/acceptance.md "{\"content\":\"# Acceptance\\n\\n- [x] board edit\",\"base_hash\":\"$wt_before\"}")"
  [[ "$code" == 200 && "$(pj ok)" == True ]] || fail "$label: a matching base_hash must write, got $code $(cat "$TMP/$kind/post.json")"
  grep -q 'board edit' "$wtf" || fail "$label: the worktree copy was not written"
  [[ "$(sha "$mainf")" == "$main_before" ]] || fail "$label: main's copy must be untouched by a live write"
  [[ "$(pj etag)" == "$(sha "$wtf")" && "$(etag_of acceptance.md)" == "$(sha "$wtf")" ]] || fail "$label: the returned etag must be sha256 of the new file"
  [[ -z "$(ls -A "$wt/.tickets/t-lv01" | grep -F '.board-' || true)" ]] || fail "$label: a temp file was left behind"
  code="$(post t-lv01/acceptance.md "{\"content\":\"again\",\"base_hash\":\"$wt_before\"}")"      # the old etag is now stale
  [[ "$code" == 409 ]] || fail "$label: a used-up base_hash must be stale, got $code"
  # 2c. A doc the worktree lacks is created there with base_hash 'absent' (and never in main).
  code="$(post t-lv01/research.md '{"content":"new research","base_hash":"absent"}')"
  [[ "$code" == 200 && "$(cat "$wt/.tickets/t-lv01/research.md")" == 'new research' && "$(sha "$repo/.tickets/t-lv01/research.md")" == "$research_main" ]] || fail "$label: creating a doc must land in the worktree only, main's copy untouched ($code)"
  # 2d. Refusals: each leaves every file as it was.
  local plan_before tk_before; plan_before="$(sha "$wt/.tickets/t-lv01/plan.md")"; wt_before="$(sha "$wtf")"; tk_before="$(sha "$wt/.tickets/t-lv01/ticket.md")"
  refuse() {   # refuse <doc> <body> <expected status> <why>
    code="$(post "$1" "$2")"
    [[ "$code" =~ ^($3)$ ]] || fail "$label: $4 must be $3, got $code $(cat "$TMP/$kind/post.json")"
    [[ "$(sha "$wt/.tickets/t-lv01/plan.md")" == "$plan_before" && "$(sha "$wtf")" == "$wt_before" && "$(sha "$wt/.tickets/t-lv01/ticket.md")" == "$tk_before" ]] || fail "$label: $4 changed a file"
  }
  local pe; pe="$(etag_of plan.md)"
  for bad in ticket.md 'plan.md.' 'plan.md%20' 'plan.md::%24DATA' 'plan.md%3Ax' 'TICKET~1.MD' 'NUL.md' 'C%3Aplan.md' '..%2Fplan.md' 'sub%2Fplan.md' '%5Cplan.md' 'notes.md' 'plan.txt'; do
    # A `..` path segment never reaches the handler in Go: its router answers 301 to the cleaned path (no write either way).
    refuse "t-lv01/$bad" "{\"content\":\"x\",\"base_hash\":\"$pe\"}" "$([[ "$bad" == ..* ]] && echo '400|301' || echo 400)" "doc name '$bad'"
  done
  [[ "$(head -c 200 "$wt/.tickets/t-lv01/ticket.md" | grep -c 'in_progress')" == 1 ]] || fail "$label: ticket.md was changed"
  for badc in '[1,2]' '7' 'null' '{"a":1}'; do
    refuse t-lv01/plan.md "{\"content\":$badc,\"base_hash\":\"$pe\"}" 400 "content $badc"
  done
  python3 -c 'import json; print(json.dumps({"content": "x"*1300000, "base_hash": "'"$pe"'"}))' > "$TMP/$kind/big.json"
  code="$(curl -s -o "$TMP/$kind/post.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/$kind/big.json" "$base/api/doc/t-lv01/plan.md")"
  [[ "$code" == 400 && "$(sha "$wt/.tickets/t-lv01/plan.md")" == "$plan_before" ]] || fail "$label: an oversize doc must be refused unchanged, got $code"
  # 2e. A symlinked target file is refused, the outside file untouched and the link still a link.
  printf 'outside secret\n' > "$TMP/$kind/outside/secret.txt"
  mv "$wt/.tickets/t-lv01/plan.md" "$TMP/$kind/plan.real"; ln -s "$TMP/$kind/outside/secret.txt" "$wt/.tickets/t-lv01/plan.md"
  code="$(post t-lv01/plan.md '{"content":"pwned","base_hash":"absent"}')"
  [[ "$code" == 403 && "$(cat "$TMP/$kind/outside/secret.txt")" == "outside secret" && -L "$wt/.tickets/t-lv01/plan.md" ]] || fail "$label: a symlinked plan.md must be refused (403) and the outside file untouched, got $code"
  rm "$wt/.tickets/t-lv01/plan.md"; mv "$TMP/$kind/plan.real" "$wt/.tickets/t-lv01/plan.md"
  # 2g. A symlinked .tickets folder in the worktree is refused (403); the real folder it points at is untouched.
  mv "$wt/.tickets" "$TMP/$kind/wt_tickets_real"; ln -s "$TMP/$kind/wt_tickets_real" "$wt/.tickets"
  local real_plan; real_plan="$(sha "$TMP/$kind/wt_tickets_real/t-lv01/plan.md")"
  code="$(post t-lv01/plan.md "{\"content\":\"pwned\",\"base_hash\":\"$plan_before\"}")"
  [[ "$code" == 403 && "$(sha "$TMP/$kind/wt_tickets_real/t-lv01/plan.md")" == "$real_plan" ]] || fail "$label: a symlinked .tickets must be refused (403) and untouched, got $code"
  rm "$wt/.tickets"; mv "$TMP/$kind/wt_tickets_real" "$wt/.tickets"
  # 2h. A symlinked ticket folder is not bound at all (the read-side check refuses it), so the write can never reach the decoy.
  mv "$wt/.tickets/t-lv01" "$TMP/$kind/tfolder.real"; ln -s "$TMP/$kind/outside/.tickets/t-lv01" "$wt/.tickets/t-lv01"
  post t-lv01/plan.md "{\"content\":\"pwned\",\"base_hash\":\"absent\"}" >/dev/null
  [[ "$(cat "$TMP/$kind/outside/.tickets/t-lv01/plan.md")" == decoy ]] || fail "$label: a symlinked ticket folder let a write reach the decoy"
  rm "$wt/.tickets/t-lv01"; mv "$TMP/$kind/tfolder.real" "$wt/.tickets/t-lv01"; rm -f "$repo/.tickets/t-lv01/plan.md"
  # 2f. Status, Description and Demo still write main's copy (this sprint's scope is docs only), unbound writes unchanged.
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"content":"plan for lv02"}' "$base/api/doc/t-lv02/plan.md")"
  [[ "$code" == 200 && -f "$repo/.tickets/t-lv02/plan.md" ]] || fail "$label: unbound ticket doc write must still work ($code)"
  [[ "$(sha "$mainf")" == "$main_before" ]] || fail "$label: main's acceptance.md changed"

  # 2i. End to end with the PRODUCTION gate code (extracted from tools/sprint, not re-implemented): what the board writes
  # into a worktree ticket is exactly what `sprint complete` reads.
  prod_fn() { awk -v n="$1" '$0 ~ "^" n "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$ROOT/tools/sprint"; }
  { for f in _acceptance_section _gate_acceptance_sections _gate_no_unchecked _gate_plan_signoff; do prod_fn "$f"; done; } > "$TMP/$kind/gates.sh"
  [[ "$(grep -c '^_gate_' "$TMP/$kind/gates.sh")" -ge 3 ]] || fail "$label: could not extract the production gate functions"
  # shellcheck disable=SC1090
  source "$TMP/$kind/gates.sh"
  jbody() { python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1], "base_hash": sys.argv[2]}))' "$1" "$2"; }
  local acc="$wt/.tickets/t-lv01/acceptance.md" pl="$wt/.tickets/t-lv01/plan.md"
  code="$(post t-lv01/acceptance.md "$(jbody $'# Acceptance\n\n## Criteria\n\n- [ ] a\n\n## Test Plan\n\n- [ ] b\n\n## QA\n\n- [ ] c' "$(etag_of acceptance.md)")")"
  [[ "$code" == 200 ]] || fail "$label: board write of an unchecked acceptance failed ($code)"
  if _gate_no_unchecked t-lv01 "$acc" >/dev/null; then fail "$label: the gate must see the unchecked boxes the board wrote"; fi
  code="$(post t-lv01/acceptance.md "$(jbody $'# Acceptance\n\n## Criteria\n\n- [x] a\n\n## Test Plan\n\n- [x] b\n\n## QA\n\n- [x] c' "$(etag_of acceptance.md)")")"
  [[ "$code" == 200 ]] || fail "$label: board tick of acceptance failed ($code)"
  _gate_no_unchecked t-lv01 "$acc" >/dev/null || fail "$label: the gate must accept the boxes the board ticked"
  code="$(post t-lv01/plan.md "$(jbody $'# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [ ] Plan approved\n\n## Approach\n\nx' "$(etag_of plan.md)")")"
  [[ "$code" == 200 ]] || fail "$label: board write of an unapproved plan failed ($code)"
  if _gate_plan_signoff t-lv01 "$pl" >/dev/null; then fail "$label: the gate must reject an unapproved plan the board wrote"; fi
  code="$(post t-lv01/plan.md "$(jbody $'# Plan\n\n## Sign-off\nTier: normal | Risk: low\n\n- [x] Plan approved\n\n## Approach\n\nx' "$(etag_of plan.md)")")"
  [[ "$code" == 200 ]] || fail "$label: board approval of the plan failed ($code)"
  _gate_plan_signoff t-lv01 "$pl" >/dev/null || fail "$label: the gate must accept the approval the board wrote"
  [[ -f "$repo/.tickets/t-lv01/plan.md" ]] && fail "$label: main's plan.md must still not exist"

  # 2j. Malformed-input fuzz (seeded, ~250 cases): wrong types, empty, huge, CRLF and binary, hostile names, broken JSON. Every
  # case must end in a structured answer (never a 5xx or a dropped connection), and only a 200 may change files, and only
  # the worktree's three docs.
  python3 - "$base" "$wt/.tickets/t-lv01" "$repo/.tickets" "$TMP/$kind/outside" <<'PY' || fail "$label: fuzz found a defect"
import hashlib, json, os, random, sys, urllib.error, urllib.parse, urllib.request
base, wtdir, maintickets, outside = sys.argv[1:5]
rnd = random.Random(26)
ALLOWED = {'acceptance.md', 'plan.md', 'research.md'}
def snap(root):
    out = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            out[p] = os.readlink(p) if os.path.islink(p) else hashlib.sha256(open(p, 'rb').read()).hexdigest()
    return out
def etag(name):
    try: return json.load(urllib.request.urlopen(f"{base}/api/doc/t-lv01/{name}")).get('etag', '')
    except Exception: return 'absent'
NAMES = ['plan.md', 'acceptance.md', 'research.md', 'ticket.md', 'PLAN.MD', 'Plan.Md', 'plan.md.', 'plan.md ', 'plan.md::$DATA', 'plan.md:x',
         'NUL.md', 'CON.md', 'TICKET~1.MD', '..', '.', '', 'a' * 300 + '.md', 'plan.md/', '/plan.md', 'sub/plan.md', '../plan.md',
         '..\\plan.md', 'plan.md\x00', 'pla\u202en.md', 'ünï.md', 'plan.md%00', '.board-x.tmp', '.cockpit-cwd', 'research.txt']
def content():
    k = rnd.randrange(17)
    if k == 0: return None
    if k == 1: return rnd.randrange(-5, 10**9)
    if k == 2: return rnd.random() * 1e9
    if k == 3: return rnd.choice([True, False])
    if k == 4: return [rnd.choice(['a', 1, None]) for _ in range(rnd.randrange(4))]
    if k == 5: return {'a': {'b': [1, 2]}}
    if k == 6: return ''
    if k == 7: return 'line1\r\nline2\r\n- [ ] x\r\n'
    if k == 8: return ''.join(chr(rnd.randrange(0, 0x250)) for _ in range(rnd.randrange(1, 200)))
    if k == 9: return '\x00\x01\ufeff' + 'bin' * 50
    if k == 10: return 'x' * rnd.choice([10, 1_048_576, 1_048_577, 1_300_000])
    if k == 11:
        d = []
        for _ in range(400): d = [d]
        return d
    if k == 12: return 'a\ud800b'                            # a lone surrogate: must never drop the connection
    if k == 13: return 'zz\x1c\x1d   \u0085'        # whitespace Go and Python disagree on
    if k == 14: return '﻿# bom first\r\n'
    return '# Acceptance\n\n- [ ] ok\n'
def base_hash(name):
    k = rnd.randrange(8)
    if k == 0: return None
    if k == 1: return 12345
    if k == 2: return ['x']
    if k == 3: return ''
    if k == 4: return 'z' * 5000
    if k in (5, 6): return etag(name if name in ALLOWED else 'plan.md')
    return 'absent'
def raw_body():
    k = rnd.randrange(10)
    if k == 0: return b'{'
    if k == 1: return b'[1,2'
    if k == 2: return b''
    if k == 3: return b'[]'
    if k == 4: return b'null'
    if k == 5: return bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 100)))
    return json.dumps({'content': content(), 'base_hash': base_hash(rnd.choice(list(ALLOWED)))}).encode('utf-8', 'surrogatepass')
def watched(): return {'wt': snap(wtdir), 'main': snap(maintickets), 'out': snap(outside)}
bad = []
cases = 0
for i in range(250):
    name = rnd.choice(NAMES)
    body = raw_body()
    if '..' in name and len(body) > 100_000:
        body = b'{}'   # Go's router answers 301 to the cleaned path without reading the body: a big upload would only break the pipe
    before = watched()
    plain = name.isascii() and name.isprintable() and ' ' not in name and '%' not in name and '#' not in name and '?' not in name
    url = f"{base}/api/doc/t-lv01/{name}" if (plain and rnd.random() < .5) else f"{base}/api/doc/t-lv01/{urllib.parse.quote(name, safe='')}"
    try:
        req = urllib.request.Request(url, data=body, method='POST', headers={'Content-Type': 'application/json'})
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k): return None
        op = urllib.request.build_opener(NoRedirect)
        try: r = op.open(req, timeout=15); status, text = r.status, r.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as e: status, text = e.code, e.read().decode('utf-8', 'replace')
    except Exception as e:
        bad.append((i, name, 'no answer', repr(e)[:120])); continue
    cases += 1
    if status >= 500 or status not in (200, 301, 400, 403, 404, 405, 409):
        bad.append((i, name, 'status', status, text[:120]))
    if 'Traceback' in text or 'panic:' in text or 'goroutine' in text:
        bad.append((i, name, 'leaked', text[:120]))
    after = watched()
    if status != 200:
        if after != before: bad.append((i, name, 'a non-200 changed files', status))
    else:
        changed = {k for grp in after for k in set(after[grp]) | set(before[grp]) if after[grp].get(k) != before[grp].get(k)}
        stray = [k for k in changed if not (k.startswith(wtdir) and os.path.basename(k) in ALLOWED)]
        if stray: bad.append((i, name, 'a 200 changed a file outside the allowed docs', stray[:3]))
try: urllib.request.urlopen(f"{base}/api/git", timeout=5).read()
except Exception as e: bad.append(('end', 'server not responding', repr(e)[:100]))
if bad:
    print('FUZZ DEFECTS:', len(bad), bad[:6]); sys.exit(1)
print(f'fuzz: {cases} cases ok')
PY

  # 2k. Review findings (t-26f9): a lone surrogate and Go-vs-Python whitespace give identical bytes; an unreadable file is
  # never "absent"; two writers holding the same etag can never both win.
  hexof() { python3 -c 'import sys; sys.stdout.write(open(sys.argv[1], "rb").read().hex())' "$1"; }
  e="$(etag_of research.md)"
  code="$(post t-lv01/research.md "{\"content\":\"a\\ud800b\",\"base_hash\":\"$e\"}")"
  [[ "$code" == 200 && "$(hexof "$wt/.tickets/t-lv01/research.md")" == "61efbfbd620a" ]] \
    || fail "$label: a lone surrogate must be stored as U+FFFD with a 200, got $code"
  e="$(etag_of research.md)"
  code="$(post t-lv01/research.md "{\"content\":\"zz\\u001c\",\"base_hash\":\"$e\"}")"
  [[ "$code" == 200 && "$(hexof "$wt/.tickets/t-lv01/research.md")" == "7a7a1c0a" ]] \
    || fail "$label: a trailing \\x1c must be kept (Go's TrimSpace does not strip it), got $code"
  if [[ "$(id -u)" != 0 ]]; then
    chmod 000 "$wt/.tickets/t-lv01/research.md"
    code="$(post t-lv01/research.md '{"content":"bypass","base_hash":"absent"}')"
    chmod 644 "$wt/.tickets/t-lv01/research.md"
    [[ "$code" == 500 && "$(pj code)" == read_failed ]] || fail "$label: an unreadable doc must not count as absent (500 read_failed), got $code"
    [[ "$(cat "$wt/.tickets/t-lv01/research.md" | head -c 6)" != bypass ]] || fail "$label: an unreadable doc was overwritten through base_hash 'absent'"
  fi
  local round wins
  for round in 1 2 3 4 5 6 7 8 9 10 11 12; do
    e="$(etag_of research.md)"
    ( curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d "{\"content\":\"writer A $round\",\"base_hash\":\"$e\"}" "$base/api/doc/t-lv01/research.md" > "$TMP/$kind/ra" ) &
    ( curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d "{\"content\":\"writer B $round\",\"base_hash\":\"$e\"}" "$base/api/doc/t-lv01/research.md" > "$TMP/$kind/rb" ) &
    wait
    wins="$(cat "$TMP/$kind/ra" "$TMP/$kind/rb" | sort | tr -d '\n')"
    [[ "$wins" == 200409 ]] || fail "$label: two writers with the same etag must give exactly one 200 and one 409, round $round got $wins"
  done

  # 3. A lock naming anything but a registered worktree is ignored (lock is agent-writable).
  fm t-lv01 open > "$wt/.tickets/t-lv01/ticket.md"      # drop the in-progress fallback
  for bogus in /etc "$TMP/$kind/outside" "$repo"; do
    echo "$bogus" > "$repo/.tickets/t-lv01/.cockpit-cwd"
    [[ "$(tfield t-lv01)" == '{"acceptance_has_items": false, "docs_from": null, "plan_has_approach": null}' ]] \
      || fail "$label: lock '$bogus' must not overlay, got $(tfield t-lv01)"
    [[ "$(getdoc plan.md)" == 404 || "$(getdoc plan.md)" == "" ]] || fail "$label: lock '$bogus' let GET read $(getdoc plan.md)"
  done

  # 4. Worktree removed → main again.
  echo "$wt" > "$repo/.tickets/t-lv01/.cockpit-cwd"
  git -C "$repo" worktree remove --force "$wt"
  [[ "$(tfield t-lv01)" == '{"acceptance_has_items": false, "docs_from": null, "plan_has_approach": null}' ]] \
    || fail "$label: removed worktree must fall back to main, got $(tfield t-lv01)"
  echo "  $label: live docs ok"
}

# Trigger paths (t-26f9): every client doc write goes through a call that carries base_hash. After the refactor there
# are exactly three direct `postWrite(`/api/doc…` sites (the guarded read-modify-write helper, the editor save, new doc);
# the checkbox toggle, the Sign-off controls and the Gate model all write through the helper.
writes="$(grep -n 'postWrite(`/api/doc' "$ROOT/tools/sprint-check-app/app.html" || true)"
[[ "$(grep -c . <<<"$writes")" -eq 3 ]] || fail "expected exactly 3 direct doc write sites in app.html, got: $writes"
[[ -z "$(grep -v base_hash <<<"$writes")" ]] || fail "a doc write site in app.html sends no base_hash: $(grep -v base_hash <<<"$writes")"

run_checks py server.py
if [[ -n "$GO_BIN" ]]; then
  run_checks go main.go
else
  echo "  main.go: go absent — Go half skipped"
fi
echo "sprint-check-live-docs: ok"
