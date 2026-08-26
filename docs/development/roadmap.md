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
- **0.3.3** — P-1 audit. Linux backend moved off hardcoded x86_64 syscall
  numbers (aarch64 `sendto` → `fstatfs` silently broke every resolve there);
  DNS reply acceptance bound to QR/id/QDCOUNT/question-echo on a connected
  socket (RFC 5452); entropy failures fail closed; heap scratch → stack.
  Suite 40 → 73, each guard mutation-verified; aarch64 CI leg added.
- **0.4.0** — DNS over TCP: `taar_resolve_ipv4` retries on the TC bit
  (RFC 1035 §4.2.2 length framing), falling back to the truncated datagram
  answer if the retry fails. `_taar_plat_dns_server` moved to the
  `sys_net_dns_server()` wrapper — the last raw syscall literal in the tree.
  Suite → 89, plus a netns-based integration harness for the TC path.

## Next (per second-consumer / duplication trigger)

- **`icmp` module** — echo packet construction + checksum, lifted from `yo`'s
  `icmp.cyr`; the AGNOS side is `icmp_echo`#55. Note the trigger has *not*
  fired: `yo` is already on `[deps.taar]`, but it is still the only consumer
  with ICMP, so nothing is duplicated yet. Per CLAUDE.md this waits for a
  second ICMP consumer (traceroute is the likely one) rather than being
  pre-built.
- **`tls` / `http` submodules** — as `whirl` forces them (HTTPS today stops
  at the TCP layer taar provides).
- **Consumer pin bump to 0.4.0** — `yo`, `dig` and `whirl` all still pin
  `taar 0.3.1`, so none of them have the 0.3.3 security fixes. This is the
  highest-value item on the list and it is consumer-repo work, not taar work.
- **CI: wire `tests/integration/tc_fallback.sh`** — the TC path has no unit
  coverage by nature. Needs a check that `unshare -rn` is permitted on the
  GitHub runner before it becomes a gate.

## Consumer migration

- `whirl` → **done** (0.2.0): HTTP transport on `taar_tcp_*` +
  `taar_resolve_ipv4`.
- `dig` → on `[deps.taar]`; in-tree `ipv4.cyr` **already dropped**. Still
  carries its own `dns.cyr` + `resolv.cyr` — that dedup onto `taar.dns` /
  `taar.socket` is what remains. Verify host + `--agnos` after.
- `yo` → on `[deps.taar]`; in-tree `ipv4.cyr` **already dropped**. Still
  carries `icmp.cyr` + `dns.cyr`; the `icmp` fold is the open piece.

## v1.0 criteria (not yet scheduled)

- All four planned consumers (yo, dig, whirl, + traceroute if it lands) on
  taar with no in-tree duplication.
- Every module carries a working AGNOS backend, validated on the kernel.
- Frozen public surface + ADR for the module/backend contract.
