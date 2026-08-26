# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.3] — 2026-08-26 — P-1 audit: hardening + repairs

A priority-1 sweep of the whole substrate — arch portability, the DNS reply
path, entropy, and memory. Six defects fixed, all reachable from
`taar_resolve_ipv4`, the one public entry point that parses attacker-supplied
bytes. No public signature changed; consumers rebuild unmodified.

### Fixed

- **aarch64: `taar_udp_send` sent nothing and overwrote the caller's packet
  buffer.** The Linux backend hardcoded x86_64 syscall numbers. cyrius's
  aarch64 backend rewrites the numbers it recognises (ESYSXLAT), which is why
  `--aarch64` builds were clean and most calls worked — but **sendto has no
  entry**, because it has no stdlib wrapper or `SYS_SENDTO` constant. x86_64
  44 is `sendto`; aarch64 44 is `fstatfs(2)`. The old
  `syscall(44, fd, pkt, len, …)` therefore returned 0 (which passed taar's
  `sent < 0` check), transmitted nothing, and wrote ~120 bytes of
  `struct statfs` over the DNS query buffer. Every aarch64 resolve then blocked
  until the 5s timeout and failed. **Verified under `qemu-aarch64`:** the 0.3.2
  `resolve-smoke` exits 1 on aarch64 while succeeding on x86_64; 0.3.3 returns
  an address on both.
  - The whole Linux backend now goes through the stdlib's arch-dispatched
    wrappers (`sys_socket` / `sys_connect` / `sys_setsockopt` / `sys_recvfrom`
    / `sys_read` / `sys_write` / `sys_close` / `sys_openat`).
  - `taar_udp_send` is now `connect(2)` + `write(2)` instead of `sendto` —
    there is no sendto wrapper to switch to, and this closes a security gap
    at the same time (below). `_taar_plat_read_file` moved to `sys_openat`,
    since bare `open(2)` does not exist on aarch64 at all.
  - `programs/resolve-smoke.cyr` (`syscall(1, …)`) and `tests/taar.tcyr`
    (`syscall(60, …)`) carried the same literals; both now use the dispatched
    forms.

- **DNS replies were accepted on a 16-bit ID alone (RFC 5452).** The UDP socket
  was unconnected, so the kernel delivered datagrams from *any* source, and
  taar checked only the query ID and rcode. A forged reply that guessed the ID
  was accepted — its QR bit, question section and source were never examined.
  Worse, a single non-matching datagram aborted the whole resolve, so one
  stray packet was a reliable denial of service. Now:
  - the socket is connected to the nameserver, so the kernel drops anything
    not from that address/port (an off-path attacker must also guess the
    ephemeral source port);
  - a datagram is parsed only if QR=1, the ID matches, QDCOUNT is 1, and the
    question section is echoed back byte-for-byte (`_taar_dns_same_question`);
  - non-matching datagrams are skipped and the wait resumes, bounded by
    `_TAAR_DNS_MAX_REPLIES` (8).

- **The DNS query ID could be uninitialised stack.** `_taar_plat_random_u16`
  ignored the result of its `/dev/urandom` read (and, on AGNOS, of
  `sys_getrandom`), so a short or failed draw left the 2-byte buffer
  uninitialised and its garbage became the query ID — the precise opposite of
  what RFC 5452, cited in that function's own comment, asks for. The AGNOS
  ephemeral **source port** (`_taar_ag_ephemeral_port`) had the identical bug.
  Both now zero-initialise, check the byte count, and return -1 so the caller
  fails closed rather than resolving with a guessable ID. Linux draws from
  `getrandom(2)` directly instead of opening `/dev/urandom`.

- **`taar_resolve_ipv4` leaked 6.4 KB per call and never checked `alloc`.**
  cyrius's `alloc` is a bump allocator with no per-pointer `free`, so the
  300 B query, 2 KB reply and 4 KB resolv.conf buffers were gone for the
  process lifetime — unbounded growth in a long-running consumer. The return
  was also never checked, so allocator exhaustion meant stores through a null
  pointer. All three are now function-local stack, matching the allocator-free
  posture `socket.cyr` already documented. The bundle no longer references the
  allocator at all.

