#!/usr/bin/env bash
# t-2af0: scripts/integrity-list.sh writes the file list a release carries for Admin > Integrity. Protects the release (release.sh attaches
# this file and pins its hash): the list must equal the tag's tree byte for byte, name the gate files and prompts, refuse odd paths, and
# live apart from releases.txt, whose three-field lines every installed canon reads exactly.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
command -v python3 >/dev/null 2>&1 || { echo "integrity-list: skipped, no python3"; exit 0; }
LIST="$ROOT/scripts/integrity-list.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# 1. The list equals the committed tree of HEAD, byte for byte, and its printed line is the hash of the file.
mkdir "$W/out"
line="$("$LIST" v9.9.9 "$W/out" HEAD)"
json="$W/out/integrity-9.9.9.json"
[[ -f "$json" ]] || fail "integrity-list: $json was not written"
sum="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$json"; else shasum -a 256 "$json"; fi | cut -d' ' -f1)"
assert_eq "v9.9.9 $sum" "$line"
python3 -I - "$ROOT" "$json" <<'PY'
import hashlib, json, subprocess, sys
root, path = sys.argv[1:3]
d0 = json.load(open(path))
head = subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip()
def verify(d):
  assert d["tag"] == "v9.9.9" and d["commit"] == head, (d["tag"], d["commit"])
  tree = subprocess.check_output(["git", "-C", root, "ls-tree", "-r", "-z", "--name-only", "HEAD"]).decode().split("\0")[:-1]
  assert sorted(tree) == sorted(d["files"]), (set(tree) ^ set(d["files"]))
  for p in tree:
      blob = subprocess.check_output(["git", "-C", root, "cat-file", "blob", "HEAD:" + p])
      assert hashlib.sha256(blob).hexdigest() == d["files"][p], p
  assert d["gate_files"] == ["tools/sprint", "tools/gate-snapshot.sh", "tools/subagent-log.sh", "tools/evidence.sh", "tools/sprint-headless", "tools/sprint-headless-eval", "tools/gate-model.sh"], d["gate_files"]
  assert d["gate_prompts"] == ["agents/canon-reviewer.md", "agents/canon-evaluator.md", "skills/sprint/reference/review.md", "skills/sprint/reference/eval.md", "skills/sprint/reference/shared-gate-protocol.md"], d["gate_prompts"]
  for p in d["gate_files"] + d["gate_prompts"]:
      assert p in d["files"], p
  return len(tree)
n = verify(d0)
# the comparison itself must be able to fail: one extra, one missing and one changed file are each caught
import copy
extra = copy.deepcopy(d0); extra["files"]["zz-extra-file"] = "0" * 64
missing = copy.deepcopy(d0); del missing["files"][sorted(d0["files"])[0]]
changed = copy.deepcopy(d0); k = sorted(d0["files"])[0]; changed["files"][k] = "1" * 64
for name, bad in (("one extra", extra), ("one missing", missing), ("one changed", changed)):
    try:
        verify(bad)
    except AssertionError:
        continue
    raise SystemExit("integrity-list: the comparison did not catch " + name + " file")
print("integrity-list: %d files match HEAD, the gate lists are exact; an extra, a missing and a changed file are each caught" % n)
PY

# 2. Refusals: a bad tag, a missing folder, an unknown revision, and a gate path that is not in the tree.
r="$("$LIST" 0.1.0 "$W/out" HEAD 2>&1)" && fail "integrity-list: a tag without v was accepted"
assert_contains "$r" "tag must look like"
r="$("$LIST" v1.0.0 "$W/nowhere" HEAD 2>&1)" && fail "integrity-list: a missing output folder was accepted"
assert_contains "$r" "does not exist"
r="$("$LIST" v1.0.0 "$W/out" no-such-rev 2>&1)" && fail "integrity-list: an unknown revision was accepted"
assert_contains "$r" "does not exist here"
r="$("$LIST" v1.0.0 "$W/out" 2>&1)" && fail "integrity-list: with no tag in this repo the default revision should refuse"
assert_contains "$r" "does not exist here"

# 3. An odd file name (a space) stops the build: the JSON is hand-written, so the name is seen before it ships.
mkdir -p "$W/repo/scripts" && cp "$LIST" "$W/repo/scripts/"
g=(tools/sprint tools/gate-snapshot.sh tools/subagent-log.sh tools/evidence.sh tools/sprint-headless tools/sprint-headless-eval tools/gate-model.sh agents/canon-reviewer.md agents/canon-evaluator.md skills/sprint/reference/review.md skills/sprint/reference/eval.md skills/sprint/reference/shared-gate-protocol.md)
for f in "${g[@]}"; do mkdir -p "$W/repo/$(dirname "$f")"; echo x > "$W/repo/$f"; done
git -C "$W/repo" init -q -b main; git -C "$W/repo" -c user.email=t@t -c user.name=t add -A
git -C "$W/repo" -c user.email=t@t -c user.name=t commit -qm base
mkdir "$W/o2"; "$W/repo/scripts/integrity-list.sh" v1.0.0 "$W/o2" HEAD >/dev/null || fail "integrity-list: a clean fixture repo was refused"
echo y > "$W/repo/has space.txt"; git -C "$W/repo" -c user.email=t@t -c user.name=t add -A; git -C "$W/repo" -c user.email=t@t -c user.name=t commit -qm odd
r="$("$W/repo/scripts/integrity-list.sh" v1.0.1 "$W/o2" HEAD 2>&1)" && fail "integrity-list: a path with a space was accepted"
assert_contains "$r" "has a character the list does not allow"
git -C "$W/repo" rm -q "tools/gate-model.sh"; git -C "$W/repo" -c user.email=t@t -c user.name=t commit -qam nogate
git -C "$W/repo" rm -q "has space.txt"; git -C "$W/repo" -c user.email=t@t -c user.name=t commit -qm clean
r="$("$W/repo/scripts/integrity-list.sh" v1.0.2 "$W/o2" HEAD 2>&1)" && fail "integrity-list: a tree without a gate file was accepted"
assert_contains "$r" "gate path 'tools/gate-model.sh' is not in the tree"

# 4. releases.txt stays three fields: a line with a fourth is something release-manifest.sh refuses, which is why the list is pinned
#    in a file of its own.
h64="$(printf 'a%.0s' $(seq 64))"; h40="$(printf 'b%.0s' $(seq 40))"
printf '# manifest\nv1.2.3 %s %s\n' "$h64" "$h40" > "$W/m3.txt"
printf '# manifest\nv1.2.3 %s %s %s\n' "$h64" "$h40" "$h64" > "$W/m4.txt"
r="$(CANON_MANIFEST_URL="file://$W/m3.txt" bash "$ROOT/tools/release-manifest.sh" v1.2.3 2>&1)" || fail "integrity-list: a three-field line was refused: $r"
assert_eq "$h64 $h40" "$r"
r="$(CANON_MANIFEST_URL="file://$W/m4.txt" bash "$ROOT/tools/release-manifest.sh" v1.2.3 2>&1)" && fail "integrity-list: a four-field line was accepted: $r"
assert_contains "$r" "malformed"

echo "integrity-list: ok"
