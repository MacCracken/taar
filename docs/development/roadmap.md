# taar — Roadmap

> **Forward-looking only.** What has already shipped is recorded once, in
> [`CHANGELOG.md`](../../CHANGELOG.md) — it is not duplicated here, because two
> copies of a release history drift. Current state (version, module surface,
> what is verified) lives in [`state.md`](state.md). Every item names what it
> waits on; "ready" means nothing blocks it.

## Growth rule

taar grows **per second-consumer trigger**, not up-front. A module folds in
when a real consumer's duplication forces it — the founding case being `ipv4`,
which `yo` and `dig` shipped byte-identical. Nothing in the backlog is built
until its trigger actually fires; a plausible future need is not a trigger.
Hardening of what already ships is not growth and does not wait on a consumer.

## 0.7.x — the AGNOS backend, executed

The largest untested surface in the repo. `src/socket.cyr`'s
`#ifdef CYRIUS_TARGET_AGNOS` arm compiles and is confirmed selected, but
nothing runs it, so every guarantee on that target rests on review alone. 0.6.2
made it more pressing: it shipped four AGNOS changes (the reply-source filter,
timeout 0 = no deadline, `udp_send`'s payload count, the 1-spin send cap) whose
logic is unit-tested on Linux but whose wiring has never executed.

- **0.7.0 — an AGNOS execution harness.** *Waits on:* the design decision — a
  QEMU-booted agnos image in CI, or something smaller in-repo. Done when
  `tests/taar.tcyr`'s socket groups and the TC-fallback cases run against the
  AGNOS arm, and the four 0.6.2 changes above are exercised.
- **Per-socket AGNOS state.** Timeout, TCP conn and UDP peer / source port are
  module globals today, so a resolve disturbs a consumer's socket: the TC retry's
  `taar_tcp_open` drops a live conn without closing it (a leaked kernel slot,
  and the consumer's next recv reads 0), `taar_resolve_ipv4` overwrites the
  consumer's timeout, and `_taar_ag_src_port` keeps the resolver's freed port.
  Index state by the fd taar returns. *Waits on:* 0.7.0 — a state-model rewrite
  must not ship blind.
- **AGNOS EOF vs reset.** `sock_recv#49` answers -1 for a clean EOF *and* for
  a reset / dead conn, so `taar_tcp_recv` reports both as 0 ("peer closed")
  where Linux returns -ECONNRESET; a consumer reading to EOF can take a
  mid-body reset for a complete response. *Waits on:* the agnos kernel
  distinguishing the two (to file upstream), then a one-line map in taar.
- **AGNOS no-connection guard.** `taar_tcp_send` / `taar_tcp_recv` pass
  `_taar_ag_conn` even when it is -1 (never connected, or closed). Return an
  error instead. *Waits on:* 0.7.0 (a guard needs a test).

## 0.8.x — stub-resolver completeness

`taar_resolve_ipv4` against what glibc and musl stubs do. All of these are
testable on Linux with the existing unit + `unshare -rn` harness.

- **Nameserver failover.** taar uses the first usable `nameserver` only; glibc
  and musl try up to three, in order, on timeout / SERVFAIL / refusal, and honour
  `options timeout:` / `attempts:`. *Ready.*
- **A total resolve deadline.** Waits are bounded per call today: UDP 8 replies
  × 5 s, TCP 16 reads × 5 s plus a 5 s connect. One deadline per resolve needs a
  monotonic clock, which only `chrono` provides on Linux — and `yo` / `dig` do
  not carry it, so taar cannot depend on it (CLAUDE.md). *Waits on:* a clock in
  the `syscalls` leaf upstream, or every consumer carrying `chrono`.
- **Answer owner-name validation.** `_taar_dns_first_a` takes the first class-IN
  A record without checking its owner against the QNAME or the CNAME chain (or
  the reply's OPCODE). glibc checks; musl does not. Matters only against a broken
  or hostile configured resolver. *Ready.*
- **Decision: the fallback when resolv.conf is missing or unreadable.** taar
  uses 8.8.8.8 (deliberate for AGNOS, where a kernel lease is tried first); glibc
  and musl use 127.0.0.1 on Linux. 0.6.2 already fails closed when the file names
  resolvers taar cannot use. Includes whether EACCES should count as "missing".
  *Waits on:* the decision — it changes behaviour on minimal containers.
- **Decision: query-name case.** Either randomise the QNAME's letter case
  (DNS 0x20) for extra anti-spoofing entropy — taar already requires an exact
  echo, so it would be enforced — or compare the echo case-insensitively for
  resolvers that canonicalise case. Not both. *Waits on:* research into which
  resolvers in the consumers' deployments preserve case.
- **Retry the UDP wait on EINTR.** With SO_RCVTIMEO set, Linux does not restart
  `recvfrom` after a signal, so a consumer's signal ends the resolve. *Ready.*
- **Detect oversize datagrams.** A UDP reply over 2 KB is cut silently (no
  `MSG_TRUNC`) and parsed as if whole. Memory-safe; compliant servers stay under
  512 bytes because taar sends no EDNS OPT. *Ready, low value.*
- **Decision: `ipv4_parse` leading zeros.** `010.1.1.1` parses as decimal
  10.1.1.1 where `inet_aton(3)` reads octal 8.1.1.1. Harmless while callers use
  the packed value; a caller that validates a string here and re-parses it with
  libc gets a different address. Pinned by test so a change is deliberate.
  *Waits on:* the decision.

## 0.9.x — surface freeze

- **An ADR for the module / backend contract.** What every `taar_*` function
  promises on both targets (returns, timeouts, the 0-means-closed rule), so the
  AGNOS work above has a written contract to test against. *Ready.*
- **Public-surface review.** Settle names and return contracts before 1.0;
  deprecate anything not wanted. *Waits on:* 0.7.x and 0.8.x, whose fixes touch
  the surface.

## 1.0.0 — criteria

- Every planned consumer (`yo`, `dig`, `whirl`, + traceroute if it lands) on
  taar with no in-tree duplication — see *Consumer migration*.
- Every module's AGNOS backend **executed**, not merely compiled (0.7.x).
- Frozen public surface + the contract ADR (0.9.x).

## Backlog (v1, trigger-gated)

Grown only when the named trigger fires.

- **`icmp` module** — echo packet construction + checksum, lifted from `yo`'s
  `icmp.cyr`; the AGNOS side is `icmp_echo`#55. *Trigger:* a second ICMP
  consumer (traceroute is the likely one). `yo` alone duplicates nothing.
- **`tls` / `http` submodules** — HTTPS above taar's TCP layer; `whirl` carries
  it today. *Trigger:* a second consumer needing them.
- **IPv6** — AAAA queries, v6 sockets, v6 nameservers (an IPv6-only resolv.conf
  is the one host config taar cannot resolve on). *Trigger:* a consumer that
  needs v6.

## Consumer migration

Consumer-repo work, handled there; listed so taar's 1.0 criteria are visible.

- **Bump past 0.5.0.** All three consumers pin taar 0.5.0, so none carries
  0.6.2's resolver hardening (bounded TCP connect, no silent public-resolver
  fallback, the AGNOS source filter).
- **`dig` onto taar's `socket` and `dns`.** The `socket` fold trigger fired at
  dig 0.3.7, when dig wrote its own connect-then-write UDP transport — the same
  RFC 5452 reasoning as `taar_udp_send`, rediscovered. The fold runs the other
  way from `ipv4`: taar's `socket` and `dns` were written independently on
  whirl's pull, so dig would *migrate onto* them — a behavioural review, not a
  dedup. Parked at dig's own 0.4.x.
- **`yo`'s `icmp.cyr`** — waits on the `icmp` backlog item.
