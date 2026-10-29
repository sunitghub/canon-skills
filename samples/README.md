# Samples

Canon's own examples: code to read and copy into your own tooling. **canon never runs anything here**; no command, board route, daemon or install step calls a sample. They ship in the release zip so you have them on disk.

| Folder | What | Status |
|---|---|---|
| `events/` | Hooks that read the activity log (format and read rules: [docs/plugins.md](../docs/plugins.md)). `events/tail-closes` prints one line per closed or merged ticket. | available |
| `plugins/` | Plugin samples, once the plugin API exists (t-347a). Planned: Sprint HUD (t-0a09), GitHub intake (t-a0c6). | planned |
| `executors/` | Executor samples (t-fe6a). The reference executor (t-5a94) lands in `executors/local`. | planned |

`examples/` is a different, local-only folder of demo projects; nothing in it ships.

`tests/samples-events.sh` runs each events sample against a fixture log, so a change to the event format that breaks readers fails the suite.
