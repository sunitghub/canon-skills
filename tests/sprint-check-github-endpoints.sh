#!/usr/bin/env bash
# t-d271: the GitHub workflow routes in BOTH servers run exactly one tkt command each (a stub via TKT_BIN logs its
# argv, cwd and environment), refuse a bad PR before running anything, and the merge job shows output while it runs,
# keeps one job per ticket, and ends with the exit code. Both servers give the same shapes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
command -v go >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "sprint-check-github-endpoints: skipped (needs go and curl)"; exit 0; }

W="$(cd "$(mktemp -d)" && pwd -P)"; GO_BIN="$W/sc-go"; PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done; rm -rf "$W"; }
trap cleanup EXIT
PROJ="$W/proj"; mkdir -p "$PROJ/.tickets/t-ab12" && (cd "$PROJ" && git init -q)
printf -- '---\nid: t-ab12\nstatus: open\ntype: task\npriority: 2\n---\n# Sent one\n' > "$PROJ/.tickets/t-ab12/ticket.md"

# The stub tkt: one log line per call ("<cwd> | <argv> | progress=<CANON_PROGRESS_SECONDS>"). merge-pr --yes prints a
# line, waits for $W/release (the test's go-ahead), prints another; $W/fail makes every call exit 3.
cat > "$W/tkt" <<SH
#!/usr/bin/env bash
printf '%s | %s | progress=%s\n' "\$PWD" "\$*" "\${CANON_PROGRESS_SECONDS:-}" >> "$W/log"
[[ -e "$W/fail" ]] && { echo "stub failure"; exit 3; }
case "\$1 \$*" in
  *"--dry-run"*) echo "would do: \$*" ;;
  "merge-pr "*"--yes"*) echo "progress one"; for _ in \$(seq 100); do [[ -e "$W/release" ]] && break; sleep 0.1; done; echo "progress two" ;;
  *) echo "did: \$*" ;;
esac
SH
chmod +x "$W/tkt"
(cd "$ROOT" && GO111MODULE=off go build -o "$GO_BIN" ./tools/sprint-check-go)
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PYP="$(port)"; GOP="$(port)"
mkdir -p "$W/ck"
SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$W/c1" COCKPIT_STATE_DIR="$W/ck" TKT_BIN="$W/tkt" python3 "$ROOT/tools/sprint-check-app/server.py" "$PYP" >/dev/null 2>&1 & PIDS+=($!); disown $! 2>/dev/null || true
SPRINT_CHECK_ROOT="$PROJ" CANON_HOME="$W/c2" COCKPIT_STATE_DIR="$W/ck" TKT_BIN="$W/tkt" SPRINT_CHECK_NO_BROWSER=1 "$GO_BIN" "$GOP" >/dev/null 2>&1 & PIDS+=($!); disown $! 2>/dev/null || true
for p in "$PYP" "$GOP"; do for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$p/api/tickets" && break; sleep 0.1; done; done

get()  { curl -s -w '\n%{http_code}' "http://127.0.0.1:$1$2"; }
post() { curl -s -w '\n%{http_code}' -X POST -H 'Origin: http://localhost' -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$1$2"; }
code() { tail -n1 <<< "$1"; }; body() { sed '$d' <<< "$1"; }
js() { node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));const r=(function(j){return eval(process.argv[1])})(j);process.stdout.write(typeof r==="string"?r:JSON.stringify(r))' "$1"; }
last() { tail -n1 "$W/log" 2>/dev/null || true; }
expect_call() { # <name> <port> <response> <argv> [progress]
  [[ "$(code "$3")" == 200 ]] || fail "$1: HTTP $(code "$3"): $(body "$3")"
  assert_eq "$PROJ | $4 | progress=${5:-}" "$(last)"
  assert_eq "true|0" "$(body "$3" | js '[j.ok,j.exit_code].join("|")')"
}