- **`taar_fill_sockaddr` did not exist on AGNOS.** It was defined inside the
  `#ifndef CYRIUS_TARGET_AGNOS` arm despite being public API and pure,
  syscall-free byte packing, so an AGNOS-target consumer calling it failed to
  link — against this module's "identical `taar_*` surface" contract. Hoisted
  out of both arms.

- **An empty hostname produced a well-formed query for the root zone.**
  `_taar_dns_encode_name("")` returned the bare root label and
  `_taar_dns_build_query` wrapped it into a valid A query for `"."`. Both now
  reject it, and `taar_resolve_ipv4` rejects an empty host before opening a
  socket. A trailing dot (`"example.com."`) is still accepted and encodes
  identically to the undotted form.

### Tests

- `tests/taar.tcyr` → **73 assertions** (was 40), adding four groups:
  `dns-reply-match` (QR / TC / question-echo binding), `dns-hostile`
  (self-referential, forward and out-of-range compression pointers; reserved
  label prefixes; a maximum-length label; rdata running past the message end;
  header-only truncation), `dns-encode-edges`, and `resolve-guards`
  (null/empty host and literal short-circuit — all offline).
- Every guard was **mutation-tested**: each bounds check was individually
  removed and the suite confirmed to go red. Two initial tests did not survive
  this and were rewritten — an over-long `rdlength` case that never reached the
  bounds check, and a reserved-label-prefix case masked by the
  end-of-message check.
- Suite now also run green under `--aarch64` (via `qemu-aarch64`), which is how
  the sendto defect was caught and confirmed fixed.

### Notes
- `ipv4_parse` accepts leading zeros and reads them as **decimal**: `010.1.1.1`
  is 10.1.1.1, where `inet_aton(3)` would say 8.1.1.1. taar's callers consume
  the packed return value rather than re-parsing the string, so this is now
  pinned by test rather than changed; see the state.md carry-forward.
- AGNOS `taar_tcp_recv` still reports a deadline expiry as `0`, the same value
  as a clean peer close, so a stalled peer can make a truncated read look
  complete. Giving timeout its own return is a breaking change for whirl's
  transport and is left as a tracked carry-forward, not slipped into a patch.
- `dist/taar.deps` still lists `assert` and `alloc`: the sidecar echoes the
  project's `[deps] stdlib`, and the test suite needs `assert`, which itself
  includes `lib/alloc.cyr`. The shipped bundle no longer uses either.

## [0.3.2] — 2026-08-26 — toolchain + stdlib refresh

Maintenance cut: no `src/` changes. The cyrius pin and the vendored stdlib
snapshot both move up to current, and `cyrius distlib` gains a dep sidecar.

### Changed
- **Cyrius pin `6.2.6` → `6.5.35`** (`cyrius.cyml [package].cyrius`). The pin is
  the single source of truth both CI workflows read to install the toolchain, so
  this is the only place the version appears. Clears the `toolchain drift`
  warning cycc emitted on every build.
- **Vendored stdlib re-resolved from the 6.5.35 snapshot** — all 16 `lib/*.cyr`
  files changed (`lib/` is a `cyrius deps` build artifact, gitignored, not
  source). Largest deltas are the syscall tables: `syscalls_x86_64_agnos.cyr`
  23,656 → 79,649 bytes, `syscalls_windows.cyr` 6,261 → 18,078,
  `syscalls_aarch64_linux.cyr` 20,115 → 31,870; also `alloc.cyr` 26,485 → 42,247
  and `fmt.cyr` 7,878 → 12,844. No taar source change was needed to absorb them.
- `dist/taar.cyr` regenerated at 0.3.2 — bundle body is **byte-identical** to
  0.3.1 apart from the version header, confirming the stdlib bump is
  source-transparent to consumers.

### Added
- **`dist/taar.deps`** — dep sidecar now emitted by `cyrius distlib` (6.5.35),
  listing the four stdlib leaves the bundle needs in scope (`syscalls`, `fmt`,
  `assert`, `alloc`) for a consumer's `cyrius deps` to pick up. Matches
  `[deps] stdlib` exactly. Ships alongside `dist/taar.cyr`.

### Verified
- Linux: `cyrius build programs/smoke.cyr` + smoke run green; **40** unit
  assertions / 0 failed (unchanged); `programs/resolve-smoke.cyr` resolved a
  live domain over UDP-53.
