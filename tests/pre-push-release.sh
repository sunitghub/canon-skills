#!/usr/bin/env bash
# t-4ea4: canon's pre-push hook (scripts/install-hooks.sh) refuses any push to a canon.mirror remote (public) of a commit whose
# binaries are not released, whatever the route (a plain `git push public`, an agent's push); origin is untouched.
# Prod path: every push of canon to canon-skills. All remotes are local bare repos; the check script is a stub that judges
# the manifest AT the pushed commit, like the real one (tests/tkt-push-main.sh uses the same stub).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@e; git config --global init.defaultBranch main
for r in origin public; do git init -q --bare "$W/$r.git"; done
P="$W/p"; git clone -q "$W/origin.git" "$P" 2>/dev/null; cd "$P"
git remote add public "$W/public.git"; git config --add canon.mirror public
# the hook runs <repo>/tools/tkt and <repo>/scripts/check-binaries-released.sh, as in canon's own checkout
mkdir -p tools scripts .git/hooks
printf '#!/usr/bin/env bash\nexec bash "%s/tools/tkt" "$@"\n' "$ROOT" > tools/tkt
cp "$ROOT/scripts/install-hooks.sh" scripts/install-hooks.sh   # its own copy: it installs into the repo it sits in
cat > scripts/check-binaries-released.sh <<'STUB'
#!/usr/bin/env bash
[ "$1" = --rev ] || exit 2
m="$(git show "$2:tools/cockpit-daemon.sha256")" || exit 2
case "$m" in *LAG*) echo "NOT RELEASED  linux-amd64: cockpit-daemon is at abc but the newest manifest line is old" >&2; exit 1 ;; esac
exit 0
STUB
printf '.tickets/\n' > .gitignore
echo OK > tools/cockpit-daemon.sha256
git add -A; git commit -qm "released"; git push -q origin main; git push -q public main
out="$(bash scripts/install-hooks.sh)"; assert_contains "$out" "pre-push hook installed"
rm -f .git/hooks/post-commit   # it rebuilds canon's daemon (build-zip.sh), which this scratch repo does not have
bash scripts/install-hooks.sh >/dev/null; rm -f .git/hooks/post-commit   # idempotent: a second run leaves one working hook
at() { git --git-dir="$W/$1.git" rev-parse -q --verify refs/heads/main || echo none; }
pushed() { git --git-dir="$W/$1.git" cat-file -e "$2" 2>/dev/null; }

# 1. a commit whose binaries are not released: a plain push to public is refused, nothing reaches it
before="$(at public)"
echo LAG > tools/cockpit-daemon.sha256; git commit -qam "daemon change, not released"; UNREL="$(git rev-parse HEAD)"
rc=0; out="$(git push public main 2>&1)" || rc=$?
[[ "$rc" != 0 ]] || fail "a plain git push of an unreleased commit reached public"
assert_contains "$out" "pre-push: ${UNREL:0:8} is not released yet; nothing pushed"
assert_contains "$out" "NOT RELEASED  linux-amd64"
assert_contains "$out" "refused the push to public (t-4ea4)"
assert_eq "$before" "$(at public)"; pushed public "$UNREL" && fail "the unreleased commit's objects reached public"
# ...on any branch, not only main
rc=0; git push public main:refs/heads/side >/dev/null 2>&1 || rc=$?; [[ "$rc" != 0 ]] || fail "an unreleased commit reached a public branch"
# 2. origin is not a mirror: the same commit goes there
git push -q origin main; assert_eq "$UNREL" "$(at origin)"
# 3. once released, the push goes through
echo OK > tools/cockpit-daemon.sha256; git commit -qam "record the release"; REL="$(git rev-parse HEAD)"
git push -q public main; assert_eq "$REL" "$(at public)"
# 4. a branch deletion pushes nothing and is not checked
git push -q public main:refs/heads/gone; echo LAG > tools/cockpit-daemon.sha256; git commit -qam "not released again"
git push -q public :refs/heads/gone; [[ "$(git --git-dir="$W/public.git" rev-parse -q --verify refs/heads/gone || echo none)" == none ]] || fail "the deletion did not go through"
# 5. a commit that ships no binaries (no manifest in it) is not checked
git rm -q tools/cockpit-daemon.sha256; git commit -qm "no binaries here"; NOBIN="$(git rev-parse HEAD)"
git push -q public main; assert_eq "$NOBIN" "$(at public)"

echo "pre-push-release: ok (an unreleased commit is refused on public, any branch, with the release message; origin untouched; a released commit, a deletion and a no-binaries commit go through; install is idempotent)"
