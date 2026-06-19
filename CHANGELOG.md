# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
