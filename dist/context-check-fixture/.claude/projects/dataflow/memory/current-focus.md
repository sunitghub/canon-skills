# Current Focus

The team is migrating event ingestion from polling to webhook delivery.

Keep webhook validation and database writes separate. The latest prototype lives
in `src/index.ts`, but production code should eventually move route handlers into
`src/routes/`.