- AGNOS: `CYRIUS_TARGET_AGNOS=1 cyrius build --agnos src/main.cyr` compiles the
  sovereign backend; the emitted image differs from the Linux build, confirming
  the `#ifdef` branch is taken.
- `cyrius audit` — fmt clean, lint clean, tests green. `cyrius distlib --check`
  reports the committed bundle current.

### Notes
- The pre-existing `undefined function 'vec_get'` warning is unchanged: it comes
  from a `vec`-args variadic path in `lib/fmt.cyr` that taar never calls (taar
  uses `fmt_int_buf` only), and it is dead-code-eliminated. Adding `vec` to
  `[deps] stdlib` would push a dep onto consumers that don't carry it.

## [0.3.1] — 2026-06-23

### Added
- **AGNOS resolver discovery prefers the kernel-leased DNS server.** On agnos,
  `_taar_resolv_discover` (`src/dns.cyr`) now calls the new **`net_config(3)`#61**
  syscall first via `_taar_plat_dns_server` (`src/socket.cyr`) — the DHCP option-6
  on-subnet resolver — and uses it when `> 0`, before `/etc/resolv.conf` and the
  `8.8.8.8` fallback. The off-subnet fallback needs working gateway routing the kernel
  can't guarantee on real iron (it froze `whirl https://google.com` on archaemenid);
  the leased resolver is on-subnet + directly ARP-reachable. The Linux backend's
  `_taar_plat_dns_server` returns `0`, so the `/etc/resolv.conf` path is unchanged
  there. Interim raw `syscall(61, 3)` (a cyrius `sys_net_config` wrapper is requested,
  agnos `2026-06-23-agnos-net-config-syscall-wrapper`). **Requires agnos ≥ 1.45.16.**

## [0.3.0] — 2026-06-18 — AGNOS sovereign backend

The socket substrate gains its **AGNOS backend**, selected at compile time by the
cyrius emit target (`CYRIUS_TARGET_AGNOS=1`). The `taar_*` API is identical across
both targets — consumers (`whirl`'s transport, `taar`'s own DNS) never branch.

