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

## 0.7.x — AGNOS parity

Since 0.7.0 the AGNOS arm executes: `tests/agnos/run.sh` boots a pinned agnos
kernel under QEMU and runs `tests/agnos/selftest.cyr` against it, in CI. What
remains is where the AGNOS arm still differs from the Linux one. Each item
waits on an upstream change, all filed: cyrius stdlib wrappers for ABI agnos
already ships, and two agnos issues (epoll lifetime, UDP queueing).

- **AGNOS EOF vs reset.** `sock_recv#49` answers -1 for a clean EOF *and* for
  a reset / dead conn, so `taar_tcp_recv` reports both as 0 ("peer closed")
  where Linux returns -ECONNRESET; a consumer reading to EOF can take a
  mid-body reset for a complete response. The kernel already tells them apart
  elsewhere: since agnos 1.57.17, `epoll_wait#21` on `EP_TCP | conn` reports
  `EPOLLIN | EPOLLERR | EPOLLHUP` for a conn that died (RST or retransmit
  exhaustion) and `EPOLLRDHUP` for the peer's FIN. So when #49 says -1, taar
  can ask the conn's readiness and return `_TAAR_ERR_RESET` (or -ECONNRESET)
  for the first. *Waits on:*
  - cyrius's agnos peer for the `epoll_ctl` op-3 target and the `EP_TCP` /
    `EPOLL*` constants — cyrius issue
    `2026-11-04-agnos-epoll-timeout-epollout-tcp-ids-peer.md`, open. (Issuing
    the 4-argument calls with taar's own constants would work, but CLAUDE.md's
    rule is the stdlib wrapper.)
  - agnos freeing epoll instances — filed as agnos issue
    `2026-11-09-an-epoll-instance-is-never-freed-so-short-lived-ones-run-the-heap-dry.md`.
    Today an instance's watch list is never freed (1.69 M create/close pairs
    exhaust the kernel heap in 18 s), so taar could only use one process-wide
    instance, which is shared state 0.7.1 just removed. The issue also asks for
    the narrower fix: a distinct `sock_recv#49` answer for a dead connection,
    which would need no epoll at all.
