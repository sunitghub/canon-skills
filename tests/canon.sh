#!/usr/bin/env bash
# canon.sh — launcher single-instance + /cockpit landing tests (t-9917).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "canon: skipped (python3/curl not both present)"
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
out="$(CC_OPEN_LOG="$CC_OPEN_LOG" PATH="$STUBDIR:$PATH" "$ROOT/tools/canon" "$PORT" 2>&1)" || true
echo "$out" | grep -qi "already running" || fail "canon: expected single-instance 'already running' message, got: $out"

# still exactly one listener on the port (the launcher didn't bind a second)
n="$(lsof -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')"
[[ "$n" == "1" ]] || fail "canon: expected exactly 1 listener after 2nd launch, found $n"

# ── T5: /cockpit landing serves the Projects page with key elements ───────────
page="$(curl -s -H 'Host: localhost' "http://127.0.0.1:$PORT/cockpit")"
grep -q "<title>Canon Cockpit</title>" <<<"$page" || fail "canon: /cockpit missing Canon Cockpit title"
grep -q "Add Project" <<<"$page" || fail "canon: /cockpit missing Add Project"
grep -q "class=\"projbar\"" <<<"$page" || fail "canon: /cockpit missing the Projects section bar"
grep -q "escAttr" <<<"$page" || fail "canon: /cockpit missing quote-safe escAttr (XSS guard)"
# the page must NOT use inline onclick with interpolated user data (uses data-attr + listeners)
grep -q "onclick=\"dereg(" <<<"$page" && fail "canon: /cockpit still has inline onclick with interpolated data (XSS risk)"

# ── Phase 2a: tab bar + iframe + persistence + card stats (t-a55a) ───────────
grep -q 'class="tab pinned active"' <<<"$page" || fail "canon: /cockpit missing pinned (non-dismissable) Projects tab"
grep -q 'data-tab="projects"' <<<"$page" || fail "canon: /cockpit Projects tab not wired"
grep -q "openProject(" <<<"$page" || fail "canon: /cockpit green > not wired to openProject"
grep -q "function closeTab" <<<"$page" || fail "canon: /cockpit missing closeTab"
grep -qE "f\.src=.?/\?project=" <<<"$page" || fail "canon: /cockpit project tab iframe not pointed at /?project="
grep -q "canon-cockpit-tabs" <<<"$page" || fail "canon: /cockpit missing localStorage tab persistence key"
grep -q "byId.get(id)" <<<"$page" || fail "canon: /cockpit restore does not drop deregistered projects"
grep -q "/api/project-stats?project=" <<<"$page" || fail "canon: /cockpit card stats not project-scoped"

# app.html (the embedded board) must carry the project-scoping fetch wrapper
board="$(curl -s -H 'Host: localhost' "http://127.0.0.1:$PORT/?project=x")"
grep -q "__canonProject" <<<"$board" || fail "canon: app.html missing the ?project fetch wrapper"
grep -q "urlTheme" <<<"$board" || fail "canon: app.html does not honor shell-passed ?theme"
grep -q "&theme=" <<<"$page" || fail "canon: project iframe src does not carry the shell theme"

# ── Phase 2b-ii: the wrapper scopes WRITE POSTs, not just reads (t-8485) ──────
# A WRITE_RE covering the editable-tab write set (status/body/demo/visual + doc)
# must be present, and the wrapper must scope POST/PUT (not only GET). The OUT
# set (cockpit/version/ci/headless) must NOT appear in WRITE_RE. t-1780:
# worktree create/unlock moved OUT of the OUT-set — they're project-scoped now.
grep -q "WRITE_RE" <<<"$board" || fail "canon: app.html missing WRITE_RE (write POSTs not scoped)"
write_re_line="$(grep -m1 "const WRITE_RE" <<<"$board")"
for tok in status body demo visual doc tickets 'worktrees\$' worktree-unlock ticket-commit; do
  grep -q "$tok" <<<"$write_re_line" || fail "canon: WRITE_RE missing the '$tok' write path"
done
for bad in cockpit version ci-workflow headless; do
  grep -q "$bad" <<<"$write_re_line" && fail "canon: WRITE_RE must NOT scope OUT-set path '$bad'"
done
# t-1780: worktrees/worktree-lock read paths must now be in READ_RE too — a
# shared multi-project instance otherwise showed the shell's launch-time
# project's worktrees under any tab (live-reproduced, Windows).
read_re_line="$(grep -m1 "const READ_RE" <<<"$board")"
for tok in worktrees worktree-lock ticket-commit; do
  grep -q "$tok" <<<"$read_re_line" || fail "canon: READ_RE missing the '$tok' read path (t-1780)"
