# Dataflow — Project Instructions

@./docs/setup-guide.md
@./docs/api-reference.md
@./docs/legacy-runbook.md

## Overview

This project is a data pipeline service that ingests events from external APIs,
transforms them, and writes results to a database. It is written in TypeScript
and runs on Node.js.

Always write clean, readable code. Make sure to test your changes before
committing. Follow best practices at all times.

## Development Setup

- Run `npm install` to install dependencies.
- Run `npm run dev` to start the development server.
- Run `npm test` to run the test suite.
- Use Node.js 20 or higher.
- Use TypeScript strict mode.

## Architecture

The service has three layers:
1. Ingestion: pulls data from upstream APIs on a schedule
2. Transform: normalizes and validates the payload
3. Storage: writes to Postgres via the repository layer

Keep the layers separate. Don't mix ingestion logic with storage logic.

## Code Style

- Use 2-space indentation.
- Always use `const` over `let` unless reassignment is needed.
- Prefer `async/await` over raw Promises.
- Write good code that is easy to understand.
- Be thorough and thoughtful when making changes.
- Name things clearly and consistently.
- Write helpful comments where appropriate.
- Avoid overly complex solutions.

## Testing

- Write tests for all new functionality.
- Make sure tests pass before opening a PR.
- Always test your changes.
- Use Jest for unit tests.
- Use Supertest for HTTP integration tests.
- Keep test files co-located with the source file they test.

## Git

- Use imperative mood in commit messages.
- Keep commits small and focused.
- Reference ticket IDs in commit bodies.
- Never force-push main.

## Database

- All schema changes must go through migrations.
- Never modify an existing migration file.
- Run `npm run migrate` before starting the server locally.
- Use parameterized queries — never interpolate user input into SQL.

## API

- All endpoints require authentication via Bearer token.
- Validate all incoming request bodies with Zod schemas.
- Return consistent error shapes: `{ error: string, code: string }`.
- Log all 5xx errors with the full request context.

## Environment Variables

- Copy `.env.example` to `.env` and fill in the values.
- Never commit `.env` to version control.
- All required env vars are listed in `.env.example`.
- Be careful with secrets.

## Deployment

- CI runs on every push to main.
- Merging to main triggers an automatic deploy to staging.
- Production deploys require manual approval in GitHub Actions.
- Monitor the deploy in the #deployments Slack channel.

## Support Rotation

- Check the dashboard first.
- Be helpful and thorough.
- Use good judgment.
