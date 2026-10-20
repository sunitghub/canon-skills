# Building on canon: the event stream

canon records what happens to tickets, sprints, close gates and Cockpit sessions as events, one JSON object per line, so a plugin, a status-bar
widget or a script can follow along without polling the board. This page is the contract for **schema v1**
(`t-f182`, `t-8854`). A read API (`t-0b89`) comes next. v1 only ever gains fields or kinds: nothing listed here is
renamed or removed.

## Where events are

- `$CANON_HOME/events/YYYY-MM-DD.jsonl`, one file per **UTC** day. `CANON_HOME` defaults to `~/.canon`.
- Read the files in name order, then each file's lines in order. That is append order, which is not always strict
  `ts` order: two writers can finish a few milliseconds apart. Use `id` to drop a line you have already seen.
- To resume where you left off, keep the file name and the byte offset you had read up to. A day's file only grows,
  and a new day starts a new file, so you never miss an event at midnight.
- Files older than 90 days are deleted when the first event of a new day is written. Nothing else in the folder is
  touched. `emit-errors.log` beside them notes events that could not be written.

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
| `project` | the project's root folder, an absolute path (symlinks resolved) |
| `data` | only the fields listed for the kind; every value is a string |

## Kinds (v1)

| Kind | `data` | Written when |
|---|---|---|
| `ticket.created` | `ticket`, `title` (at most 200 characters), `type`, `priority` | `tkt create`, `tkt import-issue` and `sync-issues`, `sprint start "<title>"`, the board's **+ New** |
| `ticket.status_changed` | `ticket`, `from`, `to` | `tkt start`, `close`, `archive` and other status changes, a status move on the board, `tkt import-results` setting an in-progress ticket back to open |
| `ticket.closed` | `ticket` | together with the `status_changed` to `closed` |
| `sprint.started` | `ticket` | `sprint start` |
| `sprint.completed` | `ticket` | `sprint complete`, after the ticket is closed |
| `gate.started` | `ticket`, `role` (`reviewer`/`evaluator`, empty if not given), `attempt` (the evaluator's failed attempts so far + 1), `docs` (12 hex: the hash of the ticket's acceptance.md and plan.md) | `gate-snapshot.sh pre … --role <role>`, right before a close gate runs |
| `gate.finished` | `ticket`, `role`, `verdict` (`YES`/`NO` for the reviewer; `pass`/`fail`/`partial`/`not-run` for the evaluator; `unknown` if its report has none), `model`, `tokens`, `minutes` | `subagent-log.sh`, after a gate's run is logged |
| `gate.rejected` | `ticket`, `role`, `reason` | a close refusal: `missing_report`, `unverified_run`, `missing_transcript`, `verdict_not_pass`, `report_inconsistent`, `report_model`, `graded_head_stale` (evaluator); `review_model`, `review_shape` (reviewer); `stale_evidence` (`sprint check-evidence`) |
| `session.needs_you` | `session`, `ticket`, `agent` | a Cockpit agent session starts waiting for you |
| `session.exited` | `session`, `ticket`, `agent`, `reason` (`exited` on its own, or `killed` by the Cockpit) | a session ends |
| `session.saved` | `session`, `ticket`, `agent`, `by` (`marker` or `file-settle`) | Save & End saved the session's state |

An event never carries a ticket's description, documents or session text. Each field has a length limit, and longer
values are cut.

## Guarantees

- **Observer-only.** Writing an event never blocks, slows down or fails the change it describes. If the folder can't be
  written, the command behaves exactly as it would without events, and the failure is noted in `emit-errors.log`.
- **Whole lines.** Each event is one append of one line, so concurrent writers never interleave. The shell tools write
  through the board program (`sprint-check event …`) rather than appending themselves, because a shell `printf >>`
  can split a long line.
- **Written after the fact.** An event is written only once its change has been saved.