### Added
- **`src/socket.cyr` AGNOS backend** (`#ifdef CYRIUS_TARGET_AGNOS`) — sovereign
  ring-3 syscalls via cyrius's agnos syscall lib, mirroring `dig`'s `platform_agnos.cyr`:
  - **TCP** over `sock_connect`#47 / `sock_send`#48 / `sock_recv`#49 / `sock_close`#50.
    AGNOS has no `socket()`+`connect()` split, so `taar_tcp_open` resets the conn
    slot and `taar_tcp_connect` does the real `sock_connect` (ephemeral src port from
    `getrandom`#45), stashing the conn_id (single active conn; taar is single-threaded).
    `sock_recv`#49 is non-blocking (`>0` / `0`=WOULD_BLOCK / `-1`=EOF) — `taar_tcp_recv`
    polls it against an `uptime_ms`#40 deadline and maps the result back to the Linux
    blocking-read sense (`>0` data, `0`=closed) callers expect.
  - **UDP** over `udp_bind`#51 / `udp_send`#52 / `udp_recv`#53 / `udp_unbind`#54
    (ephemeral source port; packed `(sport<<16)|dport`; deadline-polled recv).
  - **Platform helpers** `_taar_plat_random_u16` (`getrandom`#45) + `_taar_plat_read_file`
    (`sys_open`/`read`/`close`) — relocated here from `dns.cyr` so DNS stays
    platform-neutral RFC-1035 framing.
- **`taar_udp_close`** — splits UDP teardown (`udp_unbind`#54 on AGNOS) from
  `taar_sock_close` (TCP `sock_close`#50). On Linux both remain `close(2)`. `dns.cyr`
  now closes its UDP listener via `taar_udp_close`.

### Changed
- `src/socket.cyr` Linux backend wrapped in `#ifndef CYRIUS_TARGET_AGNOS`; the
  entropy/file helpers `_taar_dns_random_u16` / `_taar_dns_read_file` removed from
  `dns.cyr` (folded into the platform helpers).
- `dist/taar.cyr` regenerated (643 lines) — the `#ifdef` blocks survive the bundle
  concatenation and resolve at the **consumer's** compile target.

### Verified
- Linux: build + smoke + **40** unit assertions green (unchanged).
- AGNOS: `CYRIUS_TARGET_AGNOS=1 cyrius build src/main.cyr` compiles the sovereign
  backend — `sys_sock_*` / `sys_udp_*` / `sys_getrandom` / `sys_uptime_ms` /
  `sys_sleep_ms` resolve from the agnos syscall lib (same path `dig` proved).

## [0.2.0] — 2026-06-18 — socket + dns (whirl extraction)

`whirl` (the third network-tools consumer) drove the next two substrate modules.
The transport `whirl` needs — TCP + hostname resolution — is lifted here as the
documented "taar grows" step, so `dig` can dedup onto it later.

### Added
- **`src/socket.cyr`** — raw-syscall UDP + TCP primitives (Linux backend; the
  AGNOS `#ifdef` backend is a follow-up). `taar_udp_open` / `taar_udp_send` /
  `taar_udp_recv` / `taar_udp_set_timeout_ms`; `taar_tcp_open` / `taar_tcp_connect`
  / `taar_tcp_send` / `taar_tcp_recv` / `taar_tcp_set_timeout_ms`; `taar_sock_close`
  + the shared `taar_fill_sockaddr`. Allocator-free (stack scratch), no lib/net.cyr.
- **`src/dns.cyr`** — `taar_resolve_ipv4(host)`: resolv.conf discovery + RFC 1035
  A-record query build + response parse (pointer-loop-guarded), over UDP-53.
  Ported from dig's `dns.cyr` + `resolv.cyr`, narrowed to the A-record path;
  framing helpers are `_taar_dns_*`-prefixed so this coexists with dig's own
  `dns.cyr` until dig refactors. A literal dotted-quad short-circuits the lookup.
- **`programs/resolve-smoke.cyr`** — live DNS check (resolves a real domain).
- `dist/taar.cyr` regenerated (ipv4 + socket + dns); `[deps] stdlib` gains `alloc`.

### Tests
- `tests/taar.tcyr` → **40 assertions** (ipv4 17 + sockaddr 10 + dns encode/build/
  parse-A 13). Live resolve confirmed (`example.com` → a real Cloudflare IP).

### Notes
- First consumer: `whirl` 0.2.0 (HTTP transport over `taar_tcp_*` + `taar_resolve_ipv4`).
- Still planned: the AGNOS socket backend (`sock_*`#47-50 / `udp_*`#51-54), `icmp`
  (for `yo`), and `tcp`/`tls`/`http` growth; `dig` dedups onto `taar.dns`/`socket`.

## [0.1.0] — 2026-06-14 — extraction: IPv4 codec

First cut of the network-tools substrate library. Opened at the documented
extraction trigger — `yo` 0.5.4 and `dig` 0.3.2 carried a byte-identical
`src/ipv4.cyr`; that duplication is the signal to extract a shared lib (the
same second-consumer pattern as `mihi → iam/chakshu`).

### Added
- **`src/ipv4.cyr`** — the strict dotted-quad IPv4 codec, taar's canonical
  home for it: `ipv4_parse` (dotted-quad → packed u32, `IPV4_PARSE_FAIL`
  sentinel on any rejection) and `ipv4_format_to_buf` (packed u32 →
  dotted-quad, returns bytes written). Packing matches
  `agnos/kernel/core/net.cyr` `ip4()` so a parsed address feeds the AGNOS
  `sock_connect` / `udp_send` packed-addr argument directly.
- **`[lib]` distlib** → `dist/taar.cyr` (consumer bundle); `[deps] stdlib`
  = `syscalls` / `fmt` / `assert`.
- **`programs/smoke.cyr`** — parse → format round-trip; **`tests/taar.tcyr`**
  — 17 assertions (valid/reject parse cases + format + round-trip).
- Repo scaffold: README, LICENSE (GPL-3.0-only), CLAUDE.md, docs/development.

### Notes
- Consumers `yo` and `dig` fold their in-tree `ipv4.cyr` onto this module in
  follow-on patch cuts; their AGNOS backends (`platform_agnos.cyr`) are
  unaffected — `ipv4` is pure code with no syscalls.
- Planned modules (grow per second-consumer trigger): `socket` (UDP/ICMP
  shim, Linux + AGNOS backends), `icmp` (echo + checksum), `dns` (query
  build / response parse / name compression). `whirl` arrives as the third
  consumer and adds the TCP/TLS/HTTP submodules.
