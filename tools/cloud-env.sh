#!/usr/bin/env bash
# cloud-env.sh — t-9955: the one owner of the Claude cloud environment recipe (allowed domains and setup script), as the
# environment dialog takes them. Every project gets the base; a Go project (and canon itself) adds the Go part with --go.
# `tkt cloud-env` and `tkt github-doctor`'s `cloud` field print from here; docs/setup.md shows the --go recipe and
# tests/cloud-env.sh keeps the two in step. No network call.
#   cloud-env.sh domains [--go]   one domain per line
#   cloud-env.sh script [--go]    the setup script
set -euo pipefail

usage() { echo "Usage: cloud-env.sh domains|script [--go]" >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || usage
what="$1"; go=false
if [[ $# -eq 2 ]]; then [[ "$2" == --go ]] || usage; go=true; fi

# getcanon.dev is required: install.sh installs the latest verified release, read from its releases.txt manifest (t-34f1).
base_domains() {
  printf '%s\n' getcanon.dev github.com raw.githubusercontent.com objects.githubusercontent.com
}
go_domains() {
  printf '%s\n' go.dev dl.google.com proxy.golang.org sum.golang.org
}

script_head() {
  cat <<'SH'
#!/bin/bash
set -e
curl -fsSL https://getcanon.dev/install.sh | bash
SH
}
script_go() {
  cat <<'SH'

# Go: the toolchain canon pins, read from the installed release, so builds and tests match your machine.
GOV="$(sed -n 's/^toolchain go//p' "$HOME/.canon/tools/canon-go/go.mod" 2>/dev/null)" || GOV=""   # a missing file must not stop the session
case "$(uname -m)" in x86_64) GOARCH=amd64 ;; aarch64|arm64) GOARCH=arm64 ;; *) GOARCH="" ;; esac
if [ -n "$GOV" ] && [ -n "$GOARCH" ] && curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GOV}.linux-${GOARCH}.tar.gz"; then
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
else
  echo "setup: could not install Go ${GOV:-?}; keeping the image's $(go version 2>/dev/null)" >&2
fi
SH
}
script_tail() {
  cat <<'SH'

for t in canon sprint tkt sprint-check skills.sh evidence.sh gate-snapshot.sh subagent-log.sh mutant-sweep; do
  printf '#!/bin/bash\nexec "$HOME/.canon/tools/%s" "$@"\n' "$t" > "/usr/local/bin/$t"
  chmod +x "/usr/local/bin/$t"
done
mkdir -p "$HOME/.claude/agents"
cp "$HOME/.canon/agents/canon-reviewer.md" "$HOME/.canon/agents/canon-evaluator.md" "$HOME/.claude/agents/" || true
git config --global user.name >/dev/null || git config --global user.name "canon cloud session"
git config --global user.email >/dev/null || git config --global user.email "noreply@getcanon.dev"
SH
}

case "$what" in
  domains) base_domains; if $go; then go_domains; fi ;;
  script)  script_head; if $go; then script_go; fi; script_tail ;;
  *)       usage ;;
esac
