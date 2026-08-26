# taar — Current State

> Refreshed every release. CLAUDE.md is preferences/process (durable); this
> file is **state** (volatile).

## Version

**0.4.0** — 2026-08-26. DNS over TCP. `taar_resolve_ipv4` now honours the TC
(truncated) bit by re-asking over TCP-53 with RFC 1035 §4.2.2 length framing,
holding the TCP reply to the same acceptance rules as the UDP one and falling
back to the truncated datagram answer whenever the retry fails — so the retry
can only improve an answer. `_taar_plat_dns_server` moved onto cyrius 6.5.35's
`sys_net_dns_server()` wrapper, retiring the last raw syscall literal in the
tree. Unit suite 73 → **89**; a netns-based integration harness
(`tests/integration/`) covers the TC path, which is not unit-testable.
`dist/taar.cyr` 922 lines.

**0.3.3** — 2026-08-26. P-1 audit / hardening cut. Six defects fixed across
arch portability, DNS reply acceptance, entropy and memory — all reachable
from `taar_resolve_ipv4`. No public signature changed. Headline: the Linux
backend hardcoded x86_64 syscall numbers, and the one number cyrius's aarch64
ESYSXLAT layer does **not** remap is `sendto` (44 → `fstatfs` on aarch64), so
`taar_udp_send` silently sent nothing and wrote ~120 bytes of `struct statfs`
over the caller's packet buffer. `tests/taar.tcyr` 40 → **73** assertions, each
guard mutation-verified; the suite and a live resolve now run green on
x86_64, aarch64 (qemu) and the AGNOS target. `dist/taar.cyr` 797 lines.

**0.3.2** — 2026-08-26. Toolchain + stdlib refresh; no `src/` changes. Cyrius
pin moved `6.2.6` → `6.5.35` and all 16 vendored `lib/*.cyr` re-resolved from
that snapshot. `cyrius distlib` also began emitting `dist/taar.deps`.

## Toolchain

- **Cyrius pin**: `6.5.35` (`cyrius.cyml [package].cyrius`) — the single source
  of truth; both CI workflows read it to install the toolchain.
- **`[deps] stdlib`**: `syscalls`, `fmt`, `assert`, `alloc`. `lib/` is a
  `cyrius deps` build artifact (gitignored), not source.
- Known benign build warning: `undefined function 'vec_get'` — a `vec`-args
  variadic path in `lib/fmt.cyr` that taar never calls (it uses `fmt_int_buf`
  only); DCE-eliminated. Adding `vec` would push a dep onto consumers that
  don't carry it.
- **Syscall rule (0.3.3):** never write a syscall number as a literal. Go
  through the stdlib's arch-dispatched `sys_*` wrappers. cyrius's aarch64
  backend remaps the x86_64 numbers it recognises, which makes a hardcoded
  literal *look* portable, but the numbers it deliberately cannot remap (those
  colliding with a different native aarch64 call, e.g. `sendto` 44 vs
  `fstatfs`) fail silently at runtime with a clean build. Where no wrapper
  exists, restructure to a call that has one — `taar_udp_send` connects and
  `write(2)`s rather than reaching for `sendto`.
- The shipped bundle is allocator-free. `dist/taar.deps` still echoes the
  project's full `[deps] stdlib` (`assert` → `lib/alloc.cyr`) because the test
  suite needs `assert`; the bundle itself uses only `syscalls` + `fmt`.

## Modules

`[lib].modules` order (single-pass — a module may only reference earlier ones):
`ipv4` → `socket` → `dns`.

| Module | Surface | Status |
|--------|---------|--------|
| `ipv4` | `ipv4_parse`, `ipv4_format_to_buf` | shipped 0.1.0 |
| `socket` | `taar_udp_open/send/recv/set_timeout_ms/close`, `taar_tcp_open/connect/send/recv/set_timeout_ms`, `taar_sock_close`, `taar_fill_sockaddr` | shipped 0.2.0 (Linux); AGNOS backend 0.3.0 |
| `dns` | `taar_resolve_ipv4` (resolver discovery + RFC 1035 A-record query/parse over UDP-53, TCP-53 retry on TC) | shipped 0.2.0; AGNOS kernel-leased resolver 0.3.1; reply-acceptance hardening 0.3.3; TCP fallback 0.4.0 |
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