done
# the wrapper must act on writes, not GET-only (method POST/PUT branch present)
grep -qE "method *=== *'POST'|method *=== *\"POST\"" <<<"$board" || fail "canon: fetch wrapper is still GET-only (does not scope POST writes)"

# ── Phase 3: embedded-board chrome stripped + folder-path breadcrumb (t-6a74) ─
# The marker is applied client-side from __canonProject; assert the mechanism +
# the marker-scoped hide CSS + folder-path logic are present in the served board.
grep -q "canon-proj-embed" <<<"$board" || fail "canon: app.html missing canon-proj-embed marker mechanism"
grep -q "classList.add('canon-proj-embed')" <<<"$board" || fail "canon: canon-proj-embed not applied from __canonProject context"
grep -qF 'class="brand-text"' <<<"$board" || fail "canon: brand text not wrapped in .brand-text (can't hide separately from icon)"
# hide rules present for version/theme/help, scoped to the marker (t-8d98: #s-daemon
# removed from app.html entirely — the sidebar daemon widget moved to this Cockpit
# shell's own Admin panel, so there's nothing left to hide-on-embed)
for sel in "#h-version" "#theme-toggle" "#tour-btn" ".brand-text"; do
  grep -qF "html.canon-proj-embed $sel" <<<"$board" || fail "canon: missing embed hide rule for $sel"
done
# CI button is KEPT (must NOT be in the hide list)
grep -qF "html.canon-proj-embed #btn-ci-setup" <<<"$board" && fail "canon: #btn-ci-setup must NOT be hidden in embed (CI kept per t-6a74)"
# folder-path breadcrumb: embedded shows git.root
grep -q "canon-proj-embed" <<<"$board" && grep -qE "git\??\.root" <<<"$board" || fail "canon: embedded breadcrumb does not use git.root folder path"
# must scope to canon-proj-embed, NOT the t-ddc8 body.embed agent-terminal mode
grep -qE "html\.canon-proj-embed #h-version" <<<"$board" || fail "canon: hide rules must key on canon-proj-embed"
grep -qE "body\.embed #h-version" <<<"$board" && fail "canon: must NOT hide chrome via body.embed (that's the t-ddc8 agent mode)"

# ── Phase 2b-i: shell Admin panel (t-5dc2) ───────────────────────────────────
# Admin nav item + view, daemon panel (status/version/uptime/restart), 3 tiles
# (incl. Active projects), sessions list — all from EXISTING endpoints. Plus the
# daemon uptime_secs plumbing. Assertions run on the served cockpit.html ($page).
grep -qF 'id="nav-admin"' <<<"$page" || fail "canon: missing Admin nav item"
grep -qF "showView('admin')" <<<"$page" || fail "canon: Admin nav not wired to showView"
grep -qF 'id="view-admin"' <<<"$page" || fail "canon: missing #view-admin section"
grep -qF 'id="ad-version"' <<<"$page" || fail "canon: Admin missing Current version row"
grep -qF 'id="ad-uptime"' <<<"$page" || fail "canon: Admin missing Daemon Uptime row"
grep -qF "Daemon Uptime" <<<"$page" || fail "canon: Admin Uptime row not relabeled Daemon Uptime (t-ade9)"
grep -qF 'id="ad-shell-uptime"' <<<"$page" || fail "canon: Admin missing Cockpit Uptime row (t-ade9)"
grep -qF "Cockpit Uptime" <<<"$page" || fail "canon: Admin missing Cockpit Uptime label (t-ade9)"
grep -qF "shell_uptime_secs" <<<"$page" || fail "canon: Admin should read shell_uptime_secs from /api/cockpit (t-ade9)"
grep -qF 'id="ad-restart"' <<<"$page" || fail "canon: Admin missing Restart button"
grep -qF 'id="ad-stop"' <<<"$page" || fail "canon: Admin missing Stop button (t-a30c)"
for tile in ad-tile-projects ad-tile-agents ad-tile-active; do
  grep -qF "id=\"$tile\"" <<<"$page" || fail "canon: Admin missing tile $tile"
