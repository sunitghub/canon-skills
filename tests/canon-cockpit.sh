#!/usr/bin/env bash
# canon-cockpit.sh — launcher single-instance + /cockpit landing tests (t-9917).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "canon-cockpit: skipped (python3/curl not both present)"
  exit 0
fi

# ── T4: single-instance — a second launch must NOT start a second server ──────
# We simulate "already running" by occupying the port with a server, then assert
# the launcher's port-in-use path is taken (it prints "already running" + opens
# the URL rather than binding). We drive the launcher with a stub browser opener
# and a very short timeout so it can't block.

PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [[ -n "${SRV:-}" ]] && kill "$SRV" 2>/dev/null || true' EXIT

# occupy the port with the real server
CANON_HOME="$WORK/.canon" SPRINT_CHECK_ROOT="$ROOT" python3 "$ROOT/tools/sprint-check-app/server.py" "$PORT" >/dev/null 2>&1 &
SRV=$!
for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/projects" && break; sleep 0.1; done

# launcher with a stubbed browser opener on PATH so it can't actually open a browser
STUBDIR="$WORK/stub"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/open" <<'SH'
#!/usr/bin/env bash
echo "STUB-OPEN $*" >> "$CC_OPEN_LOG"
SH
chmod +x "$STUBDIR/open"

CC_OPEN_LOG="$WORK/open.log"; : > "$CC_OPEN_LOG"
# Run the launcher; because the port is in use it must hit the single-instance
# branch (print "already running", open URL, exit 0) WITHOUT starting a server.
out="$(CC_OPEN_LOG="$CC_OPEN_LOG" PATH="$STUBDIR:$PATH" "$ROOT/tools/canon-cockpit" "$PORT" 2>&1)" || true
echo "$out" | grep -qi "already running" || fail "canon-cockpit: expected single-instance 'already running' message, got: $out"

# still exactly one listener on the port (the launcher didn't bind a second)
n="$(lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')"
[[ "$n" == "1" ]] || fail "canon-cockpit: expected exactly 1 listener after 2nd launch, found $n"

# ── T5: /cockpit landing serves the Projects page with key elements ───────────
page="$(curl -s -H 'Host: localhost' "http://127.0.0.1:$PORT/cockpit")"
grep -q "<title>Canon Cockpit</title>" <<<"$page" || fail "canon-cockpit: /cockpit missing Canon Cockpit title"
grep -q "Add Project" <<<"$page" || fail "canon-cockpit: /cockpit missing Add Project"
grep -q "projFilter" <<<"$page" || fail "canon-cockpit: /cockpit missing project filter dropdown"
grep -q "escAttr" <<<"$page" || fail "canon-cockpit: /cockpit missing quote-safe escAttr (XSS guard)"
# the page must NOT use inline onclick with interpolated user data (uses data-attr + listeners)
grep -q "onclick=\"dereg(" <<<"$page" && fail "canon-cockpit: /cockpit still has inline onclick with interpolated data (XSS risk)"

# ── Phase 2a: tab bar + iframe + persistence + card stats (t-a55a) ───────────
grep -q 'class="tab pinned active"' <<<"$page" || fail "canon-cockpit: /cockpit missing pinned (non-dismissable) Projects tab"
grep -q 'data-tab="projects"' <<<"$page" || fail "canon-cockpit: /cockpit Projects tab not wired"
grep -q "openProject(" <<<"$page" || fail "canon-cockpit: /cockpit green > not wired to openProject"
grep -q "function closeTab" <<<"$page" || fail "canon-cockpit: /cockpit missing closeTab"
grep -qE "f\.src=.?/\?project=" <<<"$page" || fail "canon-cockpit: /cockpit project tab iframe not pointed at /?project="
grep -q "canon-cockpit-tabs" <<<"$page" || fail "canon-cockpit: /cockpit missing localStorage tab persistence key"
grep -q "byId.get(id)" <<<"$page" || fail "canon-cockpit: /cockpit restore does not drop deregistered projects"
grep -q "/api/project-stats?project=" <<<"$page" || fail "canon-cockpit: /cockpit card stats not project-scoped"

