#!/usr/bin/env bash
# doc-commands-shimmed — t-96f1: every canon command a skill or gate agent tells an agent to run must run from PowerShell and
# cmd.exe too. PowerShell opens a bare `x.sh` by file association (Windows' "Select an app" dialog) instead of running it; the
# commands that work are the ones with a `tools/<name>.cmd` shim, which starts Git Bash. Prod path: every close an agent runs from
# the sprint docs on Windows (Copilot CLI's shell is PowerShell). Scans inline code spans and fenced-block lines in skills/**/*.md
# and agents/*.md; a span of two or more words whose first word is a canon tool (tools/<word> exists) must have a .cmd shim, and a
# word ending in .sh never counts as shimmed. Exceptions are closed: a new unshimmed name fails here until it is shimmed, made a
# sprint subcommand, or listed below with its reason.
# Usage: tests/doc-commands-shimmed.sh [<root>]   (root defaults to this checkout; the revert proof passes a scratch copy)
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

EXCEPT="$(cat <<'LIST'
# name<TAB>reason (closed list: remove a row when its name is shimmed or no doc runs it)
canon-dev.sh	canon's own dev lint and catalog, run only in canon's repo on the Mac
skill-eval-history.sh	skill authoring in canon's repo (complete.md: skill eval is canon only)
plugin-eval-gen	skill authoring in canon's repo (complete.md: skill eval is canon only)
skills.sh	no name runs on both yet: tools/skills is a folder on Mac/Linux, skills.cmd on Windows (t-a844)
pipeline.sh	no name runs on both yet: no tools/pipeline on Mac/Linux, pipeline.cmd on Windows (t-a844)
LIST
)"

python3 - "$ROOT" "$EXCEPT" <<'PY'
import os, re, sys, pathlib
root = pathlib.Path(sys.argv[1]); exc = {}
for row in sys.argv[2].splitlines():
    if row.strip() and not row.startswith('#'):
        name, _, why = row.partition('\t'); exc[name.strip()] = why.strip()
        assert why.strip(), f'exception {name!r} has no reason'
files = sorted(root.glob('skills/**/*.md')) + sorted(root.glob('agents/*.md'))
prefix = re.compile(r'^(?:[A-Z_][A-Z0-9_]*=\S+\s+)*(?:\$\{?CANON_ROOT\}?/|~/\.canon/|\./)?')
bad, used = [], set()
def check(f, n, text):
    text = prefix.sub('', text.strip())
    words = text.split()
    if len(words) < 2: return
    w = words[0]; name = w[len('tools/'):] if w.startswith('tools/') else w
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name): return
    tool = root / 'tools' / name   # a canon command: an executable file in tools/, or a name with a shim (tools/skills/ is a folder)
    if not ((tool.is_file() and os.access(tool, os.X_OK)) or (root / 'tools' / (name + '.cmd')).is_file()): return
    if name in exc: used.add(name); return
    if name.endswith('.sh') or not (root / 'tools' / (name + '.cmd')).is_file():
        bad.append(f"{f.relative_to(root)}:{n}: `{text[:80]}` — {name} has no .cmd shim (PowerShell cannot run it)")
for f in files:
    fence = None
    for n, line in enumerate(f.read_text(encoding='utf-8').split('\n'), 1):
        m = re.match(r'\s*(```|~~~)\s*(\S*)', line)
        if m:
            fence = None if fence else m.group(2).lower() or 'none'; continue
        if fence is not None:
            if fence in ('none', 'sh', 'bash', 'shell', 'console', 'powershell', 'ps1', 'pwsh', 'cmd', 'bat'): check(f, n, line)
            continue
        for span in re.findall(r'`([^`\n]+)`', line): check(f, n, span)
for name in sorted(set(exc) - used):
    bad.append(f"exception '{name}' matches no command any more: remove it from tests/doc-commands-shimmed.sh")
if bad:
    print('\n'.join('FAIL: ' + b for b in bad)); sys.exit(1)
print(f'doc-commands-shimmed: ok ({len(files)} files)')
PY