done
grep -qF "Active projects" <<<"$page" || fail "canon: Admin third tile should be 'Active projects'"
grep -qF 'id="ad-sessions"' <<<"$page" || fail "canon: Admin missing sessions list"
grep -qF "/api/cockpit-restart" <<<"$page" || fail "canon: Admin Restart not wired to /api/cockpit-restart"
grep -qF "/api/cockpit-stop" <<<"$page" || fail "canon: Admin Stop not wired to /api/cockpit-stop (t-a30c)"
grep -qF "running_build" <<<"$page" || fail "canon: Admin uptime should read cockpit.running_build.uptime_secs"
# t-a30c: Admin's Stop is a genuinely new capability (stop WITHOUT relaunch,
# distinct from Restart's kill+relaunch) — /api/cockpit-stop is a deliberate
# addition here, not a violation of Admin reusing existing endpoints below.
for ep in "/api/cockpit" "/api/cockpit-sessions" "/api/cockpit-restart" "/api/cockpit-stop" "/api/version" "/api/projects"; do
  grep -qF "$ep" <<<"$page" || fail "canon: Admin should use existing endpoint $ep"
done
# Stop button must never call the daemon's token-gated /shutdown or reference
# a boot token — OS pid-kill only, preserving the t-ddc8 boundary (t-a30c).
grep -qF "/shutdown" <<<"$page" && fail "canon: Admin Stop must not call the daemon's /shutdown (t-ddc8)"

# daemon /version exposes uptime_secs (t-5dc2): assert the board passes it through
grep -qF "uptime_secs" <<<"$page" || fail "canon: cockpit.html does not read uptime_secs"

# t-ffb9: Admin panel debug-logging toggle — wired to /api/cockpit-debug,
# reflects debug_enabled from running_build (never trusts only client state),
# and never calls the daemon's token-gated /shutdown or references a token.
grep -qF 'id="ad-debug-toggle"' <<<"$page" || fail "canon: Admin missing debug-logging toggle"
grep -qF "/api/cockpit-debug" <<<"$page" || fail "canon: Admin debug toggle not wired to /api/cockpit-debug"
grep -qF "debug_enabled" <<<"$page" || fail "canon: Admin debug toggle should read debug_enabled from running_build"

# t-5dc2: every --col-* referenced in cockpit.html must be defined (undefined token → unstyled).
# Note: `grep -- ` so a "--col-*" pattern isn't parsed as options.
CKHTML="$ROOT/tools/sprint-check-app/cockpit.html"
for tok in $(grep -oE 'var\(--col-[a-z]+\)' "$CKHTML" | sed 's/var(//;s/)//' | sort -u); do
  grep -qF -- "${tok}:" "$CKHTML" || fail "canon: cockpit.html uses ${tok} but never defines it"
done

# ── Phase 2b-iv: Upkeep view (t-7ae6) ─────────────────────────────────────────
# t-67ab: Upkeep lives in each project tab (the board's Upkeep button), not the sidebar; no picker.
! grep -qF 'id="nav-upkeep"' <<<"$page" || fail "canon: Upkeep must not have a sidebar entry (t-67ab)"
grep -qF "showView('upkeep')" <<<"$page" || fail "canon: openUpkeepFor must show the Upkeep view"
grep -qF "type==='open-upkeep'" <<<"$page" || fail "canon: the shell must handle the board's open-upkeep message"
grep -qF 'id="view-upkeep"' <<<"$page" || fail "canon: missing #view-upkeep section"
! grep -qF 'id="up-projrow"' <<<"$page" || fail "canon: Upkeep must not have its own project picker (t-67ab)"
grep -qF 'id="up-back"' <<<"$page" || fail "canon: Upkeep missing its ← Board button"
grep -qF 'id="up-grid"' <<<"$page" || fail "canon: Upkeep missing report card grid"
grep -qF 'id="up-detail"' <<<"$page" || fail "canon: Upkeep missing the single report-detail panel"
for skill in "context-check" "context-doctor" "dead-code-cleanup" "promote-learnings"; do
  grep -qF "$skill" <<<"$page" || fail "canon: Upkeep missing skill $skill"
done
for ep in "/api/upkeep/run" "/api/upkeep/status" "/api/upkeep/report"; do
  grep -qF "$ep" <<<"$page" || fail "canon: Upkeep should call $ep"
done
# t-7ae6 grill #1/#2: Agent picker only enables Claude; Pi/Copilot are visibly
# present but disabled ("(soon)"), never silently omitted.
grep -qF "Pi (soon)" <<<"$page" || fail "canon: Upkeep Agent picker should show Pi disabled, not omit it"
grep -qF "Copilot (soon)" <<<"$page" || fail "canon: Upkeep Agent picker should show Copilot disabled, not omit it"
# Model defaults to Haiku 4.5, Sonnet 5 is the only other option.
grep -qF "Haiku 4.5" <<<"$page" || fail "canon: Upkeep Model picker missing Haiku 4.5 default"
grep -qF "Sonnet 5" <<<"$page" || fail "canon: Upkeep Model picker missing Sonnet 5 option"
# t-7ae6 grill #2: universal read-only — the client must never claim to write
# to any of these shared files itself (the dispatch prompt enforces this
# server-side via tools/upkeep-run; this just guards against a future client
# regression that adds a direct write call).
for forbidden in "standards/" "critique/canon-learnings.md"; do
  grep -qE "fetch.*$forbidden" <<<"$page" && fail "canon: Upkeep client must never write to $forbidden directly"
