# taar — Roadmap

> Milestone sequence. Volatile current-state lives in
> [`state.md`](state.md).

## Shipped

- **0.1.0** — extraction cut: `ipv4` codec module (`ipv4_parse` +
  `ipv4_format_to_buf`), distlib + smoke + 17-assertion test suite, repo
  scaffold.
- **0.2.0** — `socket` (Linux raw-syscall UDP + TCP) and `dns`
  (`taar_resolve_ipv4`: resolv.conf discovery + RFC 1035 A-record
  query/parse over UDP-53), driven by `whirl` as the third consumer.
  `programs/resolve-smoke.cyr`; suite to 40 assertions.
- **0.3.0** — the AGNOS socket backend behind `#ifdef CYRIUS_TARGET_AGNOS`:
  TCP over `sock_*`#47-50, UDP over `udp_*`#51-54, plus the
  `_taar_plat_*` entropy/file helpers. Identical `taar_*` API across targets.
- **0.3.1** — AGNOS resolver discovery prefers the kernel-leased DNS server
  via `net_config`#61 (on-subnet, ARP-reachable) ahead of `/etc/resolv.conf`.
- **0.3.2** — toolchain + stdlib refresh: cyrius pin `6.2.6` → `6.5.35`, all
  vendored `lib/*.cyr` re-resolved, `dist/taar.deps` sidecar. No `src/` change.

## Next (per second-consumer / duplication trigger)

- **`icmp` module** — echo packet construction + checksum (from `yo`). Folds
  when `yo` migrates; the AGNOS side is `icmp_echo`#55.
- **`tls` / `http` submodules** — as `whirl` forces them (HTTPS today stops
  at the TCP layer taar provides).
- **DNS TCP fallback on TC** — when a reply sets the TC (truncated) bit, retry
  the query over TCP-53 rather than parsing the partial UDP message.
  `_taar_dns_hdr_tc` already surfaces the bit; the transport
  (`taar_tcp_*`) is already in place.
- **`sys_net_config` wrapper** — replace the interim raw `syscall(61, 3)` in
  `src/socket.cyr` once cyrius ships the typed wrapper (requested as agnos
  `2026-06-23-agnos-net-config-syscall-wrapper`).

## Consumer migration

- `whirl` → **done** (0.2.0): HTTP transport on `taar_tcp_*` +
  `taar_resolve_ipv4`.
- `dig` → `[deps.taar]`, drop in-tree `ipv4.cyr` and dedup its
  `dns.cyr`/`resolv.cyr` onto `taar.dns`/`taar.socket`; verify host + `--agnos`.
- `yo` → `[deps.taar]`, drop in-tree `ipv4.cyr`; drives the `icmp` fold.

## v1.0 criteria (not yet scheduled)

- All four planned consumers (yo, dig, whirl, + traceroute if it lands) on
  taar with no in-tree duplication.
- Every module carries a working AGNOS backend, validated on the kernel.
- Frozen public surface + ADR for the module/backend contract.
