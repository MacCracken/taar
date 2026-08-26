# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