done

# ── Help/tour overlay (t-c5e7) ───────────────────────────────────────────────
grep -qF 'id="help-overlay"' <<<"$page" || fail "canon: missing Help overlay"
grep -qF 'id="help-btn"' <<<"$page" || fail "canon: Help button not given an id (still a stub?)"
grep -qF "openHelp()" <<<"$page" || fail "canon: Help button not wired to openHelp"
grep -qF "Help (coming soon)" <<<"$page" && fail "canon: Help is still a 'coming soon' stub"
grep -qF 'id="help-close"' <<<"$page" || fail "canon: Help overlay missing a close control"
grep -qF "closeHelp" <<<"$page" || fail "canon: Help overlay missing close handler"
grep -qF "hv-canon" <<<"$page" || fail "canon: Help missing the Versions block"
for kw in "One window" "Admin" "Update"; do
  grep -qF "$kw" <<<"$page" || fail "canon: Help content missing section '$kw'"
done
grep -qF "/api/version" <<<"$page" || fail "canon: Help should read /api/version for the Versions block"

# ── Phase 2b-iii: in-tab agent session + refresh/close guard (t-0db3) ─────────
# (a) In-tab agent session reuses the board's Resume/cockpit path: canon-proj-embed
#     must NOT hide the Resume affordance or the cockpit overlay (Part A). The board
#     ($board) is /?project=<id>-scoped so the agent runs against the tab's project.
for hidden in "card-start" "#cockpit-overlay" "\.resume"; do
  grep -qE "html\.canon-proj-embed [^{]*${hidden}" <<<"$board" && fail "canon: canon-proj-embed must NOT hide the in-tab agent affordance ($hidden)"
done
grep -q "canon-proj-embed" <<<"$board" || fail "canon: board embed marker missing (Part A relies on the ?project tab)"
# (b) Live-session detection: the shell polls /api/cockpit-sessions and matches a
#     session's project_root to the tab's project path.
grep -qF "/api/cockpit-sessions" <<<"$page" || fail "canon: 2b-iii live detection must poll /api/cockpit-sessions"
grep -qF "project_root" <<<"$page" || fail "canon: 2b-iii must match session project_root to the tab"
grep -qE "liveTabIds" <<<"$page" || fail "canon: 2b-iii missing the live-tab set"
grep -qE "function pollSessions|pollSessions *=" <<<"$page" || fail "canon: 2b-iii missing the session poller"
# (c) Guarded closeTab: warns when live, closes immediately when idle (never a
#     silent orphan/kill). Assert closeTab checks liveTabIds before removing.
#     (flatten newlines — BSD grep has no -P/-z multiline).
page_flat="$(printf '%s' "$page" | tr '\n' ' ')"
grep -qE "function closeTab\(id\)\{ *if\(liveTabIds\.has" <<<"$page_flat" || fail "canon: closeTab must consult liveTabIds (guard) before removing a tab"
grep -qF 'id="closeWarn"' <<<"$page" || fail "canon: missing close-tab warning modal"
for act in "Keep working" "End without saving" "Save &amp; End"; do
  grep -qF "$act" <<<"$page" || fail "canon: close-warn modal missing action '$act'"
done
grep -qF "confirmCloseTab" <<<"$page" || fail "canon: close-warn actions not wired to confirmCloseTab"
# (d) Save & End / End reuse the board via a shell→iframe postMessage (no new daemon surface).
grep -qF "canon-cockpit-shell" <<<"$page" || fail "canon: Save&End/End must post as source 'canon-cockpit-shell'"
grep -qE "postMessage\(\{source:'canon-cockpit-shell'" <<<"$page" || fail "canon: confirmCloseTab must postMessage to the board iframe"
# (e) beforeunload is SCOPED: guarded by live-tab presence, never unconditional.
grep -qF "beforeunload" <<<"$page" || fail "canon: missing beforeunload refresh guard"
grep -qE "addEventListener\('beforeunload', *function\(e\)\{ *if\(liveTabIds\.size" <<<"$page_flat" || fail "canon: beforeunload must be gated by liveTabIds.size (not a blanket trap)"