## Verification (0.4.0)

Run from a clean `cyrius clean` + fresh `cyrius deps`.

- `cyrius audit` — fmt clean, lint clean, tests green.
- **x86_64**: smoke → `taar smoke ok`; `cyrius tests tests/` → 89 passed,
  0 failed; `resolve-smoke` (UDP) and `tcp-resolve-smoke` (TCP) both resolved a
  live domain.
- **aarch64** (`qemu-aarch64`): `cyrius tests --aarch64` → 89 passed, 0 failed;
  smoke ok; `tcp-resolve-smoke` resolved a live domain. The same check against
  0.3.2 exits 1 — this is the regression gate for the sendto defect.
- **Integration** (`tests/integration/tc_fallback.sh`, x86_64 and aarch64): all
  five TC cases pass — TC=0 uses UDP, TC=1 retries TCP, TC=1 with no TCP
  listener falls back, and a TCP peer lying about its framed length (too long,
  too short) is refused. Removing the `mlen > rmax` bound turns the
  over-long case red by killing the process, so that guard is load-bearing.
- **AGNOS**: `CYRIUS_TARGET_AGNOS=1 cyrius build --agnos src/main.cyr` → OK,
  and the image differs from the Linux build (confirms the `#ifdef` arm is
  taken).
- Guard coverage is **mutation-verified**: removing any single bounds check in
  `dns.cyr` turns the suite red. The one exception is the `ptr >= msg_len`
  check in `_taar_dns_skip_name`, which is provably redundant given the
  backward-pointer rule and is kept as defence-in-depth (noted in-source).
- `cyrius distlib --check` → committed bundle current.

## Carry-forward

- `dig` and `yo` are on `[deps.taar]` and have dropped their in-tree
  `ipv4.cyr`. What remains: `dig` still carries its own `dns.cyr` + `resolv.cyr`
  to dedup onto `taar.dns` / `taar.socket`; `yo` still carries `icmp.cyr`.
- `icmp` waits for a **second** ICMP consumer, not just yo's migration — yo is
  already on taar and nothing is duplicated yet, so folding now would be the
  speculative pre-build CLAUDE.md rules out. `tls`/`http` likewise wait on
  `whirl`.
- **Consumers are pinned at `taar 0.3.1`** (`yo` 0.5.7, `dig` 0.3.5,
  `whirl` 0.6.4), so none of them carry the 0.3.3 security fixes — the aarch64
  `sendto` defect or the DNS reply-acceptance hardening — let alone 0.4.0.
  Bumping those pins is the highest-value open item; it is consumer-repo work.
- Wire `tests/integration/tc_fallback.sh` into CI once `unshare -rn` is
  confirmed permitted on the GitHub runner. Until then the TC path is guarded
  only by a manual run.
- 15 undocumented public fns reported by `cyrius audit` docs pass; not CI-gated.
- **AGNOS `taar_tcp_recv` conflates timeout with EOF.** A deadline expiry
  returns `0`, the same value as a clean peer close, so a peer that stalls
  mid-body can make a truncated read look like a complete one. The fix is to
  give timeout its own negative return, which is a breaking change for whirl's
  transport — schedule it with a whirl cut, not a taar patch. 0.4.0's TCP DNS
  read inherits this: on AGNOS a stall ends `_taar_dns_tcp_read_all` early, the
  short read is refused, and the resolve falls back to the UDP answer. Safe,
  but it means the TC retry is best-effort on AGNOS rather than reliable.
- **`ipv4_parse` accepts leading zeros as decimal.** `010.1.1.1` parses as
  10.1.1.1; `inet_aton(3)` would read octal and say 8.1.1.1. Harmless while
  consumers use the packed return value, but a consumer that validates with
  taar and then hands the *string* to libc would get a different address —
  the classic parser-differential SSRF shape. Current behaviour is pinned by
  test; decide deliberately before changing it.
- The AGNOS backend has no automated coverage at all — it only compiles. The
  `#ifdef` arm is verified by build + image-differs, never executed.
