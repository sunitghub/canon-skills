# Building on canon: the event stream

canon records what happens to tickets, sprints, close gates and Cockpit sessions as events, one JSON object per line, so a plugin, a status-bar
widget or a script can follow along without polling the board. This page is the contract for **schema v1**
(`t-f182`, `t-8854`). A read API (`t-0b89`) comes next. v1 only ever gains fields or kinds: nothing listed here is
renamed or removed.

## Where events are

- `$CANON_HOME/events/YYYY-MM-DD.jsonl`, one file per **UTC** day. `CANON_HOME` defaults to `~/.canon`.
- The files hold paths as written. **Export .jsonl** (Admin > Logging) writes the user's home folder as `~` in the `project` field only (`~/work/app`, `~\work\app` on Windows); no other field and no file on disk is changed, and a line that is not JSON is exported as it is.
- Read the files in name order, then each file's lines in order. That is append order, which is not always strict
  `ts` order: two writers can finish a few milliseconds apart. Use `id` to drop a line you have already seen.
- To resume where you left off, keep the file name and the byte offset you had read up to. A day's file only grows,
  and a new day starts a new file, so you never miss an event at midnight.
- **Retention** (`log.retention_days` in `$CANON_HOME/settings.json`: `{"log":{"retention_days":90}}`; only 30, 90 or 365; 30 when the file is missing or wrong). When the first event of a new day is written, and hourly while the daemon runs, canon seals closed days, gzips sealed days older than 7 days (`YYYY-MM-DD.jsonl.gz`, same lines: read it with `gunzip`; `{"log":{"compress":false}}` in the same file turns the gzip step off, and on is the default) and removes days older than the setting. A removal writes a `log.pruned` event. A change to either setting from Admin > Logging writes a `setting.changed` event (`name` is `log.retention_days` or `log.compress`). Nothing else in the folder is touched. `emit-errors.log` beside them notes events that could not be written.
- **Day seals** (`seals.jsonl`, same folder). One line per closed day: `day`, `lines`, `sha256` of the uncompressed file, and `prev`, the hash of the line before it. A day is sealed one hour after it ends; today's file is never sealed. `canon log verify` recomputes every day and the chain and prints `intact`, `broken`, `missing` or `unsealed` for each, and exits 1 when any day is broken or missing; `canon log seal` seals what is due. A line `{"pruned_through":"YYYY-MM-DD","prev":...}` records that retention removed the days up to there. **A seal shows that a day was not changed after it was sealed. Removing the newest seal lines, or the whole file, is not detected: the days are then shown `unsealed` and are sealed again as they are. It does not show who wrote a line, and someone who can rewrite `seals.jsonl` and every line after the change defeats it.**

## One event

```json
{"schema":1,"id":"9f2c41d07a3be815","ts":"2026-10-20T07:08:09.123Z","kind":"ticket.status_changed","source":"tkt","project":"/Users/me/code/app","data":{"from":"open","ticket":"t-ab12","to":"in_progress"}}
```

| Field | Meaning |
|---|---|
| `schema` | always `1` for this version |
| `id` | 16 hex characters, random; unique per event |
| `ts` | when it was written, RFC 3339 UTC with milliseconds |
| `kind` | one of the kinds below |
| `source` | the program that wrote it: `tkt`, `sprint`, `board`, `gate-snapshot`, `subagent-log` or `daemon` |
| `actor` | optional: who caused it: `user` (a person at the board or the command line), `agent` (an agent in a session) or `system` (canon itself: a timer, the idle reaper, a retention job). Different from `source`, which is the program that wrote the line. Absent from every event written before it existed and from any emitter that does not know it: treat absent as unknown. The set is closed in v1: a line with any other value is not a v1 event |
| `project` | the project's root folder, an absolute path (symlinks resolved) |
| `data` | only the fields listed for the kind; every value is a string |

## Kinds (v1)

