# taar — Current State

> **Snapshot, refreshed every release.** Only what is true *now* — release
> history belongs in [`CHANGELOG.md`](../../CHANGELOG.md), forward work in
> [`roadmap.md`](roadmap.md), durable process in
> [`CLAUDE.md`](../../CLAUDE.md). If a fact here is also stated in one of
> those, this file is the one that goes stale; prefer deleting it.

## Version

**0.7.1** — 2026-11-09. Last P(-1) review (0.6.2):
[`docs/audit/2026-11-08-audit.md`](../audit/2026-11-08-audit.md).

`dist/taar.cyr` is 1322 lines (`wc -l`; `cyrius distlib` reports 1305, excluding
its 17-line generated header and `# Requires` block — the two numbers are the
same bundle).

## Toolchain

- **Cyrius pin**: `6.7.18` (`cyrius.cyml [package].cyrius`) — the single source
  of truth. Both CI workflows read it to install the toolchain; no version is
  hardcoded in YAML.
- **`lib/`** is a `cyrius deps` build artifact (gitignored), not source. At this
  pin it resolves to 20 files, every one byte-identical to the 6.7.18 bundled
  stdlib snapshot (19 from `[deps] stdlib`, plus `bench` from `[test] stdlib`).
- **Dependency surface.** `[deps] stdlib` is `syscalls`, `fmt`, `assert`,
  `alloc` — taar's *build* list. What a consumer needs is what `distlib`'s
  compile-verify derives: **`syscalls` and `fmt`**, written to both
  `dist/taar.deps` and the bundle's `# Requires` block. `assert` and `alloc`
  serve the test suite and smoke programs and do not reach the sidecar; `bench`
  is in `[test] stdlib`, which only test / bench / fuzz compiles see.
- Known benign `distlib` warning: `sys_openat (x86_64-windows)` still undefined
  after the sidecar verify. taar's non-AGNOS `socket` arm is Linux-only
  (`sys_openat` lives in `lib/syscalls_linux_common.cyr`), and Windows is not a
  taar target. The verify compiles six targets and reports the gap; it does not
  fail the run.

## Modules

`[lib].modules` order (single-pass — a module may only reference earlier ones):
`ipv4` → `socket` → `dns`.

| Module | Surface | Since |
|--------|---------|-------|
| `ipv4` | `ipv4_parse`, `ipv4_format_to_buf` | 0.1.0 |
| `socket` | `taar_udp_open/send/recv/set_timeout_ms/close`, `taar_tcp_open/connect/send/recv/set_timeout_ms`, `taar_sock_close`, `taar_fill_sockaddr` | 0.2.0 (Linux); AGNOS backend 0.3.0; arch-dispatched syscalls 0.3.3; recv-timeout parity 0.5.0; TCP timeout bounds connect + send, AGNOS reply-source filter 0.6.2; AGNOS executed, send deadline + no-connection errors 0.7.0; per-socket AGNOS state, fd validation 0.7.1 |
| `dns` | `taar_resolve_ipv4` — resolver discovery, RFC 1035 A-record query/parse over UDP-53, TCP-53 retry on TC | 0.2.0; AGNOS kernel-leased resolver 0.3.1; reply-acceptance hardening 0.3.3; TCP fallback 0.4.0; fail-closed resolver choice 0.6.2 |

Planned modules and their triggers live in [`roadmap.md`](roadmap.md).

**`src/socket.cyr` is the only module with per-target arms** — one
`#ifdef CYRIUS_TARGET_AGNOS` split, resolved at the *consumer's* compile
target. `ipv4` is a pure codec with no syscalls; `dns` is platform-neutral
RFC-1035 framing that reaches the kernel only through `socket`'s helpers. The
`taar_*` surface is identical on both targets, so consumers never branch.

## Consumers

