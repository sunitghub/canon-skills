# API Reference

## Endpoints

### `GET /health`

Returns service health.

### `POST /events`

Accepts event batches from upstream systems.

## Request Rules

- Validate all request bodies with Zod schemas.
- Return consistent error shapes: `{ "error": "message", "code": "CODE" }`.
- Use parameterized queries for all database writes.

## Repeated Context Rules

- Write clean, readable code.
- Use good judgment.
- Make sure tests pass before opening a pull request.