# app.html: the shell→board bridge listener must be ORIGIN-CHECKED (same-origin only)
# and only drive the existing Save & End / end flow — no new daemon capability.
grep -qF "canon-cockpit-shell" <<<"$board" || fail "canon: app.html missing the shell→board control listener"
grep -qF "e.origin !== location.origin" <<<"$board" || fail "canon: shell→board listener not origin-checked (same-origin)"
grep -qF "ckLeaveSaveAndEnd" <<<"$board" || fail "canon: shell→board listener must reuse the vetted ckLeaveSaveAndEnd flow"

# ── t-7485 + t-96c3: per-project Skills line + register (efficiency/sprint) ────
grep -qF 'data-f="skills"' <<<"$page" || fail "canon: card missing the Skills meta row (data-f=\"skills\")"
grep -qE "s\.skills|\.skills" <<<"$page" || fail "canon: fillCardStats must read the project-stats skills field"
grep -qF 'class="regskill"' <<<"$page" || fail "canon: missing the Register-skill button"
# t-96c3: the register buttons are generated from a single IMPORTANT_SKILLS source
grep -qE "const IMPORTANT_SKILLS *= *\['efficiency', *'sprint'\]" <<<"$page" || fail "canon: register buttons must derive from IMPORTANT_SKILLS=['efficiency','sprint']"
grep -qF "IMPORTANT_SKILLS.map(" <<<"$page" || fail "canon: register buttons must be generated from IMPORTANT_SKILLS (DRY, not hardcoded)"
grep -qF "!skills.includes(b.dataset.skill)" <<<"$page" || fail "canon: each register button must be gated on whether that skill is already registered"
grep -qF "function registerSkill" <<<"$page" || fail "canon: missing registerSkill handler"
grep -qE "querySelectorAll\('\.regskill'\)" <<<"$page" || fail "canon: register buttons not wired via a delegated handler"
grep -qF "/api/register-skill?project=" <<<"$page" || fail "canon: registerSkill must POST to /api/register-skill?project=<id>&skill=<skill>"
grep -qF "&skill=" <<<"$page" || fail "canon: registerSkill must pass the chosen skill"
grep -qF "confirm(" <<<"$page" || fail "canon: registerSkill must confirm before the mutating register"
grep -qF "unsupported" <<<"$page" || fail "canon: registerSkill must surface the copy-paste command on unsupported hosts"
# t-96c3: card meta reordered — Added is the FIRST meta row (before Updated)
page_flat="$(printf '%s' "$page" | tr '\n' ' ')"
grep -qE 'class="k">Added<.*class="k">Updated<.*class="k">Total Tickets<.*class="k">Skills<' <<<"$page_flat" || fail "canon: meta rows must be ordered Added, Updated, Total Tickets, Skills"
# t-96c3: subtle divider between meta and actions + larger action buttons + red X border
grep -qF 'class="card-divider"' <<<"$page" || fail "canon: card missing the divider between meta and actions"
grep -qE "\.go\{[^}]*width:40px" <<<"$page" || fail "canon: action buttons should be enlarged (40px)"
grep -qE "\.dereg\{[^}]*col-discarded" <<<"$page" || fail "canon: the ✕ (dereg) should carry a red border at rest"

# ── t-65b0: board (app.html) blue-grey dark theme + embed rail hide + card fold-in ─
board_flat="$(printf '%s' "$board" | tr '\n' ' ')"
# dark :root repaletted to blue-grey (not the old near-black), accent kept purple
grep -qE '\-\-bg: *#1b2330' <<<"$board_flat" || fail "canon: app.html dark --bg should be the blue-grey #1b2330"
grep -qF "#0d0d10" <<<"$board" && fail "canon: app.html still carries the old near-black #0d0d10 dark --bg"
grep -qE '\-\-accent: *#7c6af7' <<<"$board_flat" || fail "canon: app.html --accent must stay purple #7c6af7"
# light theme untouched (its --bg is still #f2f2f7)
grep -qF "#f2f2f7" <<<"$board" || fail "canon: app.html light --bg (#f2f2f7) must be unchanged"
# embed-only: the collapsed-sidebar quick-jump rail is hidden in a project tab, but the markup still exists for standalone
grep -qE "html\.canon-proj-embed \.sidebar-icon-rail *\{ *display: *none" <<<"$board" || fail "canon: the icon rail must be hidden in the embedded tab (canon-proj-embed)"
grep -qF 'class="sidebar-icon-rail"' <<<"$board" || fail "canon: the standalone icon rail markup must still be present"
# card fold-in (cockpit.html): bottom-row register buttons + right-aligned actions + tooltips
grep -qF 'class="cardbottom"' <<<"$page" || fail "canon: card missing the .cardbottom row (register buttons + actions)"
grep -qE "\.card \.actions\{[^}]*margin-left:auto" <<<"$page" || fail "canon: card actions must be right-aligned via margin-left:auto"
grep -qF 'title="Not set up in this project yet — click to register the ${sk} skill"' <<<"$page" || fail "canon: register buttons must carry a hover title tooltip"

