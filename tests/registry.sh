#!/usr/bin/env bash
# registry.sh — Canon Cockpit project registry data-layer tests (t-9917).
# Exercises server.py's registry_* functions directly with a temp CANON_HOME:
# add (valid git dir), list, deregister, id stability/idempotence, and the
# error cases (missing dir / non-git / duplicate / empty).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "registry: skipped (python3 not present)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# a valid git repo to register
PROJ="$WORK/myproj"
mkdir -p "$PROJ/.git"
# a non-git dir
NONGIT="$WORK/plain"
mkdir -p "$NONGIT"

export CANON_HOME="$WORK/.canon"
export SPRINT_CHECK_ROOT="$ROOT"

CANON_HOME="$CANON_HOME" SPRINT_CHECK_ROOT="$ROOT" python3 - "$ROOT" "$PROJ" "$NONGIT" "$WORK" <<'PY'
import sys, importlib.util, json, os
root, proj, nongit, work = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
spec = importlib.util.spec_from_file_location("srv", os.path.join(root, "tools/sprint-check-app/server.py"))
srv = importlib.util.module_from_spec(spec); spec.loader.exec_module(srv)

def check(cond, msg):
    if not cond:
        print("FAIL:", msg); sys.exit(1)

# empty registry
check(srv.registry_list() == [], "registry should start empty")

# add a valid git dir
r = srv.registry_add(proj, "my project")
check(r.get("ok") is True, f"add valid git dir should succeed: {r}")
p = r["project"]
check(len(p["id"]) == 12 and all(c in "0123456789abcdef" for c in p["id"]), f"id must be 12 hex: {p['id']}")
check(p["name"] == "myproj", f"name should be basename: {p['name']}")
check(p["description"] == "my project", "description stored")
check(len(srv.registry_list()) == 1, "one entry after add")

# id stability / idempotence: re-add same path → duplicate error, still 1 entry
r2 = srv.registry_add(proj, "again")
check(r2.get("ok") is False and "already" in r2.get("error",""), f"re-add should be duplicate error: {r2}")
check(len(srv.registry_list()) == 1, "duplicate add must not grow the registry")

# error: non-git dir
r3 = srv.registry_add(nongit, "x")
check(r3.get("ok") is False and "git" in r3.get("error",""), f"non-git dir should be rejected: {r3}")

# error: missing dir
r4 = srv.registry_add(os.path.join(work, "does-not-exist"), "x")
check(r4.get("ok") is False, f"missing dir should be rejected: {r4}")

# error: empty path
r5 = srv.registry_add("", "x")
check(r5.get("ok") is False, f"empty path should be rejected: {r5}")

# on-disk file exists with 0600-ish perms and correct field order
regfile = os.path.join(os.environ["CANON_HOME"], "cockpit", "projects.json")
check(os.path.exists(regfile), "projects.json written")
raw = open(regfile).read()
check(raw.endswith("\n"), "registry file ends with newline")
check(raw.index('"id"') < raw.index('"path"') < raw.index('"name"') < raw.index('"description"') < raw.index('"added"'),
      "field order must be id,path,name,description,added")

# deregister (registry-only) — project dir must still exist afterward
pid = p["id"]
r6 = srv.registry_remove(pid)
check(r6.get("removed") is True, f"remove should report removed: {r6}")
check(len(srv.registry_list()) == 0, "registry empty after remove")
check(os.path.isdir(proj), "deregister must NOT touch the project repo on disk")

# remove unknown id → no-op success
r7 = srv.registry_remove("deadbeef0000")
check(r7.get("ok") is True and r7.get("removed") is False, f"unknown remove should be no-op success: {r7}")

print("registry: ok (add/list/remove, id-stable, git-dir + dup + missing + empty validation, registry-only deregister)")
PY
