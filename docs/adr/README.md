# Architecture Decision Records

Decisions about taar — what we chose, the context, and the consequences we
accept. Use these when a future reader would reasonably ask *"why does taar do
it this way?"*

## Conventions

- **Filename**: `NNNN-kebab-case-title.md`, zero-padded to four digits. Never renumber.
- **One decision per ADR.** If a decision supersedes a prior one, add a new ADR
  and set the old one's status to `Superseded by NNNN`. An accepted ADR is not
  rewritten; its "where the targets differ" rows are the one exception, updated
  as each difference closes, since they record standing rather than decision.
- **Status lifecycle**: `Proposed` → `Accepted` → (optionally) `Superseded` or `Deprecated`.
- Use [`template.md`](template.md) as the starting point (shared with yo and dig).

## Index

| ADR | Status | Decision |
|---|---|---|
| [0001](0001-one-socket-and-resolver-contract.md) — One socket and resolver contract | Accepted | Both backends keep one contract for every public call (returns, timeouts, fds, signals, threading); where AGNOS cannot meet it, the difference is named in the ADR's table and tracked until closed. |
