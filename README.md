# taar

> तार — *wire / string / connection.*

**taar** is the network-probe substrate library for AGNOS's first-party
network tools. It holds the primitives those tools share — address codecs,
socket I/O, packet construction, DNS — so each tool (`yo`, `dig`, `whirl`)
stays a thin front-end over a common, well-tested core rather than carrying
its own copy.

Sanskrit/Hindi system-library naming lane (per AGNOS naming conventions);
the tools that consume it sit in the English-wordplay lane.

## Status

**v0.3.2.** taar opened at the extraction trigger — `yo` (ping/ICMP) and
`dig` (DNS) shipped with a byte-identical `ipv4.cyr`, and that duplication is
the signal to extract — then grows per-protocol as each consumer folds in.
`whirl` (HTTP/S) drove the `socket` and `dns` folds and runs on taar today;
`dig` and `yo` dedup onto it next.

| Module | Surface | Status |
|--------|---------|--------|
| `ipv4` | `ipv4_parse` (strict dotted-quad → packed u32), `ipv4_format_to_buf` | **shipped** |
| `socket` | raw-syscall UDP + TCP primitives (`taar_udp_*` / `taar_tcp_*`), Linux + AGNOS backends | **shipped** |
| `dns` | `taar_resolve_ipv4` — resolver discovery + RFC 1035 A-record query/parse over UDP-53 | **shipped** |
| `icmp` | echo packet build + checksum | planned |
| `tcp`/`tls`/`http` | HTTPS transport growth | planned |

Both socket-bearing modules carry a Linux and an AGNOS backend behind
`#ifdef CYRIUS_TARGET_AGNOS`; the `taar_*` API is identical across targets,
so consumers never branch. The bundle ships both — the branch resolves at the
**consumer's** compile target.

Address packing mirrors `agnos/kernel/core/net.cyr` `ip4()`
(`(a<<24)|(b<<16)|(c<<8)|d`), so a parsed address is byte-comparable with
kernel struct fields and ready as the packed-addr argument to the AGNOS
`sock_connect` / `udp_send` syscalls.

## Consuming taar

Add a dep block to your `cyrius.cyml` (local path during development;
git+tag once published):

```toml
[deps.taar]
git = "https://github.com/MacCracken/taar.git"
path = "../taar"
tag = "0.3.2"
modules = ["dist/taar.cyr"]
```

Then `include "lib/taar.cyr"` after `cyrius deps`. The dist bundle leaves
stdlib symbols (`fmt_int_buf`, `store8`, …) unresolved by design — they're
supplied by the consumer's own `[deps] stdlib` list. The four leaves the
bundle needs in scope are `syscalls`, `fmt`, `assert`, `alloc`; `cyrius
distlib` also emits `dist/taar.deps` listing them for `cyrius deps` to pick
up.

## Build & test

Requires the cyrius toolchain pinned in `cyrius.cyml` (`6.5.35`); run
`cyrius deps` first to vendor the stdlib into `lib/`.

```sh
cyrius build programs/smoke.cyr build/taar-smoke   # compiles + round-trips an address
cyrius tests tests/                                 # tests/taar.tcyr — 40 assertions
cyrius build programs/resolve-smoke.cyr build/taar-resolve   # live DNS check
cyrius distlib                                      # regenerate dist/taar.cyr + .deps
cyrius audit                                        # fmt + lint + docs + tests sweep
```

## License

GPL-3.0-only.
