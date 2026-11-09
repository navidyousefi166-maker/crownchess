# Move dispatch and clock diagnostics

The browser now starts the move RPC before rebuilding the board and move history. Clock painting checks game-over status once per repaint instead of once for each clock element. A response from a game that has already been left cannot overwrite the new game's clocks.

No lag allowance, client-authoritative clock value, or clock-animation compensation was added. Network delay can still cause an authoritative correction. The asynchronous illegal-move audit remains enabled.

The SQL change adds response-only timing fields without changing the function signature, grants, clock calculations or move-audit trigger. `lock_wait_ms` includes the small pre-lock validation segment; `write_ms` includes the game UPDATE and its triggers (including enqueueing the audit), not the later asynchronous chess validation. These numbers do not include API gateway or network delay.

`window.kfClockDiagnostics` retains the most recent 30 move timings in memory and logs each with `[Kingsfall clock]`. `prepareMs` measures from local move execution to actual fetch dispatch, including payload preparation and session-token waiting. `roundTripMs` includes the network/API response and JSON parsing. `serverMs`, `lockMs`, and `writeMs` narrow down server work. `adjustmentMs` is the exact local-to-server clock correction, not the rounded seconds displayed. No credentials, player IDs or move payloads are logged.

Validation: run `node tests/clock-path.cjs`. The database assertions in `tests/clock-path.sql` were run inside a transaction with ROLLBACK for both colors, client-clock tampering, audit queue preservation and unauthenticated rejection. No test games or player statistics were committed.

Rollback frontend: restore index.html from branch `backup/clock-before-20261110` (commit `0e48944f54f01509555e3e9b2f3240a621d4aa16`). Rollback server instrumentation: execute `ops/clock/rollback.sql`. The old frontend is compatible with the added response fields, and the new frontend tolerates their absence.
