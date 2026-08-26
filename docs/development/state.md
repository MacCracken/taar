# taar — Current State

> Refreshed every release. CLAUDE.md is preferences/process (durable); this
> file is **state** (volatile).

## Version

**0.3.2** — 2026-08-26. Toolchain + stdlib refresh; no `src/` changes. Cyrius
pin moved `6.2.6` → `6.5.35` and all 16 vendored `lib/*.cyr` re-resolved from
that snapshot — absorbed with no source edit. `dist/taar.cyr` regenerated (677
lines, 24,645 bytes); its body is byte-identical to 0.3.1 apart from the version
header. `cyrius distlib` now also emits `dist/taar.deps`. Smoke green;
`tests/taar.tcyr` 40 assertions / 0 failed; live UDP-53 resolve confirmed;
AGNOS target compiles.

## Toolchain

- **Cyrius pin**: `6.5.35` (`cyrius.cyml [package].cyrius`) — the single source
  of truth; both CI workflows read it to install the toolchain.
- **`[deps] stdlib`**: `syscalls`, `fmt`, `assert`, `alloc`. `lib/` is a
  `cyrius deps` build artifact (gitignored), not source.
- Known benign build warning: `undefined function 'vec_get'` — a `vec`-args
  variadic path in `lib/fmt.cyr` that taar never calls (it uses `fmt_int_buf`
  only); DCE-eliminated. Adding `vec` would push a dep onto consumers that
  don't carry it.

## Modules

`[lib].modules` order (single-pass — a module may only reference earlier ones):
`ipv4` → `socket` → `dns`.

| Module | Surface | Status |
|--------|---------|--------|
| `ipv4` | `ipv4_parse`, `ipv4_format_to_buf` | shipped 0.1.0 |
| `socket` | `taar_udp_open/send/recv/set_timeout_ms/close`, `taar_tcp_open/connect/send/recv/set_timeout_ms`, `taar_sock_close`, `taar_fill_sockaddr` | shipped 0.2.0 (Linux); AGNOS backend 0.3.0 |
| `dns` | `taar_resolve_ipv4` (resolv.conf discovery + RFC 1035 A-record query/parse over UDP-53) | shipped 0.2.0; AGNOS kernel-leased resolver via `net_config`#61 in 0.3.1 |
| `icmp` | echo packet + checksum | planned (folds when `yo` migrates) |
| `tcp`/`tls`/`http` | HTTPS transport growth | planned (`whirl`-driven) |

Both socket/dns backends ship in the bundle behind `#ifdef
CYRIUS_TARGET_AGNOS`, resolved at the **consumer's** compile target.

## Consumers

| Consumer | Role | taar adoption |
|----------|------|---------------|
| `whirl` | curl/wget (HTTP/S) | **on taar** since whirl 0.2.0 — HTTP transport over `taar_tcp_*` + `taar_resolve_ipv4` |
| `dig` | DNS resolver | pending — dedup onto `taar.dns` / `taar.socket` |
| `yo` | ping / ICMP | pending — folds `ipv4`; drives the `icmp` module |

## Verification (0.3.2)

- `cyrius audit` — fmt clean, lint clean, tests green.
- `cyrius build programs/smoke.cyr` + run → `taar smoke ok`.
- `cyrius tests tests/` → 40 passed, 0 failed.
- `programs/resolve-smoke.cyr` → resolved a live domain over UDP-53.
- `CYRIUS_TARGET_AGNOS=1 cyrius build --agnos src/main.cyr` → OK, and the image
  differs from the Linux build (confirms the `#ifdef` branch is taken).
- `cyrius distlib --check` → committed bundle current.

## Carry-forward

- Migrate `dig` + `yo` off their in-tree `src/ipv4.cyr` (and dig's own
  `dns.cyr`/`resolv.cyr`) onto `[deps.taar]`; verify each still builds host +
  `--agnos`.
- `icmp` folds when `yo` migrates; `tls`/`http` as `whirl` forces them.
- Replace the interim raw `syscall(61, 3)` in `src/socket.cyr`
  (`_taar_plat_dns_server`) with a cyrius `sys_net_config` wrapper once the
  toolchain ships one — requested as agnos
  `2026-06-23-agnos-net-config-syscall-wrapper`.
- 17 undocumented public fns reported by `cyrius audit --docs`; not CI-gated.