| Consumer | Role | Adoption | Pinned at |
|----------|------|----------|-----------|
| `whirl` | curl/wget (HTTP/S) | fully migrated — HTTP transport on `taar_tcp_*` + `taar_resolve_ipv4`, live on both targets | 0.6.2 |
| `dig` | DNS resolver | on `[deps.taar]`, in-tree `ipv4.cyr` dropped; own `dns.cyr` + `resolv.cyr` still to dedup | 0.6.2 |
| `yo` | ping / ICMP | on `[deps.taar]`, in-tree `ipv4.cyr` dropped; still carries `icmp.cyr` | 0.6.2 |

All three are on cyrius `6.7.18`, taar's own pin. `yo` and `dig` call only
`ipv4`, which 0.7.x does not change. `whirl` is the consumer 0.7.x is for: on
AGNOS its sends are unbounded by its 10 s deadline, and its resolve shares
socket state with its HTTP connection, until it bumps (roadmap, *Consumer
migration*).

## Verification

What is actually gated, and what is not.

**Automated (CI: `build`, `aarch64`, `integration`, `agnos`, `security`, `docs`)**

- `cyrius audit` — fmt, lint, docs and tests all green over `src/`,
  `programs/`, `tests/` (including `tests/agnos/`) and `benches/`. Lint and doc
  coverage are hard gates in the `build` job over the same files; `audit` alone
  only reports them.
- **x86_64**: smoke round-trip; unit suite **140 passed / 0 failed** (21
  groups).
- **aarch64** (`qemu-aarch64`, `unit` + smoke *executed*, not just built) — 140
  passed / 0 failed. This leg exists because the 0.3.3 `sendto` defect built
  clean and only failed at runtime.
- **Integration, Linux** (`tests/integration/tc_fallback.sh`): seven cases —
  TC=0 uses UDP, TC=1 retries TCP, TC=1 with no TCP listener falls back, a TCP
  peer lying about its framed length (too long, too short) is refused, a TCP/53
  that drops SYNs is given up on at the 5 s deadline, and a UDP reply forged
  from the wrong port is ignored. The script builds its own resolve binary from
  the checkout and runs each case under a 30 s timeout, as PID 1 of its own PID
  namespace. The job relaxes Ubuntu's AppArmor user-namespace restriction, then
  probes and warns-and-skips where namespaces are still forbidden.