| Kind | `data` | Written when |
|---|---|---|
| `ticket.created` | `ticket`, `title` (at most 200 characters), `type`, `priority` | `tkt create`, `tkt import-issue` and `sync-issues`, `sprint start "<title>"`, the board's **+ New** |
| `ticket.status_changed` | `ticket`, `from`, `to` | `tkt start`, `close`, `archive` and other status changes, a status move on the board, `tkt import-results` setting an in-progress ticket back to open |
| `ticket.closed` | `ticket` | together with the `status_changed` to `closed` |
| `sprint.started` | `ticket`, `gate_agents` (`ok`, or `missing` when canon's gate agents are not loaded in the Claude Code session; absent when it cannot tell, t-ff14) | `sprint start` |
| `sprint.completed` | `ticket` | `sprint complete`, after the ticket is closed |
| `gate.started` | `ticket`, `role` (`reviewer`/`evaluator`, empty if not given), `attempt` (the evaluator's failed attempts so far + 1), `docs` (12 hex: the hash of the ticket's acceptance.md and plan.md) | `gate-snapshot.sh pre … --role <role>`, right before a close gate runs |
| `gate.finished` | `ticket`, `role`, `verdict` (`YES`/`NO` for the reviewer; `pass`/`fail`/`partial`/`not-run` for the evaluator; `unknown` if its report has none), `model`, `tokens`, `minutes`, `tier`, `agent` (the evaluator transcript's agent type: `canon-evaluator`, or `Plan` on the fallback; absent when none is found, t-ff14) | `subagent-log.sh`, after a gate's run is logged |
| `gate.rejected` | `ticket`, `role`, `reason` | a close refusal: `missing_report`, `unverified_run`, `missing_transcript`, `verdict_not_pass`, `report_inconsistent`, `report_model`, `graded_head_stale` (evaluator); `review_model`, `review_shape` (reviewer); `stale_evidence` (`sprint check-evidence`) |
| `session.needs_you` | `session`, `ticket`, `agent` | a Cockpit agent session starts waiting for you |
| `session.exited` | `session`, `ticket`, `agent`, `reason` (`exited` on its own, or `killed` by the Cockpit), `models`, `peak_context_pct`, `tokens_new`, `turns` | a session ends |
| `session.saved` | `session`, `ticket`, `agent`, `by` (`marker` or `file-settle`) | Save & End saved the session's state |

Audit kinds (t-4c09; the schema is fixed here, each emitter is built by the ticket named):

| Kind | `data` | Written when |
|---|---|---|
| `plan.approved` | `ticket`, `tier` | the plan's Sign-off box is ticked |
| `close.confirmed` | `ticket`, `tier` (one of `trivial`, `bugfix`, `normal`, `high-risk`, read from the `Tier:` line of the plan's Sign-off; absent when it names none) | `sprint complete` closes the ticket |
| `github.sent` | `ticket`, `issue` (number) | `tkt send-issue` |
| `github.results_imported` | `ticket`, `pr` (number; absent when `--pr` was not a number) | `tkt import-results`, after a clean import |
| `github.merged` | `ticket`, `pr` (number) | `tkt merge-pr` |
| `github.synced` | `count` (tickets made) | `tkt sync-issues` |
| `setting.changed` | `name`, `old`, `new` (non-secret settings only) | the Admin Model tiers page saves (`model-tiers.save`, `.reset`, `.apply`, `.retire`, `.remove`; a save or reset writes one line per changed default: `model-tiers.save` (or `.reset`) for the Review & Eval default and `model-tiers.save.<tier>.<provider>` for any other, `old` and `new` being the model before and after; a save that changes only other registry text (a model card) writes one `model-tiers.save` line with the Review & Eval default as both; a save that changes nothing writes none; `.apply`, `.retire` and `.remove` always write one line) or the Verbose session logging switch changes (`verbose-logging`, `on` or `off`) |
| `integrity.restored` | `item`, `count` | an Integrity restore |
| `context.threshold` | `session`, `ticket`, `agent`, `pct` | once, when a session passes 75% context |
| `log.pruned` | `from`, `to` (days), `files`, `last_seal` | the retention job removes day files; `actor: system`, `last_seal` is the hash of the last seal line before the removal |
| `log.deleted` | `from`, `to` (days), `files` | the user deleted the activity log from Admin > Logging; `actor: user`; the first line of the fresh log |

Which audit kinds are written today (t-4c09): `close.confirmed`, `github.sent`, `github.results_imported` (a clean import only), `github.merged`, `github.synced`, `setting.changed`, `log.pruned` (by retention, see Retention above) and `log.deleted`. A command run from a terminal carries no `actor`, because it cannot tell a person from an agent. A Model tiers write from the Admin page carries `actor: user` only when the request has a loopback Origin (a click on the page); the Verbose session logging switch carries none, because that endpoint is open to any local process. Install-wide events such as `setting.changed` have `project` set to the empty string. Not written yet, each waiting on a feature that does not exist: `plan.approved` (nothing observes the approval: the box in `plan.md` is ticked by hand), `integrity.restored` (Admin > Integrity only checks, there is no restore), and `context.threshold` (there is no per-session context figure yet).

Terminal audit kinds (t-57ab; written by the Cockpit daemon's restricted terminal; `ticket` is the scratch id; never a password, a path or a command):

| Kind | `data` | Written when |
|---|---|---|
| `terminal.su_prompted` | `session`, `ticket` | `su` is typed and the word is shown |
| `terminal.su_granted` | `session`, `ticket`, `minutes` | the word is typed back and the full shell starts; if this cannot be written, no shell starts |
| `terminal.su_denied` | `session`, `ticket`, `reason` (`auth`, `unavailable`, `locked`) | `auth`: the OS password prompt failed or was cancelled; `unavailable`: the machine has no OS password prompt, so there is no full shell (never counted); `locked` is the third failed password, which closes the terminal |
| `terminal.su_expired` | `session`, `ticket`, `how` (`ended` at the time limit, `exited` when the shell ended first) | the full shell ends |
| `terminal.tkt` | `session`, `ticket`, `sub` (the subcommand name only, never an argument) | one of `create`, `start`, `demo`, `close`, `reopen`, `archive`, `send-issue`, `import-issue`, `open-pr`, `import-results` is run in the Terminal without `su`; if this cannot be written, the command is not run |

Audit events carry ids, numbers and names only: never a PR or issue title, an imported result's text, a token, or a URL
with credentials.

Sprint progress kinds (t-5ef8; the Cockpit card reads these; "Build" has no kind: it is the time after `plan.approved` and before the first `wrapup.gate_started`):

| Kind | `data` | Written when |
|---|---|---|
| `plan.written` | `ticket`, `tier` | the plan is drafted and waits for approval |
| `wrapup.gate_started` | `ticket`, `gate` (a Wrapup Gates row: `code-simplifier`, `code-reviewer`, `security-review`, `doc-audit`, ...) | a wrapup gate begins |
| `wrapup.gate_finished` | `ticket`, `gate`, `result` (`ran`, `skipped`, `not-applicable`) | a wrapup gate ends |

An event never carries a ticket's description, documents or session text. Each field has a length limit, and longer
values are cut.

## Guarantees

- **Observer-only.** Writing an event never blocks, slows down or fails the change it describes. If the folder can't be
  written, the command behaves exactly as it would without events, and the failure is noted in `emit-errors.log`.
- **Whole lines.** Each event is one append of one line, so concurrent writers never interleave. The shell tools write
  through the board program (`sprint-check event …`) rather than appending themselves, because a shell `printf >>`
  can split a long line.
- **Written after the fact.** An event is written only once its change has been saved.
