# Bug Patterns

Accumulated root-cause patterns from closed bug sprints. Each row is bought by a real failure.

| Ticket | Symptom | Root Cause Category | Root Cause | Fix Pattern | Prevent |
|--------|---------|-------------------|------------|-------------|---------|
| _example_ | _test passes in isolation, fails in suite_ | _state pollution_ | _prior test run leaves stale data; date-only vs ISO datetime sort mismatch_ | _clear state before run; normalize datetime format_ | _added isolation test case to eval suite_ |