for P in "$PYP" "$GOP"; do
  srv=$([[ $P == "$PYP" ]] && echo py || echo go); : > "$W/log"
  expect_call "$srv send-preview" "$P" "$(get "$P" /api/ticket/t-ab12/github/send-preview)" "send-issue t-ab12 --dry-run"
  expect_call "$srv send"          "$P" "$(post "$P" /api/ticket/t-ab12/github/send '{}')" "send-issue t-ab12"
  expect_call "$srv send public"   "$P" "$(post "$P" /api/ticket/t-ab12/github/send '{"public":true}')" "send-issue t-ab12 --public"
  expect_call "$srv send public?"  "$P" "$(post "$P" /api/ticket/t-ab12/github/send '{"public":"yes"}')" "send-issue t-ab12"   # only a real true
  expect_call "$srv sync-preview"  "$P" "$(get "$P" /api/github/sync-preview)" "sync-issues --dry-run"
  expect_call "$srv sync"          "$P" "$(post "$P" /api/github/sync '{}')" "sync-issues"
  expect_call "$srv import"        "$P" "$(post "$P" /api/ticket/t-ab12/github/import '{"pr":58}')" "import-results t-ab12 --pr 58"
  expect_call "$srv import str"    "$P" "$(post "$P" /api/ticket/t-ab12/github/import '{"pr":"58"}')" "import-results t-ab12 --pr 58"
  expect_call "$srv import no pr"  "$P" "$(post "$P" /api/ticket/t-ab12/github/import '{}')" "import-results t-ab12"
  expect_call "$srv merge-check"   "$P" "$(get "$P" '/api/ticket/t-ab12/github/merge-check?pr=58')" "merge-pr t-ab12 --check --pr 58"
  expect_call "$srv take-back"     "$P" "$(post "$P" /api/ticket/t-ab12/github/take-back '{}')" "take-back t-ab12"
  expect_call "$srv take-back cl"  "$P" "$(post "$P" /api/ticket/t-ab12/github/take-back '{"close_issue":true}')" "take-back t-ab12 --close-issue"
  # A PR that is not digits: 400 and nothing run, on every route that takes one.
  n="$(wc -l < "$W/log")"
  for bad in '"5x"' '"58; rm -rf /"' '-1' '1.5' '"--yes"'; do
    r="$(post "$P" /api/ticket/t-ab12/github/import "{\"pr\":$bad}")"; [[ "$(code "$r")" == 400 ]] || fail "$srv import pr=$bad: HTTP $(code "$r")"
    r="$(post "$P" /api/ticket/t-ab12/github/merge "{\"pr\":$bad}")"; [[ "$(code "$r")" == 400 ]] || fail "$srv merge pr=$bad: HTTP $(code "$r")"
  done
  r="$(get "$P" '/api/ticket/t-ab12/github/merge-check?pr=x9')"; [[ "$(code "$r")" == 400 ]] || fail "$srv merge-check pr=x9: HTTP $(code "$r")"
  r="$(post "$P" /api/ticket/T-AB12/github/send '{}')"; [[ "$(code "$r")" != 200 ]] || fail "$srv accepted a malformed id"
  assert_eq "$n" "$(wc -l < "$W/log")"   # none of those ran tkt
  # A failing tkt: ok false, its exit code and output.
  touch "$W/fail"; r="$(post "$P" /api/ticket/t-ab12/github/send '{}')"; rm -f "$W/fail"
  assert_eq "false|3|stub failure" "$(body "$r" | js '[j.ok,j.exit_code,j.output.trim()].join("|")')"
  # The merge job: idle first; running, with the first line visible before the job ends; a second start is the same job.
  assert_eq "idle" "$(body "$(get "$P" /api/ticket/t-ab12/github/merge)" | js 'j.status')"
  rm -f "$W/release"; : > "$W/log"
  r="$(post "$P" /api/ticket/t-ab12/github/merge '{"pr":58}')"; assert_eq "running" "$(body "$r" | js 'j.status')"
  seen=""; for _ in $(seq 50); do s="$(body "$(get "$P" /api/ticket/t-ab12/github/merge)")"; [[ "$(js 'j.output' <<< "$s")" == *"progress one"* ]] && { seen="$s"; break; }; sleep 0.1; done
  [[ -n "$seen" ]] || fail "$srv: the merge job's output was not visible while it ran"
  assert_eq "running|false" "$(js '[j.status, j.output.includes("progress two")].join("|")' <<< "$seen")"
  [[ "$(js 'typeof j.elapsed' <<< "$seen")" == number ]] || fail "$srv: no elapsed while running"
  assert_eq "running" "$(body "$(post "$P" /api/ticket/t-ab12/github/merge '{"pr":58}')" | js 'j.status')"
  touch "$W/release"
  for _ in $(seq 50); do s="$(body "$(get "$P" /api/ticket/t-ab12/github/merge)")"; [[ "$(js 'j.status' <<< "$s")" == done ]] && break; sleep 0.1; done
  assert_eq "done|0|true" "$(js '[j.status,j.exit_code,j.output.includes("progress two")].join("|")' <<< "$s")"
  assert_eq "1" "$(grep -c 'merge-pr t-ab12 --yes --pr 58' "$W/log")"   # one job, not two
  assert_eq "$PROJ | merge-pr t-ab12 --yes --pr 58 | progress=5" "$(grep 'merge-pr' "$W/log")"
  echo "sprint-check-github-endpoints: $srv ok"
done
echo "sprint-check-github-endpoints: ok (both servers)"
