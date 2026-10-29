# tail-closes

Prints one line per `close.confirmed` and `github.merged` event in canon's activity log. Plain bash, `awk`, `tail`; works on macOS, Linux and Git Bash. It reads the log the way [docs/plugins.md](../../../docs/plugins.md) says to: day files in name order, lines in order, an `id` already seen dropped, and a resume point of file name plus byte offset.

```
samples/events/tail-closes/tail-closes [--events DIR] [--state FILE]
```

- `--events DIR`: the events folder (default `${CANON_HOME:-~/.canon}/events`).
- `--state FILE`: keep the resume point and the last 1000 ids here. Run it again later (from cron, a loop or a hook) and it prints only what is new. A line still being written is left for the next run. Without `--state` it reads everything each time.
- Reads `YYYY-MM-DD.jsonl` only. A day canon has gzipped (`.jsonl.gz`, older than 7 days) is not read; run `gunzip` on it first if you need it.

Output, one line per event: `<ts> <kind> <project> <ticket>`

```
2026-10-20T08:00:00.000Z close.confirmed /Users/me/code/app t-ab12
2026-10-20T09:30:00.000Z github.merged /Users/me/code/app t-cd34
```

Lines come in file then line order, which is append order, not always `ts` order (docs/plugins.md). Tested by `tests/samples-events.sh`.