# app.html (the embedded board) must carry the project-scoping fetch wrapper
board="$(curl -s -H 'Host: localhost' "http://127.0.0.1:$PORT/?project=x")"
grep -q "__canonProject" <<<"$board" || fail "canon-cockpit: app.html missing the ?project fetch wrapper"
grep -q "urlTheme" <<<"$board" || fail "canon-cockpit: app.html does not honor shell-passed ?theme"
grep -q "&theme=" <<<"$page" || fail "canon-cockpit: project iframe src does not carry the shell theme"

# ── Phase 2b-ii: the wrapper scopes WRITE POSTs, not just reads (t-8485) ──────
# A WRITE_RE covering the editable-tab write set (status/body/demo/visual + doc)
# must be present, and the wrapper must scope POST/PUT (not only GET). The OUT
# set (cockpit/version/worktrees/ci/headless) must NOT appear in WRITE_RE.
grep -q "WRITE_RE" <<<"$board" || fail "canon-cockpit: app.html missing WRITE_RE (write POSTs not scoped)"
write_re_line="$(grep -m1 "const WRITE_RE" <<<"$board")"
for tok in status body demo visual doc tickets; do
  grep -q "$tok" <<<"$write_re_line" || fail "canon-cockpit: WRITE_RE missing the '$tok' write path"
done
for bad in cockpit version worktree ci-workflow headless; do
  grep -q "$bad" <<<"$write_re_line" && fail "canon-cockpit: WRITE_RE must NOT scope OUT-set path '$bad'"
done
# the wrapper must act on writes, not GET-only (method POST/PUT branch present)
grep -qE "method *=== *'POST'|method *=== *\"POST\"" <<<"$board" || fail "canon-cockpit: fetch wrapper is still GET-only (does not scope POST writes)"

# ── Phase 3: embedded-board chrome stripped + folder-path breadcrumb (t-6a74) ─
# The marker is applied client-side from __canonProject; assert the mechanism +
# the marker-scoped hide CSS + folder-path logic are present in the served board.
grep -q "canon-proj-embed" <<<"$board" || fail "canon-cockpit: app.html missing canon-proj-embed marker mechanism"
grep -q "classList.add('canon-proj-embed')" <<<"$board" || fail "canon-cockpit: canon-proj-embed not applied from __canonProject context"
grep -qF 'class="brand-text"' <<<"$board" || fail "canon-cockpit: brand text not wrapped in .brand-text (can't hide separately from icon)"
# hide rules present for version/daemon/theme/help, scoped to the marker
for sel in "#h-version" "#s-daemon" "#theme-toggle" "#tour-btn" ".brand-text"; do
  grep -qF "html.canon-proj-embed $sel" <<<"$board" || fail "canon-cockpit: missing embed hide rule for $sel"
done
# CI button is KEPT (must NOT be in the hide list)
grep -qF "html.canon-proj-embed #btn-ci-setup" <<<"$board" && fail "canon-cockpit: #btn-ci-setup must NOT be hidden in embed (CI kept per t-6a74)"
# folder-path breadcrumb: embedded shows git.root
grep -q "canon-proj-embed" <<<"$board" && grep -qE "git\??\.root" <<<"$board" || fail "canon-cockpit: embedded breadcrumb does not use git.root folder path"
# must scope to canon-proj-embed, NOT the t-ddc8 body.embed agent-terminal mode
grep -qE "html\.canon-proj-embed #h-version" <<<"$board" || fail "canon-cockpit: hide rules must key on canon-proj-embed"
grep -qE "body\.embed #h-version|body\.embed #s-daemon" <<<"$board" && fail "canon-cockpit: must NOT hide chrome via body.embed (that's the t-ddc8 agent mode)"