# ── t-1b88: Add-Project Browse folder picker ─────────────────────────────────
grep -qF 'class="pathrow"' <<<"$page" || fail "canon: Add modal missing the .pathrow (input + Browse)"
grep -qF 'onclick="toggleBrowse()"' <<<"$page" || fail "canon: missing the Browse… button"
grep -qF 'id="addPath"' <<<"$page" || fail "canon: the text path input must remain (typing still works)"
grep -qF 'id="dirnav"' <<<"$page" || fail "canon: missing the folder-navigator panel"
grep -qF "/api/browse-dirs?path=" <<<"$page" || fail "canon: navigator must fetch /api/browse-dirs"
grep -qF "function loadBrowse" <<<"$page" || fail "canon: missing loadBrowse handler"
grep -qF 'onclick="useBrowseDir()"' <<<"$page" || fail "canon: missing the 'Use this folder' action"
grep -qF "getElementById('addPath').value=_browseCwd" <<<"$page" || fail "canon: 'Use this folder' must fill the path input with the chosen folder"
# t-340d: Show-hidden toggle hides dotfolders by default, opt-in via &hidden=1
grep -qF 'id="dirnav-hidden"' <<<"$page" || fail "canon: navigator missing the Show-hidden toggle"
grep -qiF "Show hidden" <<<"$page" || fail "canon: navigator missing the 'Show hidden' label"
grep -qF "&hidden=1" <<<"$page" || fail "canon: loadBrowse must pass &hidden=1 when Show-hidden is checked"
# t-07c8: submitAdd surfaces a non-blocking git warning (adds anyway), not a blocking error
grep -qF "res.warning" <<<"$page" || fail "canon: submitAdd must surface res.warning (git relaxed to a warning)"
grep -qF "⚠ Added" <<<"$page" || fail "canon: submitAdd should toast the warning alongside the add"
# t-5849: reusable canon-styled confirm replaces native confirm()/prompt()
grep -qF "function cockpitConfirm" <<<"$page" || fail "canon: missing cockpitConfirm() component"
grep -qF 'id="cconfirm"' <<<"$page" || fail "canon: missing the #cconfirm modal markup"
grep -qF 'id="cc-code"' <<<"$page" || fail "canon: confirm modal missing the copyable command field (prompt replacement)"
ccn="$(grep -c "await cockpitConfirm(" <<<"$page")"
[[ "$ccn" -ge 4 ]] || fail "canon: expected >=4 await cockpitConfirm call sites, got $ccn"
grep -qF "danger:true" <<<"$page" || fail "canon: destructive actions should use danger styling"
natives="$(grep -nE "window\.(confirm|prompt|alert)\(|[^a-zA-Z.]confirm\(|[^a-zA-Z.]prompt\(|[^a-zA-Z.]alert\(" <<<"$page" | grep -vE "cockpitConfirm|<!--|^[0-9]+:[[:space:]]*//" || true)"
[[ -z "$natives" ]] || fail "canon: native confirm/prompt/alert must be gone — found: $natives"

# ── t-5c3c: soft nudge to register sprint skill on explicit project open ─────
grep -qE "function openProject\(id,name,opts\)" <<<"$page" || fail "canon: openProject must accept an opts param (nudge flag)"
grep -qF "function maybeNudgeSkill" <<<"$page" || fail "canon: missing maybeNudgeSkill handler"
grep -qF "bar.className='skill-nudge'" <<<"$page" || fail "canon: missing the .skill-nudge banner markup"
# gated strictly on the project lacking the sprint skill (no false nudge)
grep -qF "function hasSprintSkill" <<<"$page" || fail "canon: missing hasSprintSkill helper"
grep -qE "\.skills *\|\| *\[\]\)\.includes\('sprint'\)" <<<"$page" || fail "canon: hasSprintSkill must check skills.includes('sprint')"
grep -qF "if(await hasSprintSkill(id)) return;" <<<"$page" || fail "canon: nudge must gate on hasSprintSkill(id)"
# explicit open passes {nudge:true}; tab-restore must NOT (no startup banner storm)
grep -qF "openProject(b.dataset.open,b.dataset.name,{nudge:true})" <<<"$page" || fail "canon: card '>' open must pass {nudge:true}"
# "nudge:true" must appear only at explicit-open call sites (card '>' open,
# and the #open=<id> deep link used by `sprint-check`, t-4700) — never in
# restoreTabs, which must stay silent on tab restore (no startup banner storm).
grep -q "function restoreTabs" <<<"$page" || fail "canon: missing restoreTabs"
restore_body="$(sed -n '/function restoreTabs(){/,/^  }/p' <<<"$page")"
grep -q "nudge:true" <<<"$restore_body" && fail "canon: restoreTabs must not nudge"
# t-5a4b: session-driven opens (Scratch, Continue as ticket, Agents-rail rows) nudge too, quietly — a banner
# already dismissed is not re-shown by them (nudgeDismissed).
grep -qF "openProject(proj.id,proj.name,{nudge:true,quiet:true})" <<<"$page" || fail "canon: session-driven opens must nudge quietly (openSessionInTab)"
grep -qF "nudgeDismissed" <<<"$page" || fail "canon: a dismissed nudge must be remembered for session-driven opens"
nudge_true_count="$(grep -c "nudge:true" <<<"$page")"
[[ "$nudge_true_count" == "3" ]] || fail "canon: expected exactly 3 uses of nudge:true (card open + #open= deep link + session-driven opens), got $nudge_true_count"
# Register reuses the existing registerSkill/cockpitConfirm flow; Dismiss clears the banner
grep -qE "registerSkill\(id, *name, *proj\.path" <<<"$page" || fail "canon: nudge Register button must reuse registerSkill(id,name,path,'sprint')"
grep -qF "bar.remove(); v.classList.remove('has-nudge')" <<<"$page" || fail "canon: nudge Dismiss/Register-success must remove the banner and has-nudge class"

# t-824e: server.py passes the daemon's reaper timeouts through running_build; an older daemon → 0.
# Mirrors TestCockpitRunningBuildPassesReaperTimeouts (tools/sprint-check-go).
python3 - "$ROOT/tools/sprint-check-app" <<'PY' || fail "canon: running_build must pass idle_timeout_secs / idle_timeout_main_secs through (0 when absent)"
import http.server, json, sys, threading
sys.path.insert(0, sys.argv[1])
import server
for body, want in [
    ({'version': 'v', 'exe_mtime': 1, 'uptime_secs': 2, 'debug_enabled': True, 'idle_timeout_secs': 300, 'idle_timeout_main_secs': 1800}, (300, 1800)),
    ({'version': 'v', 'exe_mtime': 1, 'uptime_secs': 2, 'debug_enabled': False}, (0, 0)),
]:
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            data = json.dumps(body).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        def log_message(self, *a): pass
    srv = http.server.HTTPServer(('127.0.0.1', 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    got = server._cockpit_running_build('127.0.0.1:%d' % srv.server_address[1])
    srv.shutdown()
    assert got and (got['idle_timeout_secs'], got['idle_timeout_main_secs']) == want and got['version'] == 'v', got
PY

# ── t-302d: the browser opens only once the board answers /api/version ────────
# A copy of the launcher with a stub server.py (starts answering after STUB_DELAY, or exits at once, or never
# listens) and a stub opener that records whether the port answered AT THE MOMENT it was called.
LT="$WORK/launch-tools"; mkdir -p "$LT/sprint-check-app" "$WORK/ostub"
cp "$ROOT/tools/canon" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$LT/"
echo 0.0.0 > "$WORK/VERSION"
cat > "$LT/sprint-check-app/server.py" <<'PY'
import http.server, os, sys, time
port = int(sys.argv[1]); mode = os.environ.get('STUB_MODE', 'serve')
if mode == 'exit': sys.exit(3)
if mode == 'never': time.sleep(600)
time.sleep(float(os.environ.get('STUB_DELAY', '0')))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
for o in open xdg-open; do
  cat > "$WORK/ostub/$o" <<'SH'
#!/usr/bin/env bash
if curl -s -f -o /dev/null --max-time 1 "http://127.0.0.1:$CC_PORT/api/version"; then s=UP; else s=DOWN; fi
echo "OPEN $1 $s" >> "$CC_OPEN_LOG"
SH
  chmod +x "$WORK/ostub/$o"
done
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

# run_launcher <mode> <delay> <wait_secs> -> sets L_OUT, L_CODE, L_OPENS (the opener log); never leaves a server behind
run_launcher() {
  local mode="$1" delay="$2" wait="$3" lp lpid
  lp="$(free_port)"; : > "$WORK/open2.log"
  CC_PORT="$lp" CC_OPEN_LOG="$WORK/open2.log" STUB_MODE="$mode" STUB_DELAY="$delay" CANON_BOARD_WAIT_SECS="$wait" \
    COCKPIT_DAEMON_BIN=/bin/true PATH="$WORK/ostub:$PATH" "$LT/canon" "$lp" >"$WORK/launch.out" 2>&1 &
  lpid=$!
  if [[ "$mode" == serve ]]; then   # the launcher blocks after opening: wait for the opener, then stop it
    for _ in $(seq 1 120); do [[ -s "$WORK/open2.log" ]] && break; sleep 0.1; done
    sleep 0.3; kill "$lpid" 2>/dev/null || true
  fi
  L_CODE=0; wait "$lpid" 2>/dev/null || L_CODE=$?
  L_OUT="$(cat "$WORK/launch.out")"; L_OPENS="$(cat "$WORK/open2.log")"
  sleep 0.2
  ! lsof -iTCP:"$lp" -sTCP:LISTEN -t >/dev/null 2>&1 || fail "canon: a stub board is still listening on $lp after the launcher ended"
}

for pair in "abc:10" "0:10" "-3:10" "2:2" "12:12" ':10'; do   # the window is a positive integer, else 10 (never raw env into arithmetic)
  [[ "$(CANON_BOARD_WAIT_SECS="${pair%%:*}" bash -c 'source "$1"; _board_wait_secs' _ "$LT/cockpit-launch-lib.sh")" == "${pair##*:}" ]] \
    || fail "canon: _board_wait_secs for '${pair%%:*}' should be ${pair##*:}"
done
for d in 0.2 1.5 3.0; do
  run_launcher serve "$d" 10
  [[ "$(printf '%s\n' "$L_OPENS" | grep -c '^OPEN ')" == 1 ]] || fail "canon: board answering after ${d}s: want exactly 1 browser open, got: $L_OPENS ($L_OUT)"
  [[ "$L_OPENS" == *" UP" ]] || fail "canon: browser opened before the board answered (delay ${d}s): $L_OPENS"
done

run_launcher exit 0 10
[[ -z "$L_OPENS" && "$L_CODE" == 1 ]] || fail "canon: board that exits at once: want no open and exit 1, got code $L_CODE opens '$L_OPENS'"
[[ "$L_OUT" == *"exited before it was ready"* ]] || fail "canon: exited-board message missing: $L_OUT"

run_launcher never 0 2
[[ -z "$L_OPENS" && "$L_CODE" == 1 ]] || fail "canon: board that never answers: want no open and exit 1, got code $L_CODE opens '$L_OPENS'"
[[ "$L_OUT" == *"did not answer on port"* ]] || fail "canon: timeout message missing: $L_OUT"

echo "canon: ok (t-302d browser opens only after /api/version answers (0.2/1.5/3.0 s starts, dead board, silent board); single-instance no-2nd-server; /cockpit serves Projects page with section bar + Add + quote-safe escaping; Phase 2a tab bar + iframe /?project= + localStorage persistence + project-scoped card stats; app.html carries the project fetch wrapper + theme sync; Phase 3 embed marker strips version/daemon/theme/help, keeps CI, folder-path breadcrumb, scoped to canon-proj-embed not body.embed; Phase 2b-i Admin view — daemon status/version/uptime/restart + 3 tiles incl Active projects + sessions list, reusing existing endpoints, uptime_secs plumbed; shell Help/tour overlay wired to the footer button + Versions from existing endpoints; Phase 2b-iv Upkeep view — nav/view/project-picker/report-grid/single-detail-panel present, all 4 skills, Agent picker shows Pi/Copilot disabled not omitted, Model defaults Haiku 4.5, client never writes directly to standards/ or critique/canon-learnings.md; Phase 2b-iii in-tab agent session reuse + live-session poller + guarded closeTab/close-warn modal + scoped beforeunload + origin-checked shell→board Save&End bridge; t-7485/t-96c3 per-project Skills row + register efficiency/sprint from IMPORTANT_SKILLS, reordered meta, divider, larger actions, red ✕; t-65b0 board blue-grey dark theme (light untouched) + embed rail hide + card bottom-row/tooltips; t-1b88 Add-Project Browse folder picker via /api/browse-dirs; t-340d hide dotfolders by default + Show-hidden toggle; t-07c8 git relaxed to a warning + no-store HTML; t-5849 canon-styled cockpitConfirm replaces native confirm/prompt; t-5c3c soft nudge to register sprint skill on explicit project open, session-scoped dismiss, no restore-time banner storm)"
