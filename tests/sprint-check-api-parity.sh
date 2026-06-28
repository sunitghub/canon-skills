#!/usr/bin/env bash
# sprint-check-api-parity — assert server.py and main.go expose the same /api/ routes

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

SERVER_PY="$ROOT/tools/sprint-check-app/server.py"
MAIN_GO="$ROOT/tools/sprint-check-go/main.go"

# Extract /api/ routes from server.py:
#   exact:  path == '/api/foo'
#   regex:  r'^/api/foo/
py_routes() {
  {
    grep -oE "path == '/api/[^']+'" "$SERVER_PY" | sed "s/path == '//;s/'$//" || true
    grep -oE "r'\^/api/[^'()\$\\\\]+" "$SERVER_PY" | sed "s/r'\^//" || true
  } | sed 's|/$||' | sort -u
}

# Extract /api/ routes from main.go:
#   exact:  case "/api/foo":
#   regex:  `^/api/foo/
go_routes() {
  {
    grep -oE 'case "/api/[^"]+"' "$MAIN_GO" | sed 's/case "//;s/"$//' || true
    grep -oE '`\^/api/[^`/()\$\\]+' "$MAIN_GO" | sed 's/`\^//' || true
  } | sed 's|/$||' | sort -u
}

py="$(py_routes)"
go="$(go_routes)"

if [[ "$py" == "$go" ]]; then
  echo "sprint-check-api-parity: ok ($(echo "$py" | wc -l | tr -d ' ') routes match)"
  exit 0
fi

echo "sprint-check-api-parity: FAIL — route mismatch between server.py and main.go"
echo ""
echo "In server.py only:"
comm -23 <(echo "$py") <(echo "$go") | sed 's/^/  /'
echo "In main.go only:"
comm -13 <(echo "$py") <(echo "$go") | sed 's/^/  /'
exit 1
