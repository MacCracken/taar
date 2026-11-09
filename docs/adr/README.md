# Architecture Decision Records

Decisions about taar — what we chose, the context, and the consequences we
accept. Use these when a future reader would reasonably ask *"why does taar do
it this way?"*

## Conventions

- **Filename**: `NNNN-kebab-case-title.md`, zero-padded to four digits. Never renumber.
- **One decision per ADR.** If a decision supersedes a prior one, add a new ADR
  and set the old one's status to `Superseded by NNNN`. An accepted ADR's
  context and reasoning are not rewritten. Two edits are allowed: its "where the
  targets differ" rows, updated as each difference closes, since they record
  standing rather than decision; and a later ADR's *amendment*, applied to its
  Decision tables, with the status line naming the amending ADR — so ADR 0001
  always reads as the current contract.
- **Status lifecycle**: `Proposed` → `Accepted` → (optionally) `Superseded` or `Deprecated`.
- Use [`template.md`](template.md) as the starting point (shared with yo and dig).

## Index

| ADR | Status | Decision |
|---|---|---|
| [0001](0001-one-socket-and-resolver-contract.md) — One socket and resolver contract | Accepted (amended by 0002) | Both backends keep one contract for every public call (returns, timeouts, fds, signals, threading); where AGNOS cannot meet it, the difference is named in the ADR's table and tracked until closed. |
| [0002](0002-the-public-surface-for-1-0.md) — The public surface for 1.0 | Accepted | Every public name carries `taar_` / `TAAR_`: the error constants lose their underscore, the IPv4 codec gains the prefix, `taar_sock_close` becomes `taar_tcp_close`, `taar_fill_sockaddr` goes internal, and a Linux connect timeout is `TAAR_ERR_TIMEOUT`. Old names are `#deprecated` aliases until 1.0.0 removes them. |