# ── Phase 2b-i: shell Admin panel (t-5dc2) ───────────────────────────────────
# Admin nav item + view, daemon panel (status/version/uptime/restart), 3 tiles
# (incl. Active projects), sessions list — all from EXISTING endpoints. Plus the
# daemon uptime_secs plumbing. Assertions run on the served cockpit.html ($page).
grep -qF 'id="nav-admin"' <<<"$page" || fail "canon-cockpit: missing Admin nav item"
grep -qF "showView('admin')" <<<"$page" || fail "canon-cockpit: Admin nav not wired to showView"
grep -qF 'id="view-admin"' <<<"$page" || fail "canon-cockpit: missing #view-admin section"
grep -qF 'id="ad-version"' <<<"$page" || fail "canon-cockpit: Admin missing Current version row"
grep -qF 'id="ad-uptime"' <<<"$page" || fail "canon-cockpit: Admin missing Uptime row"
grep -qF 'id="ad-restart"' <<<"$page" || fail "canon-cockpit: Admin missing Restart button"
for tile in ad-tile-projects ad-tile-agents ad-tile-active; do
  grep -qF "id=\"$tile\"" <<<"$page" || fail "canon-cockpit: Admin missing tile $tile"
done
grep -qF "Active projects" <<<"$page" || fail "canon-cockpit: Admin third tile should be 'Active projects'"
grep -qF 'id="ad-sessions"' <<<"$page" || fail "canon-cockpit: Admin missing sessions list"
grep -qF "/api/cockpit-restart" <<<"$page" || fail "canon-cockpit: Admin Restart not wired to /api/cockpit-restart"
grep -qF "running_build" <<<"$page" || fail "canon-cockpit: Admin uptime should read cockpit.running_build.uptime_secs"
# Admin must NOT introduce a NEW /api route — only reuse existing ones
for ep in "/api/cockpit" "/api/cockpit-sessions" "/api/cockpit-restart" "/api/version" "/api/projects"; do
  grep -qF "$ep" <<<"$page" || fail "canon-cockpit: Admin should use existing endpoint $ep"
done

# daemon /version exposes uptime_secs (t-5dc2): assert the board passes it through
grep -qF "uptime_secs" <<<"$page" || fail "canon-cockpit: cockpit.html does not read uptime_secs"

# t-5dc2: every --col-* referenced in cockpit.html must be defined (undefined token → unstyled).
# Note: `grep -- ` so a "--col-*" pattern isn't parsed as options.
CKHTML="$ROOT/tools/sprint-check-app/cockpit.html"
for tok in $(grep -oE 'var\(--col-[a-z]+\)' "$CKHTML" | sed 's/var(//;s/)//' | sort -u); do
  grep -qF -- "${tok}:" "$CKHTML" || fail "canon-cockpit: cockpit.html uses ${tok} but never defines it"
done

# ── Help/tour overlay (t-c5e7) ───────────────────────────────────────────────
grep -qF 'id="help-overlay"' <<<"$page" || fail "canon-cockpit: missing Help overlay"
grep -qF 'id="help-btn"' <<<"$page" || fail "canon-cockpit: Help button not given an id (still a stub?)"
grep -qF "openHelp()" <<<"$page" || fail "canon-cockpit: Help button not wired to openHelp"
grep -qF "Help (coming soon)" <<<"$page" && fail "canon-cockpit: Help is still a 'coming soon' stub"
grep -qF 'id="help-close"' <<<"$page" || fail "canon-cockpit: Help overlay missing a close control"
grep -qF "closeHelp" <<<"$page" || fail "canon-cockpit: Help overlay missing close handler"
grep -qF "hv-canon" <<<"$page" || fail "canon-cockpit: Help missing the Versions block"
for kw in "One window" "Admin" "Coming next"; do
  grep -qF "$kw" <<<"$page" || fail "canon-cockpit: Help content missing section '$kw'"
done
grep -qF "/api/version" <<<"$page" || fail "canon-cockpit: Help should read /api/version for the Versions block"

# ── Phase 2b-iii: in-tab agent session + refresh/close guard (t-0db3) ─────────
# (a) In-tab agent session reuses the board's Resume/cockpit path: canon-proj-embed
#     must NOT hide the Resume affordance or the cockpit overlay (Part A). The board
#     ($board) is /?project=<id>-scoped so the agent runs against the tab's project.
for hidden in "card-start" "#cockpit-overlay" "\.resume"; do
  grep -qE "html\.canon-proj-embed [^{]*${hidden}" <<<"$board" && fail "canon-cockpit: canon-proj-embed must NOT hide the in-tab agent affordance ($hidden)"
