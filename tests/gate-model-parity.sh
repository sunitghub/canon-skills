#!/usr/bin/env bash
# gate-model-parity — pins the two REAL `Gate model:` resolvers to one answer (t-842b).
#
# `Gate model:` is turned into a `--model` argv for claude in two places that share no
# runtime: tools/gate-model.sh (bash/awk, used by sprint-headless for CI) and
# tools/cockpit-daemon/main.go (Go, used by the cockpit daemon). That is the
# cross-runtime port exception in standards/efficiency.md — keep both, lock them with a
# parity test. This asserts the BASH side against tests/fixtures/gate-model-cases.json;
# TestParseGateModelFixtures / TestResolveGateModelFixtures assert the GO side against
# the same file. Either port drifting fails one of the two suites.
#
# Both sides call the real implementation — no awk or regex is re-implemented here.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/gate-model.sh"

# Guarded skip, matching tests/dsl-runner-comments.sh and tests/why-cap.sh: this
# script is in scripts/test.sh's mandatory list, so an unconditional python3 under
# `set -euo pipefail` would abort the whole suite on a python3-less machine.
if ! command -v python3 >/dev/null 2>&1; then
  echo "gate-model-parity: python3 absent — skipped"
  exit 0
fi

FIXTURES="$ROOT/tests/fixtures/gate-model-cases.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok() {
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    fails=$((fails + 1))
    printf '  FAIL %s  => got %q, want %q\n' "$1" "$2" "$3"
  fi
}

# Explode the fixtures into a TSV of (name, plan-file, expected-parse,
# expected-resolve). Tab-delimited, not NUL: bash silently drops NUL bytes, which
# collapses the record into one field and quietly skips every case but the first.
# Each plan body goes to its own file, so its newlines never reach this table.
python3 - "$FIXTURES" "$TMP" <<'PY'
import json, sys, pathlib
fixtures, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
cases = json.load(open(fixtures))["cases"]
out = []
for i, c in enumerate(cases):
    (tmp / f"plan{i}.md").write_text(c["plan"])
    assert not any("\t" in c[k] for k in ("name", "parse", "expect")), c["name"]
    out.append("\t".join([c["name"], str(tmp / f"plan{i}.md"), c["parse"], c["expect"]]))
(tmp / "records").write_text("\n".join(out) + "\n")
PY

count=0
while IFS=$'\t' read -r name plan want_parse want_resolve; do
  got_parse="$(gate_model_parse "$plan")"
  ok "parse: $name" "$got_parse" "$want_parse"
  # gate_model_resolve exits 2 on a present-but-invalid value; that is a pass when the
  # fixture expects no model, since "rejected" and "absent" both mean no --model flag.
  got_resolve="$(gate_model_resolve "$plan" 2>/dev/null)" || got_resolve=""
  ok "resolve: $name" "$got_resolve" "$want_resolve"
  count=$((count + 1))
done < "$TMP/records"

[[ "$count" -gt 0 ]] || { printf 'FAIL: no fixture cases loaded\n'; exit 1; }

if [[ "$fails" -eq 0 ]]; then
  printf '\ngate-model-parity: ok (%d cases, both directions)\n' "$count"
else
  printf '\ngate-model-parity: FAIL (%d)\n' "$fails"
  exit 1
fi