- **AGNOS, executed** (`tests/agnos/run.sh`, the `agnos` job): boots agnos
  1.57.19 with the gnoboot 0.9.0 loader under QEMU + OVMF — both release
  binaries checked against SHA-256s pinned in `tests/agnos/pins.sh` — with
  `tests/agnos/selftest.cyr` as `/bin/agnsh`, the kernel's first program.
  **84 checks**, ~15 s with KVM (~23 s under TCG, `TAAR_AGNOS_TCG=1`): UDP (open, timeouts, payload-count send,
  reply-source filter with a non-vacuity check that the forgeries arrive,
  fresh-socket peer reset), TCP (connect, send, read to EOF, recv and send
  deadlines, refused and SYN-dropped connects, no-connection errors), per-socket
  state (fd validation, the 8-slot TCP table, fresh-socket defaults, and a
  consumer's TCP and UDP sockets surviving a resolve intact), and
  `taar_resolve_ipv4` end to end through the kernel's DHCP lease against
  `fake_dns.py bylabel` (TC=0, TC retry, three TCP-failure fallbacks, a forged
  reply). Peers and the fake resolver run in a private user + net + mount + PID
  namespace. Exit 2 is VOID (a prerequisite missing) and fails CI.
- `cyrius distlib --check` — a hard gate: the committed bundle must match a
  fresh regeneration. (Before 0.6.2 CI only warned.)
- **Security job** — fails on any syscall-number literal in `src/`,
  `programs/` or `tests/agnos/` (CLAUDE.md's rule).
- `cyrius bench benches/` runs, so the benches keep compiling; the timings are
  not gated (CI runners are too noisy).
- **Supply chain** — `actions/checkout` and `softprops/action-gh-release` are
  SHA-pinned, the cyrius installer is fetched at the pinned tag (it verifies the
  release's checksum and signature), and the token is read-only except in the
  release job.

**Manual / local only**

- `programs/resolve-smoke.cyr` (UDP) and `programs/tcp-resolve-smoke.cyr` (TCP)
  need a live resolver, so they are not CI jobs.
- **The AGNOS send probe's pre-1.57.13 fallback** (`sock_send#48` when
  `sock_send_dl#109` is absent) is not reached by CI, which boots 1.57.19. It was
  run once by hand against agnos 1.57.12 (`TAAR_AGNOS_KERNEL`): 52 of 53 pass,
  the one red being the 500 ms send deadline, which that kernel can only end at
  its own ~8 s.
- **aarch64 AGNOS** compiles; agnos does not boot on aarch64 yet, so nothing
  runs it.

**Guard coverage is mutation-verified.** Removing any single bounds or
acceptance check in `dns.cyr`, or any of the 0.6.2 guards in `socket.cyr`
(18 checked in the 0.6.2 review), turns the suite red. The AGNOS arm is
mutation-checked through the harness: 14 mutations at 0.7.0 (source filter and
each half of the peer match, payload-count send, both negative-timeout checks,
timeout 0, the fresh-socket peer reset, recv's timeout code, the send deadline,
its 0 → timeout map, the empty-send and no-connection guards), all red but one;
17 more at 0.7.1 for the per-socket tables (fd range and open checks, each
field open initialises, close freeing a slot, the connect-on-connected refusal,
the table bound, the empty-recv guard), 16 red, with the 0.7.0 set re-run
against the rewritten arm. The green one widens the TCP table's scan bound from
8 to 16: the slots past the table read the connection table's -1 entries as "in
use", so nothing changes. Removing the bound outright is red.
The Linux forged-reply case was checked the same way (unconnected `sendto`
accepts the forgery). The exceptions are all commented in-source:
- the `ptr >= msg_len` check in `_taar_dns_skip_name` (redundant given the
  backward-pointer rule — unlike the hop budget, which is load-bearing);
- the `len < _TAAR_DNS_HEADER_LEN` check in `_taar_dns_reply_ok` (the
  question-echo check rejects the same inputs; it is kept because it is what
  makes the header reads above it in-bounds);
- the two `set_timeout` result checks in `dns.cyr` (no test can make
  `setsockopt` fail on a fresh socket);
- the DNS retry's `_TAAR_DNS_TCP_MAX_SPINS` cap (since 0.7.0 neither backend
  returns 0 for a non-empty send with a deadline set, so nothing reaches it);
- the AGNOS `taar_tcp_send` no-connection guard (redundant: the kernel refuses
  conn -1 itself — the one green mutation above).

## Carry-forward

- **AGNOS differs from Linux in three known ways**, all in
  [`roadmap.md`](roadmap.md) 0.7.x: EOF indistinguishable from a reset, and a
  connect bounded by the kernel's ~8 s rather than the caller's timeout — agnos
  already has the ABI for both, and they wait on cyrius stdlib wrappers (open
  cyrius issues); and a UDP listener that keeps one datagram, so a stray arrival
  can evict a DNS reply (a failed resolve, never a wrong one) — filed with agnos
  as issue `2026-11-09-a-udp-listener-keeps-one-datagram-…`.
- **AGNOS fds are taar's, not the kernel's, for TCP**: 64..71, eight at most
  (the kernel's conn table). UDP fds are the kernel listener id, 0..7.
- **Resolve waits are bounded per call, not per resolve** — no monotonic clock
  in the consumers' stdlib. Worst case UDP 8 × 5 s; the TCP retry 5 s connect +
  16 reads × 5 s.
- **resolv.conf missing or unreadable → 8.8.8.8.** A file naming only resolvers
  taar cannot use fails closed (0.6.2); the missing-file default is an open
  decision (glibc / musl use 127.0.0.1).
- **`ipv4_parse` accepts leading zeros as decimal** — a pending decision, not a
  defect; behaviour is pinned by test. Detail in [`roadmap.md`](roadmap.md).
