# Setup Guide

This guide is intentionally long for an always-on import. Some steps are useful
only during first-time onboarding and should be easy for `context-check` to flag
as rarely relevant in every session.

## First-Time Setup

1. Install Node.js 20.
2. Install Docker Desktop.
3. Clone the repository.
4. Run `npm install`.
5. Copy `.env.example` to `.env`.
6. Ask a teammate for temporary staging credentials.
7. Start Postgres with `docker compose up db`.
8. Run `npm run migrate`.
9. Run `npm test`.
10. Open the health endpoint.

## Troubleshooting

- If Docker is not running, start Docker Desktop.
- If the database port is busy, stop the old container.
- If dependencies fail to install, delete `node_modules` and reinstall.
- If TypeScript errors appear, run `npm run build`.

## Daily Development

- Run `npm run dev`.
- Run `npm test` before opening a pull request.
- Keep ingestion, transform, and storage code separate.
