# Todo App Canon Walkthrough

This example is a small vanilla JavaScript Todo app used to show canon's workflow on a real project shape:

```text
examples/todo-app/
  docs/          walkthrough docs
  src/           browser app source
  tests/         Node test coverage for Todo behavior
  .tickets/     sample sprint artifacts
```

The app has no runtime dependencies. Tests use Node's built-in test runner.

## Run It

```bash
npm test
python3 -m http.server 4173 -d src
```

Open `http://127.0.0.1:4173`.

## Walk The Canon Flow

1. Read [docs/01-setup.md](docs/01-setup.md).
2. Start the sprint in [docs/02-sprint-start.md](docs/02-sprint-start.md).
3. Build and test with [docs/03-implementation.md](docs/03-implementation.md).
4. Open the board with [docs/04-sprint-check.md](docs/04-sprint-check.md).
5. Complete the sprint with [docs/05-sprint-complete.md](docs/05-sprint-complete.md).

The sample ticket under `.tickets/t-demo/` shows what the agent and CLI create during a completed sprint. It is closed so you can run your own `sprint start` from this folder.
