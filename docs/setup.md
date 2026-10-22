# Canon Setup

> **Windows 11 — no WSL, no git clone needed:** in PowerShell run `irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex`. It offers to install Git for Windows (for its bash) with winget, fetches canon into `%USERPROFILE%\.canon`, and adds its tools to your PATH; re-run it, or run `canon update`, to update. Already have a clone? Install [Git for Windows](https://git-scm.com/download/win), then:
> 1. Run **`install.cmd`** once (double-click it, or run `install.cmd` from any terminal) — it launches `install.ps1` for you and adds `tools/` to your user PATH. Running `install.ps1` directly can fail with *"not digitally signed … UnauthorizedAccess"* (Windows' PowerShell execution policy blocking unsigned scripts); `install.cmd` sidesteps it with a process-scoped bypass, or run `powershell -ExecutionPolicy Bypass -File .\install.ps1` manually.
> 2. Use **Git Bash** to clone canon and run `git pull` to stay updated.
> 3. Use **PowerShell** for everything else: `sprint-check-win` opens the board; create and manage tickets through the UI.
>
> For agent-driven workflows (`sprint`, `tkt`, `skills.sh`), run those commands from Git Bash. WSL2 also works — see [fresh-machine-test.md → Windows 11](fresh-machine-test.md#windows-11).

## Install

**Step 1 — Clone canon**

Use the one-line installer from the [README](https://github.com/sunitghub/canon-skills#canon), or clone manually:

```bash
git clone --depth 1 https://github.com/sunitghub/canon-skills.git ~/.canon
```

The one-line installer makes the same shallow clone (`--depth 1`): about 20 MB, not the roughly 415 MB of full history. `canon update` keeps working on it. For the full history of `main`, run `git -C ~/.canon fetch --unshallow`; other branches are not fetched by a shallow clone (`git -C ~/.canon remote set-branches origin '*'` then `git -C ~/.canon fetch` adds them).

The Cockpit's board and its agent sessions (Scratch, Start sprint) are two small Go programs: the **board** (`tools/sprint-check-bin/sprint-check`) and the **cockpit daemon**. A clone has only their source, so the one-line installer, `canon update` and every `canon` start fetch the prebuilt binaries for your Mac or Linux machine from a canon-skills release and run it only after its SHA-256 matches `tools/cockpit-daemon.sha256`. If the download is unavailable (or the source is a committed change not yet released) they build it from source when Go 1.26.5 or newer is installed (`brew install go`), otherwise they print what to do. After a manual `git clone` or `git pull`, run `canon update` to fetch or refresh it. On Windows the same fetch provides `cockpit-daemon-win.exe` and `sprint-check-win.exe` (the board): the installer and `canon update` download them, check each against `tools/cockpit-daemon.sha256`, and keep the ones you already have if a download fails (they are no longer committed). Third-party licenses for the modules compiled into the daemon are in `THIRD-PARTY-NOTICES.md`.

**Custom location.** `CANON_HOME=/path/to/dir bash <(curl -fsSL https://getcanon.dev/install.sh)` installs to that folder instead of `~/.canon`.

**Step 2 — Run init (once)**

```bash
~/.canon/tools/skills.sh init
```

Installs a git-native `.git/hooks/pre-commit` (enforcement: ticket-direct-close block, high-risk Sign-off gate, test suite, wrapup reminder). If a pre-commit hook from another tool already exists, `skills.sh add` asks before moving it to `.git/hooks/pre-commit.local`; canon's hook then runs it first and fails the commit with its exit code, and removing the hook restores it. With no terminal, or on a no, it changes nothing and prints a `mv … && skills.sh refresh` command that does the same without a prompt. It also copies the Pi handoff extension when Pi is installed. Canon installs zero Claude Code hooks in `.claude/settings.json` — `HANDOFF.md` is read explicitly by sprint's `sprint start` step and refreshed explicitly by `wrapup`'s doc-refresh step, not injected by a hook. Re-run if you move the canon folder.

**Step 3 — Register sprint in your project**

```bash
cd /path/to/your-project
~/.canon/tools/skills.sh add sprint
```

If prompted to add canon tools to PATH, answer `y`, then run the printed `source ~/.zshrc` or `source ~/.bashrc`. Verify with `skills.sh status`.

`add sprint` pulls in the full workflow dependency stack automatically. Most projects need nothing else. Add optional skills individually when a project needs them.

`skills.sh add` writes skill registration to `AGENTS.md` (the file Codex and Pi read natively). Claude Code reads `CLAUDE.md` instead, so `add` also creates `CLAUDE.md` with a single `@AGENTS.md` import the first time you register a skill — bridging the two so Claude Code actually sees what's registered. If `CLAUDE.md` already exists without that import, `add` prompts before appending it rather than touching your existing content silently.

**Start Claude Code in the project folder, after `add`.** `add` also links canon's close-gate agents (`canon-reviewer`, `canon-evaluator`) into `.claude/agents/`, and Claude Code loads agents only when a session starts, from the folder it starts in. A session already running, or started in another folder, closes on a fallback instead; `sprint start` warns when that is the case and names the folder to restart in.

**Open the Cockpit**

Run `canon`. It opens the Cockpit at `http://127.0.0.1:8899/cockpit`; a second run focuses the same window. To use another port, run `canon <port>` or set `CANON_COCKPIT_PORT`.

### Uninstall

You don't need to close the Cockpit first: `canon uninstall` stops this install's own board and daemon itself. Run it from an ordinary terminal, not from a terminal inside the Cockpit (a Scratch session): it refuses there, because stopping the Cockpit would end the command itself.

```bash
canon uninstall --dry-run    # print the plan, change nothing
canon uninstall              # print the plan, ask, then remove
```

Tested on macOS and, on Windows 11, from PowerShell (full removal and `--keep-data`). cmd (`canon.cmd`) and Git Bash run the same bash script but were not tested on a real machine; Linux follows the macOS path and is untested. The macOS and Linux Cockpit stop (board, daemon, runtime state) is verified on a Mac with throwaway processes and the real daemon binary; on Windows it is stop-by-path (only this install's `sprint-check-win.exe` is recognised as its board) and was exercised only against stubs until a VM run. Options: `--yes` skips the prompt (with no terminal and no `--yes` it only prints the plan and exits 2), `--keep-data` keeps the Cockpit data (`~/.canon/cockpit`: project registrations and the restore snapshots of projects without git) and your skills registrations, `--force` also ends live agent sessions (without it, running sessions make the uninstall refuse and name how many).

What it does, in order: stops this install's Cockpit daemon and board (found by the pid and port they record and checked against this install, never by name; it refuses while agent sessions are live unless `--force`, and signals with SIGTERM only (on Windows `Stop-Process`, which cannot be graceful), so a process that will not exit is reported and nothing is deleted), runs `skills.sh uninstall` for every project registered with skills.sh or the Cockpit (git pre-commit hook, legacy Claude Code hooks, skill and agent symlinks, canon imports, the Pi handoff extension, `~/.config/canon`), removes empty `.claude/` and `.agents/` folders it leaves, deletes the Cockpit data, the daemon's runtime state in the temp folder (`canon-cockpit-board`, one per machine, so a reinstall shows no stale "session was running" banner; a second canon install whose daemon is running keeps its own) and the install folder, and on Windows removes `<install>\tools` from your user PATH (the old PATH value is printed first; a PowerShell helper deletes the folder after the command exits and writes its result to a log).

Left on purpose: your projects' `.gitignore` canon lines, the `.gitattributes` canon block, the `@` imports in `AGENTS.md` and `CLAUDE.md`, `PROMOTED.md` and `.tickets/`. Shell rc lines such as `export PATH="$PATH:<install>/tools"` are reported with file and line number, never edited.

Safety: the install folder is deleted only when it is a canon install (`tools/canon` and `tools/skills.sh` exist, it matches `~/.config/canon/install_path` when that file exists, it is not `/` or your home folder or a parent of it) and, if it is a git clone, when it has no uncommitted or untracked changes, an upstream branch with nothing unpushed, no local branch with commits on no remote, no stash, no linked worktree and no skip-worktree edits. Otherwise it is kept and the exact `rm -rf` is printed, even with `--yes`. Any other process running from the install folder blocks the run; it is never killed.

## Session continuity

No hooks fire automatically for this — canon installs zero Claude Code hooks. `sprint start`'s
context step explicitly reads `HANDOFF.md` at the start of a sprint; `wrapup`'s doc-refresh step
explicitly updates it at close. Keep the content inside `HANDOFF.md`'s `<!-- canon:handoff:BEGIN/END -->`
markers under 80 lines (checked at close time; content you add outside those markers isn't counted).
Prune stale entries freely — git history preserves everything.

## Claude cloud sessions

You can hand a ticket to a Claude cloud session (Claude desktop's Code tab, or claude.ai/code) that runs on your
Claude subscription, with no API key. The ticket goes to your repo as a GitHub issue; the session works on it there.

Before the first send, the Cockpit's Factory › GitHub (or `tkt github-doctor`) checks that gh is installed and signed in
and that origin is a GitHub repo, and has Copy buttons for the recipe below. Issues labelled `canon` come in with the
board's header button **Sync from GitHub** (`tkt sync-issues`), which stays greyed out until those checks pass. Factory ›
GitHub's Intake box shows the issues waiting (`tkt sync-issues --dry-run --json`) and when the project last synced.

**Once: create a "canon" environment.** In a new session, open *Choose environment*, then *Cloud*. `tkt cloud-env` prints
this project's recipe ready to paste (the Cockpit's Factory › GitHub has Copy buttons for it); its one source is
`tools/cloud-env.sh`. Below is the full recipe; a project that is not written in Go leaves out the Go domains and the
script's Go block:

- **Name:** `canon`
- **Network access:** *Custom*, with these domains, and tick *Also include default list of common package managers*:
  `getcanon.dev`, `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, and for Go projects and
  canon itself (canon's tests build its daemon with the Go it pins): `go.dev`, `dl.google.com`, `proxy.golang.org`,
  `sum.golang.org`. Add your own stack's domains (an npm or PyPI mirror, for example) yourself.
- **Setup script** (runs before Claude starts, so every session has canon's latest verified release):
  ```bash
  #!/bin/bash
  set -e
  curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash

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

  for t in canon sprint tkt sprint-check skills.sh evidence.sh gate-snapshot.sh subagent-log.sh mutant-sweep; do
    printf '#!/bin/bash\nexec "$HOME/.canon/tools/%s" "$@"\n' "$t" > "/usr/local/bin/$t"
    chmod +x "/usr/local/bin/$t"
  done
  mkdir -p "$HOME/.claude/agents"
  cp "$HOME/.canon/agents/canon-reviewer.md" "$HOME/.canon/agents/canon-evaluator.md" "$HOME/.claude/agents/" || true
  git config --global user.name >/dev/null || git config --global user.name "canon cloud session"
  git config --global user.email >/dev/null || git config --global user.email "noreply@getcanon.dev"
  ```
  The wrappers put the tools on the session's `PATH`; the installer only suggests a shell profile line. The close
  checklist calls `skills.sh`, `evidence.sh`, `gate-snapshot.sh`, `subagent-log.sh` and `mutant-sweep` by bare name,
  and a refusal can print a bare `skills.sh refresh`, so they get wrappers too. Wrappers work with
  every canon release; symlinks work too from 0.11.2, but before it `sprint` and `tkt` could not find their helpers
  through a link. The last two lines give the session canon's reviewer and evaluator agents, which `sprint complete`
  runs at the close. The session clones your repo itself: the script needs no `git` lines. The Go block installs the
  version canon pins, so a raised pin follows on the next release; if the download fails, the session starts anyway on the
  image's Go and the setup log says why. Check it in a session with `go version`. The two `git config` lines set an
  identity only where the image has none.
- No secrets, no environment variables.

**What to expect in a session** (seen on t-2194, 2026-10-16):

- It runs as root, so tests that make a folder unwritable skip those cases (`tkt-compact`); your machine runs them.
- The full suite takes about 7 minutes there, and a worker restart can kill it (exit 137). Rerun the stamp.
- Suites that are timing-sensitive under load (`cockpit-daemon`'s `TestReapNowSavesThenEnds`, `windows-install`) can
  fail there and pass alone: rerun before treating one as a regression.
- A test that puts canon's `tools/` on `PATH` must prepend it. The cloud has no other canon, so an appended one passes
  there and runs your installed copy on your machine (PR #24 failed `merge-pr` this way).

**Each ticket:**

1. `tkt send-issue <id> --dry-run` shows the repo (your `origin`, which must be on GitHub), whether it is public, and
   the issue, laid out like the ticket on the board: Description, Acceptance, Plan and Research, then how to work on it.
2. `tkt send-issue <id>` creates it (needs `gh auth login`), adds the `canon` label, records `github: owner/repo#N`
   in `ticket.md`, and prints the line to start with. A public repo is refused unless you add `--public`: anyone
   could read the ticket's notes.
3. Start a new session on the `canon` environment and your repo and paste the prompt `send-issue` printed (the board's
   Send panel shows the same line with a Copy prompt button), which reads: "Work on Issue#N for ticket <id>. Read its
   section "Working on this" thoroughly before starting and follow it step by step. Work on a new branch, never main."
   The branch rule is in the prompt and the issue because a private repo on a free GitHub plan cannot enforce it with a
   branch rule, so the text is the only guard (t-1cf4). The issue's "Working on this" lists the steps in order;
   `sprint import-issue N` rebuilds the ticket (an approved plan stays approved) and starts the sprint; you approve and
   confirm in that session as you would locally, and the close happens there. A ticket sent without acceptance criteria
   or a plan is not a dead end: `send-issue` warns, and the session drafts both the way `sprint start` does, then waits
   for your approval (t-093a). After `tkt export` the session stops and replies with the PR number and the import
   command; it does not watch the PR or act on CI or review comments, since the merge happens on your machine. Approve the plan in `plan.md`, not through Claude Code's plan mode: a session that planned
   in plan mode has been observed to pass it to its reviewer and evaluator, which then cannot run. Archive an older
   session on the same issue first, so two sessions never push for one ticket.
4. At the close the session runs `tkt export <id>`. If your project commits `.tickets/`, the ticket goes back inside
   the PR. If not, it is pushed to a branch `canon-results/<id>` that is never merged. A public repo needs `--public`,
   as with `send-issue`: the folder holds the ticket's notes and evidence logs.
5. On your machine, `tkt import-results <id> --pr <PR number>` brings that branch back: every file byte-for-byte, a
   local file that differs kept in `.tickets/<id>/.before-import/`, and a report of the status, the evaluator's verdict
   and whether it graded the PR's head commit. Then it deletes the branch. A ticket the cloud left `in_progress` comes
   back `open` (see "When a cloud sprint cannot close" below).
6. `tkt merge-pr <id>` finishes it: it checks the evaluator passed on the PR's head and GitHub can merge it, shows
   what the PR changes, asks once, runs your tests (`scripts/test.sh`, or `--test "<command>"`) on your base branch
   plus the PR in a scratch clone, and merges if they pass. `--check` runs the checks only. With no terminal to ask
   on (an agent running it for you), it refuses unless given `--yes`, which skips only the question, never the checks.
   After the merge it fast-forwards your local base branch to GitHub's (only a clean fast-forward; otherwise it leaves
   it and says why). To also push main to other remotes you keep in step, name them once with
   `git config --add canon.mirror <remote>`; `tkt push-main` (or the board's "Push main to …" after a merge) pushes only
   those, never forced, and prints how to undo each push.

On the board these are one button per card stage: Issue ↗, PR ↗, Import results, Check & merge, then the push. A
session that pushed its branch without opening a PR shows "branch, no PR" and a **Create PR** button (`tkt open-pr <id>`),
which opens it with `Fixes #N` after you confirm. The worktree picker's "GitHub · new issue" row reads the readiness
checks first and, when something is missing, reads "GitHub · set up first (n of m ready)" and opens Factory › GitHub.

**Letting Claude Code run the merge.** In auto mode, Claude Code blocks a merge as "Merge Without Review" even after
you said yes in chat. To let it run `merge-pr` for you, allow the command once, with `/permissions` › Allow or in the
project's `.claude/settings.local.json` (personal, gitignored; `~/.claude/settings.json` for every project):

```json
{ "permissions": { "allow": ["Bash(tkt merge-pr *)", "Bash(gh pr merge *)"] } }
```

`Bash(tkt merge-pr *)` is the safer rule: `merge-pr` merges only the graded head after your tests pass. Allow
`Bash(gh pr merge *)` only if you also want it to merge a PR that has no canon ticket (it checks nothing). A
compound command (`gh pr merge 42 && git push …`) is matched one part at a time, so each part needs its own rule.

**A cloud session that pushed a branch but opened no PR.** The session's report names `canon-results/<id>`; the
evaluator's `graded-head:` in that branch's `eval-report.md` is the commit to merge. Find its branch
(`git branch -r --contains <graded-head>`), open the PR from your machine (`gh pr create --head <branch>`), then
continue at step 5 with that PR number.

**Who grades what (t-278d).** For a ticket that is not a board or Go change, the cloud does the whole job: you
approve the plan, it builds, runs the tests, runs a fresh evaluator and stamps the evidence. The Mac only runs
`tkt import-results <id> --pr <N>` then `tkt merge-pr <id>`, and does **not** rebase: `merge-pr` merges a PR that is
MERGEABLE and CLEAN on a newer `main` after running `scripts/test.sh` on `main` + the PR, and refuses unless the PR head
is the graded head, or the graded head plus only `LEARNINGS.md`, `LEARNINGS-archive.md` or that ticket's own `.tickets/<id>/` changes (the
learnings sweep the cloud commits after its gates, t-fdb1), none of them a symlink. `merge-pr` names those files before it
asks; read the `LEARNINGS.md` row, since every sprint start reads that file. Any other change after grading, `AGENTS.md`,
`CLAUDE.md`, `HANDOFF.md`, `DECISIONS.md` and `PROMOTED.md` included (agents load them as instructions), still needs a re-grade. The Mac re-grades only for one of four triggers: a **board** change (the board, its spec or its runner: the full board spec), a **Go**
change that needs a release (the daemon, the Go board, the headless helper), a **high-risk** ticket, or a **PR head that no longer equals the graded
head**. `import-results` ends with one line saying which of these apply, or "no re-grade needed"; it only advises and
never changes `merge-pr`. Each evidence log records the machine it ran on (line 3, `# on <uname -srm>; bash <version>`);
when the cloud's logs name another OS than the Mac's, `import-results` adds `evidence ran on: Linux … (this machine: Darwin …)`,
since an OS-only failure (bash 3.2 vs 5, BSD vs GNU tools) would not show in them; `merge-pr`'s run on the Mac covers that. When a re-grade does run a full board spec, stamp its guard under its own name (for example
`board-spec-guard`) with the run's `--out` folder inside the ticket's `evidence/`; `evidence.sh check` then reports the
run `covered` (stamping the guard under the run's own log name overwrites that log).

**When a cloud sprint cannot close** (its gates cannot run there, for example because of plan mode, or a QA item
needs your machine): have the session open the PR, run `tkt export <id>` without closing, and push nothing more to
the branch. Then on your machine run `tkt import-results <id> --pr <N>`: an unfinished ticket comes back `open`, with
`cloud_status: in_progress` recording what the cloud left, so it never blocks a local sprint's close in this checkout
(t-1cf5). Do the QA, and close it from the PR's head: `tkt land <id>` (or **Continue here** on the card) makes a
worktree `<project>-worktrees/land-<id>` on branch `land/<id>` at the PR head and starts the ticket there (`.tickets/`
is shared, so nothing is copied). In that worktree run a fresh evaluator and `sprint complete`, then `tkt land <id>
--finish` removes the worktree and branch; it refuses until the ticket is closed with a passing verdict graded on that
worktree's head, and never pushes or merges (the card's **Finish** runs it). When Check & merge fails because the suite fails on this machine, **Fix here** (`tkt land <id> --fix`) makes the worktree even though the cloud's verdict passes: fix and commit there, run `sprint complete`, finish, and push the commits to the PR branch yourself. `import-results` prints that step for an unfinished ticket (`next: tkt land <id>`). The evaluator must run on your machine even when the
cloud's passed: `sprint complete` checks this machine's record of the evaluator run, which `tkt export` cannot carry
(t-b650). Then `tkt merge-pr <id>`, which also deletes `canon-results/<id>`. A fix pushed to the PR after grading
needs the evaluator again: `merge-pr` merges only the graded head.

Each session is a fresh machine. Keep the environment; archive old sessions.

## Tracking `.tickets/` in your project

canon keeps its **own** working `.tickets/` gitignored (they're canon's internal dev tickets, not
product). **Projects that consume canon should do the opposite — track `.tickets/` in git, don't add
it to `.gitignore`.** Your sprint state (`acceptance.md`, `plan.md`, `summary.md`, and any
ticket-local `features/*.feature` specs) is the durable record that survives context resets, and it
must be committed for two reasons:

- **Headless CI grading** reads the graded ticket's `acceptance.md` from the checked-out repo — an
  uncommitted ticket is invisible to the PR gate.
- **Ticket-scoped `.feature` references** (a criterion pointing at `features/<name>.feature` under
  the ticket) only render on the board and reach CI if the file is committed with the ticket.

If you started from a template that gitignores `.tickets/`, remove that line so your agent's planning
and specs travel with the repo.

**Runtime files are the exception — don't commit those.** canon writes a few per-machine files under
`.tickets/` that change every session and must never be tracked: `.tickets/ACTIVE` (the active-sprint
pointer) and the cockpit's `.tickets/<id>/.cockpit-*` files (`.cockpit-cwd`, `.cockpit-agent`,
`.cockpit-session-id`). `tkt` auto-seeds a `.tickets/.gitignore` covering them (`.cockpit-*`, `ACTIVE`)
the first time it ensures the tickets directory exists — so on a project that tracks `.tickets/`, the
ticket docs are committed while the runtime churn is ignored. Commit that `.gitignore`. If your repo
**already committed** any runtime files (e.g. from before this was seeded), untrack them once — they
stay on disk, they just stop being versioned:

```bash
git rm -r --cached --ignore-unmatch '.tickets/**/.cockpit-*' '.tickets/ACTIVE'
git commit -m "stop tracking canon runtime files"
```

Leaving them tracked otherwise causes the cockpit's worktree carry-over check to false-warn about
"uncommitted changes" whenever canon writes or deletes one of its own runtime files (t-2f53).

## Skill lifecycle

See **[standards/skill-setup-std.md](../standards/skill-setup-std.md)** for the lint → eval → register order of operations.

## Reference

### Skills commands

```bash
skills.sh list                    # show available skills
skills.sh add sprint              # register a skill in current project
skills.sh status                  # check registration + hook health
skills.sh refresh                 # re-register, repair symlinks, prune legacy imports
```

### Ticket commands

```bash
sprint current                    # active sprint
sprint status                     # active sprint + required files
tkt ls                            # list all tickets
tkt ls --status=in_progress       # filter by status
tkt show <id>                     # full ticket detail
tkt reopen <id>                   # reopen a closed ticket
tkt send-issue <id> --dry-run     # preview a ticket as a GitHub issue (see Claude cloud sessions)
```

### Skill verification

| Skill | Trigger | Expected |
|-------|---------|----------|
| `sprint` | `"Start a sprint for X"` | Tier selected → brief → awaits approval → writes plan.md |
| `context-check` | `/context-check` | Context audit; writes context-check-report.md at the project root |
| `doc-audit` | `/doc-audit` | README/guides audit; findings appended to doc-findings.md |
| `output-validator` | `/output-validator` | Pre/post-generation report validation |
| `skill-export` | `/skill-export <name>` | Exports flat skill as paste-ready text |

## Staying updated

```bash
canon update
```

If `canon update` refuses with "has uncommitted changes" and `git -C ~/.canon status --short` shows only `?? cockpit/` (installs made before this fix, 2026-10-06), run `git -C ~/.canon pull --ff-only` once. A plain pull is not blocked by that folder, and after it `canon update` works.

`canon update` moves the install to the latest verified release. **How canon update works** (below) covers the tracks, going back after a bad update, and every refusal. An install made before 2026-10-08 does not know `--to` yet (`canon update takes no arguments`): run a plain `canon update` once, then `--to` works. Releases and what each contains: `CHANGELOG.md`; how a release is cut: `docs/releasing.md`.

**Verified installs.** A release is checked against the manifest as described under *How canon update works*; there is no override, and `canon update --to main` is the way out. `main` is not verified (it changes with every push); it is the opt-in development track (`CANON_REF=main` on the installers, `canon update --to main`), and says so whenever you are on it. This protects against a corrupt or changed download and a compromise of the zip alone; it does not protect against someone who controls the installer script, which is served from the same GitHub repo. Details: `docs/releasing.md`.

Hook scripts update immediately — called by path. Skill content updates automatically via symlinks (`.claude/skills → ~/.canon/skills` and `.agents/skills → ~/.canon/skills`, for Codex/Pi) — every project picks up changes on the next session.

`add`/`refresh` also add `/.claude/skills` and `/.agents/skills` (no trailing slash, so a macOS/Linux symlink is matched too) to your project's `.gitignore` — the skill dirs are **local links to canon, never committed**. An older `/.claude/skills/` line is replaced in place on the next `refresh`. This matters on Windows, where the link is a directory *junction* that git sees as a real folder: committing it would freeze a copy of the skills, and any `git worktree` or older checkout would then serve **stale** skill guidance (a canon fix would look absent). If your repo already committed the mirror, `add`/`refresh` untracks it (`git rm --cached`, files untouched) so it stops drifting. Git worktrees are auto-linked to current canon when the board (`sprint-check`) creates them; for a worktree made by hand, run `skills.sh link-worktree <path>`. If a worktree materializes a **committed** mirror (a repo that tracked `.claude/skills`/`.agents/skills` before you untracked it), worktree creation now **replaces** that stale copy with a fresh link to current canon and untracks it in the worktree — so the worktree serves current skills immediately. The durable, all-checkouts fix is still the one-time main-repo untrack: run `skills.sh refresh` in the main checkout and commit the removal.

Those `.gitignore` lines (and the `.gitattributes` block from `add sprint`) are written but not committed. Commit them whenever it suits you: until then `git status` shows the edit, and `sprint complete`'s stale-evaluator check accepts exactly what canon's own setup writes there (it replays canon's writers on the graded file) while still refusing any other change to those two files (t-52f0).

To repair symlinks after an upgrade:

```bash
skills.sh refresh /path/to/your-project
```

### How canon update works

canon follows one of two **tracks**:

- **Release (the default).** A plain `canon update` installs the newest release listed in the published manifest (`https://getcanon.dev/releases.txt`) after checking it: on a git install the tag's commit must equal the manifest's, on a Windows zip install the zip's SHA-256 must equal it. If the manifest cannot be read, does not list a release, or disagrees, nothing is changed and `canon update` says why. `canon update --to latest` installs the latest verified release too, and is how you leave the main track.
- **Main (opt-in).** `canon update --to main` follows the development version: the newest changes, before they're released and without a release's verification. canon remembers the choice in an untracked file, `.canon-track` (on the main track it contains `main`; git ignores it; a Windows zip install writes `release` there on the release track, a git install has no file), so a plain `canon update` keeps following main, and `canon version` says so ("canon <version> (development version, following main)", then the command for the latest release). `canon update --to latest` or `--to vX.Y.Z` leaves the main track.

`canon update --to vX.Y.Z` installs that release now. It is not sticky: the next plain `canon update` goes to the latest release again.

What a plain `canon update` does, by kind of install:

| Install | What happens |
|---|---|
| Made by the installers at v0.4.0 or later | Follows its track: the latest verified release, or main if you chose `--to main`. |
| A Windows zip install (any version) | Re-runs `install.ps1` from the canon-skills `main` branch, which follows the remembered track (main) or otherwise installs the latest verified release, and keeps your Cockpit data. |
| A git install on branch `main` made before v0.4.0 (no marker) | The first update with the new updater moves it once to the latest verified release and says so ("This install was following main"). An older updater first pulls `main`, which brings the new one in; the next update does the move. |
| A git install pinned at v0.3.0 | v0.3.0's older updater refuses a plain update as "pinned". Run `canon update --to main` (or `--to v0.4.0`) once; that brings in the new updater. The older one writes no marker, so a plain `canon update` after `--to main` moves you to the latest release; to stay on main, run `canon update --to main` again with the new updater. |

**Refusals.** Each of these leaves everything exactly as it was, and says why:

- the manifest cannot be read, has no release, or does not verify the release (`canon update --to main` follows main without a manifest);
- the release the manifest names is missing on origin, or its tag points at a different commit than the manifest says (a stale tag of your own: `git tag -d <tag>`);
- the install has uncommitted changes;
- the install has local commits on `main` that a release would leave behind (`canon update --to main` follows main, which works only if your history can fast-forward);
- a main-track update cannot fast-forward (local commits that diverge, or no upstream);
- the install is on another branch than `main`;
- a *plain* update finds a detached commit that is not a release tag (its commits would be left behind; run `git switch main`, or use `--to` to leave on purpose);
- off Windows, the folder is not a git clone (reinstall); on Windows, `canon stop` first if canon's daemon is running.

A first install that cannot verify a release installs nothing; `CANON_REF=main` (with `install.sh` or `install.ps1`) installs the development branch instead.

## Requirements and Windows

| Tool | Required | For |
|---|---|---|
| Claude Code / Codex / Pi | At least one | running the agent |
| Git | Yes | clone/update canon |
| Bash | Yes | CLI tools (`sprint`, `tkt`, `skills.sh`) |
| Python 3 | Optional, macOS/Linux | `sprint-headless` JSON and `skills.sh` settings merges; the board needs none (t-15d8) |
| curl | macOS/Linux | fetching the prebuilt board and cockpit daemon on install, `canon update` and `canon`; checked against a SHA-256 in the clone before they run. Go 1.26.5+ is only a fallback that builds them when the download is unavailable |

**Windows 11 — no WSL, no git clone needed.** In PowerShell, run the one-liner. It offers to install Git for Windows (for its bash) with winget if missing, fetches canon as a zip into `%USERPROFILE%\.canon`, and adds `tools\` to your user PATH; re-running updates in place and keeps `cockpit\`:

```powershell
irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex
```

No PowerShell policy change is made. Prefer to read it first? Download `install.ps1`, open it, then run `powershell -ExecutionPolicy Bypass -File .\install.ps1` (process-scoped). From cmd: `curl.exe -fsSLO https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.cmd && install.cmd`. Set `$env:CANON_YES=1` to skip the Git prompt. Then open a new terminal and run `canon`.

Already have a clone? Install [Git for Windows](https://git-scm.com/download/win), then:
1. Run **`install.cmd`** once — double-click it, or run `install.cmd` from any terminal. It launches `install.ps1` for you and adds `tools/` to your user PATH. (Running `install.ps1` directly can fail with *"install.ps1 is not digitally signed … UnauthorizedAccess"* — that's Windows' PowerShell execution policy blocking unsigned scripts, not a canon bug. `install.cmd` sidesteps it with a process-scoped bypass; if you prefer the `.ps1`, run `powershell -ExecutionPolicy Bypass -File .\install.ps1`.)
2. Use **Git Bash** to clone canon and run `git pull` to stay updated.
3. Use **PowerShell** for everything else. Each command has a `.cmd` wrapper in `tools/`, so run it by name: `canon` or `sprint-check-win` opens the board, and `sprint`, `tkt` and `skills` (for example `skills refresh`) run canon's CLI through Git Bash for you.

In a **Git Bash** window the same tools work too, but use the script names: `skills.sh refresh`, not `skills refresh` (Git Bash doesn't run `.cmd` files, and `tools/skills` is a folder). See **[fresh-machine-test.md → Windows 11](fresh-machine-test.md#windows-11)** for the full setup.

**Git for Windows is the only dependency on Windows.** canon never runs Python, on any OS:
- `canon` and `sprint-check` start the Go board, `sprint-check-win.exe`, as on every OS. It is fetched and checksum-verified (not part of the repo); if it is missing, `canon` tries one quiet fetch before telling you to run `canon update`.
- `skills.sh` edits `.claude/settings.json` (the permission and deny rules), and `sprint-headless` reads `claude -p`'s output, with the board binary's helpers (`sprint-check-win.exe settings`, `headless-json`).
- `sprint`, `tkt` and the pre-commit hook use only bash.

So canon never runs the `python3` App execution alias under `…\AppData\Local\Microsoft\WindowsApps\`, which on some machines downloads and installs Python. A test, `tests/no-python-windows-paths.sh`, fails if a shipped script starts running Python.

### Windows: what's different

- **Command names depend on the shell:** PowerShell and cmd use the `.cmd` wrappers (`skills refresh`), Git Bash needs the script names (`skills.sh refresh`).

Adding or removing a Windows gap? Update this list in the same change.

Register canon in another project:

```bash
~/.canon/tools/skills.sh add sprint          # plan → build → ship (includes wrapup, handoff)
~/.canon/tools/skills.sh add context-check   # optional: context-budget audits
```

**A project that isn't a git repo** (common for PM and design folders) is a first-class project: register it and start an agent as usual. canon records what the agent changed from a snapshot it keeps outside the folder (under `~/.canon/cockpit/changes/`), and the End dialog and the ticket's **Changes** panel show it in plain words. Each card on the Projects page also shows a git icon beside the project name (hidden if its status check fails), for version history you can opt into. Hover it for its state: *Git enabled — this project keeps a version history*, *Git not enabled — click to turn on version history*, or *Version history needs Git, which isn't installed on this computer* (the icon is disabled then). Click the "not enabled" icon and confirm, and canon creates a local history in that folder (`git init`, a `.gitignore`, and a first commit containing only that `.gitignore`). Nothing is uploaded and your files stay uncommitted. canon refuses if the folder already has a `.git` or sits inside another repository, and warns for iCloud Drive, Dropbox, OneDrive and Google Drive folders, where sync can damage that history.