- **AGNOS connect deadline.** taar's AGNOS connect is bounded by the kernel's
  ~8 s whatever `taar_tcp_set_timeout_ms` asked for (Linux honours it), and the
  harness pins that ~8 s. agnos 1.57.18 added the deadline: `SC_TIMED` (bit 32
  of `sock_connect#47`'s src_port) makes a4 the timeout in ms, measured once
  from entry. *Waits on:* cyrius's `sys_sock_connect` peer for it — cyrius issue
  `2026-11-08-agnos-fd-wait-ready-and-sock-connect-deadline.md`, open.
- **AGNOS UDP keeps one datagram.** A listener holds one unread datagram and
  the next arrival overwrites it (`net_handle_udp`), so a stray datagram
  landing after the real DNS reply, before taar's next 5 ms poll, evicts the
  reply and the resolve times out. Never a wrong answer — the source filter
  still applies — but a cheap way to fail a resolve. The harness has a canary
  that goes red when this changes. *Waits on:* the kernel queueing datagrams —
  filed as agnos `docs/development/issues/2026-11-09-a-udp-listener-keeps-one-datagram-so-a-stray-one-evicts-the-reply.md`.

## 0.8.x — stub-resolver completeness

`taar_resolve_ipv4` against what glibc and musl stubs do. All of these are
testable on Linux with the unit suite and `tests/integration/` (0.8.0 added
`resolver.sh`, with several fake nameservers per case). 0.8.0 shipped
nameserver failover with `options timeout:` / `attempts:` and the EINTR retry;
0.8.1, answer owner-name validation along the CNAME chain and the OPCODE check;
0.8.2, the three behaviour decisions (127.0.0.1 when nothing is configured, a
case-insensitive question echo, leading zeros refused). What is left here is a
deadline that waits on a clock, and two low-value or trigger-gated items.
- **A total resolve deadline.** Waits are bounded per call today, and 0.8.0's
  failover multiplies them: per server, 8 UDP receives × the timeout, then a
  TCP retry of 16 reads × the timeout plus its connect, for each of up to three
  servers, for each of `attempts` rounds. The common cases are short (a dead
  server fails in milliseconds, a silent one at one timeout); the bound is the
  long tail. One deadline per resolve needs a monotonic clock, and the only
  portable one is `chrono`'s `clock_now_ns`. dig and whirl carry `chrono`; yo
  does not, so taar may not depend on it yet (CLAUDE.md). *Waits on* whichever
  lands first:
  - yo adopting `chrono` (yo roadmap 0.8.x, "The monotonic clock from
    `chrono`"), after which every consumer carries it;
  - a clock in the `syscalls` leaf (cyrius issue
    `2026-11-09-syscalls-has-no-monotonic-clock.md`).
- **Detect oversize datagrams.** A UDP reply over 2 KB is cut silently (no
  `MSG_TRUNC`) and parsed as if whole. Memory-safe; compliant servers stay under
  512 bytes because taar sends no EDNS OPT. *Ready, low value.*
- **Search domains.** `search` / `domain` and `options ndots:` are ignored:
  names are resolved exactly as given, never with a suffix appended. glibc and
  musl try short names against the search list. *Waits on:* a consumer that
  resolves short names (none does: whirl takes hosts from URLs, dig is
  explicit).
## 0.9.x — surface freeze

0.9.0 wrote the contract: [ADR 0001](../adr/0001-one-socket-and-resolver-contract.md).
Its "where the targets differ" table is the 0.7.x list above, kept in step.

0.9.1 settled the names: [ADR 0002](../adr/0002-the-public-surface-for-1-0.md).
Every public name carries `taar_` / `TAAR_`, and the old names are
`#deprecated` aliases until 1.0.0 removes them. Nothing in 0.9.x is open.

## 1.0.0 — criteria

- Every planned consumer (`yo`, `dig`, `whirl`, + traceroute if it lands) on
  taar with no in-tree duplication — see *Consumer migration*.
- Every module's AGNOS backend **executed**, not merely compiled — true on
  x86_64 since 0.7.0. aarch64 AGNOS compiles but agnos does not yet boot there
  (its 1.6x port); executed coverage follows that boot.
- The 0.7.x parity items closed, or each written into the contract ADR as a
  documented target difference.
- Frozen public surface + the contract ADR (0.9.x): done, ADRs 0001 and 0002.
- **The deprecated aliases removed** (ADR 0002's table): the deprecated blocks
  at the end of `src/ipv4.cyr` and `src/socket.cyr`, the `_TAAR_ERR_*` and
  `IPV4_PARSE_FAIL` constants, and the `deprecated-names` test group.

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

- **Rename for 0.9.1 / 1.0.0** (ADR 0002). Each old name warns at its call
  site from 0.9.1 and is gone at 1.0.0:
  `ipv4_parse` → `taar_ipv4_parse`, `ipv4_format_to_buf` →
  `taar_ipv4_format_to_buf`, `IPV4_PARSE_FAIL` → `TAAR_IPV4_PARSE_FAIL` (yo,
  dig); `taar_sock_close` → `taar_tcp_close` (whirl, dig). The constants cannot
  warn, because cyrius has no `#deprecated` for a `var` (proposed:
  `cyrius/docs/development/proposals/2026-11-09-deprecated-constants.md`), so
  grep for them. dig can also drop its
  mirrored `TCP_EINPROGRESS` (-115) and `PLATFORM_ERR_TIMEOUT` (-11) for taar's
  `TAAR_ERR_TIMEOUT`, which a Linux connect timeout now returns.
- **Bump to 0.9.1** — matters to all three. `yo` and `dig` parse user-typed
  addresses (and dig its resolv.conf) with `ipv4_parse`, which since 0.8.2
  refuses a leading zero: `010.1.1.1` is no longer read as 10.1.1.1. Neither
  tool's tests rely on the old reading. And to `whirl`, the one consumer of
  `socket` and `dns`. On AGNOS its sends become bounded by the 10 s deadline it already
  sets (they were not — its 1000-try loop on a 0 return could wait hours), a
  recv with no connection is an error rather than a clean close (0.7.0), and
  its resolve no longer shares socket state with its HTTP connection (0.7.1).
  On both targets its lookups fail over across resolv.conf's nameservers and
  survive a signal (0.8.0), and only take an address for the host asked or its
  CNAME chain (0.8.1); with no resolver configured on Linux it asks 127.0.0.1
  rather than 8.8.8.8, and a resolver that echoes the name in another case
  works (0.8.2). On Linux a send to a server that has gone no longer kills it
  with SIGPIPE (0.9.0).
- **`dig`'s UDP transport onto `taar_udp_*`.** dig's DNS-over-TCP already runs
  on `taar_tcp_*` (its `src/tcp.cyr`). Its connect-then-write UDP transport
  still duplicates `taar_udp_send`'s RFC 5452 reasoning, and dig held it back
  pending a review of taar's AGNOS UDP arm — which taar's harness has executed
  since 0.7.0. dig's DNS layer stays its own by design: it needs any qtype and
  the response bytes, which `taar_resolve_ipv4` deliberately does not give.
  Consumer-repo work.
- **`yo`'s `icmp.cyr`** — waits on the `icmp` backlog item.