done
grep -q "canon-proj-embed" <<<"$board" || fail "canon-cockpit: board embed marker missing (Part A relies on the ?project tab)"
# (b) Live-session detection: the shell polls /api/cockpit-sessions and matches a
#     session's project_root to the tab's project path.
grep -qF "/api/cockpit-sessions" <<<"$page" || fail "canon-cockpit: 2b-iii live detection must poll /api/cockpit-sessions"
grep -qF "project_root" <<<"$page" || fail "canon-cockpit: 2b-iii must match session project_root to the tab"
grep -qE "liveTabIds" <<<"$page" || fail "canon-cockpit: 2b-iii missing the live-tab set"
grep -qE "function pollSessions|pollSessions *=" <<<"$page" || fail "canon-cockpit: 2b-iii missing the session poller"
# (c) Guarded closeTab: warns when live, closes immediately when idle (never a
#     silent orphan/kill). Assert closeTab checks liveTabIds before removing.
#     (flatten newlines — BSD grep has no -P/-z multiline).
page_flat="$(printf '%s' "$page" | tr '\n' ' ')"
grep -qE "function closeTab\(id\)\{ *if\(liveTabIds\.has" <<<"$page_flat" || fail "canon-cockpit: closeTab must consult liveTabIds (guard) before removing a tab"
grep -qF 'id="closeWarn"' <<<"$page" || fail "canon-cockpit: missing close-tab warning modal"
for act in "Keep working" "End without saving" "Save &amp; End"; do
  grep -qF "$act" <<<"$page" || fail "canon-cockpit: close-warn modal missing action '$act'"
done
grep -qF "confirmCloseTab" <<<"$page" || fail "canon-cockpit: close-warn actions not wired to confirmCloseTab"
# (d) Save & End / End reuse the board via a shell→iframe postMessage (no new daemon surface).
grep -qF "canon-cockpit-shell" <<<"$page" || fail "canon-cockpit: Save&End/End must post as source 'canon-cockpit-shell'"
grep -qE "postMessage\(\{source:'canon-cockpit-shell'" <<<"$page" || fail "canon-cockpit: confirmCloseTab must postMessage to the board iframe"
# (e) beforeunload is SCOPED: guarded by live-tab presence, never unconditional.
grep -qF "beforeunload" <<<"$page" || fail "canon-cockpit: missing beforeunload refresh guard"
grep -qE "addEventListener\('beforeunload', *function\(e\)\{ *if\(liveTabIds\.size" <<<"$page_flat" || fail "canon-cockpit: beforeunload must be gated by liveTabIds.size (not a blanket trap)"

# app.html: the shell→board bridge listener must be ORIGIN-CHECKED (same-origin only)
# and only drive the existing Save & End / end flow — no new daemon capability.
grep -qF "canon-cockpit-shell" <<<"$board" || fail "canon-cockpit: app.html missing the shell→board control listener"
grep -qF "e.origin !== location.origin" <<<"$board" || fail "canon-cockpit: shell→board listener not origin-checked (same-origin)"
grep -qF "ckLeaveSaveAndEnd" <<<"$board" || fail "canon-cockpit: shell→board listener must reuse the vetted ckLeaveSaveAndEnd flow"

echo "canon-cockpit: ok (single-instance no-2nd-server; /cockpit serves Projects page with filter + Add + quote-safe escaping; Phase 2a tab bar + iframe /?project= + localStorage persistence + project-scoped card stats; app.html carries the project fetch wrapper + theme sync; Phase 3 embed marker strips version/daemon/theme/help, keeps CI, folder-path breadcrumb, scoped to canon-proj-embed not body.embed; Phase 2b-i Admin view — daemon status/version/uptime/restart + 3 tiles incl Active projects + sessions list, reusing existing endpoints, uptime_secs plumbed; shell Help/tour overlay wired to the footer button + Versions from existing endpoints; Phase 2b-iii in-tab agent session reuse + live-session poller + guarded closeTab/close-warn modal + scoped beforeunload + origin-checked shell→board Save&End bridge)"
