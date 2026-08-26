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

**v0.5.0.** taar opened at the extraction trigger — `yo` (ping/ICMP) and
`dig` (DNS) shipped with a byte-identical `ipv4.cyr`, and that duplication is
the signal to extract — then grows per-protocol as each consumer folds in.
All three consumers are on `[deps.taar]` today; `whirl` (HTTP/S) drove the
`socket` and `dns` folds.

| Module | Surface | Status |
|--------|---------|--------|
| `ipv4` | `ipv4_parse` (strict dotted-quad → packed u32), `ipv4_format_to_buf` | **shipped** |
| `socket` | raw-syscall UDP **and TCP** primitives (`taar_udp_*` / `taar_tcp_*`), Linux + AGNOS backends | **shipped** |
| `dns` | `taar_resolve_ipv4` — resolver discovery + RFC 1035 A-record query/parse over UDP-53, retried over TCP-53 when a reply is truncated | **shipped** |
| `icmp` | echo packet build + checksum | planned |
| `tls` / `http` | HTTPS above taar's TCP layer | planned |

Planned modules are built only when a second consumer's duplication forces
them — see [the roadmap](docs/development/roadmap.md) for each trigger.

`src/socket.cyr` is the only module with per-target arms: one
`#ifdef CYRIUS_TARGET_AGNOS` split covering Linux and AGNOS. `ipv4` is a pure
codec with no syscalls, and `dns` is platform-neutral RFC-1035 framing that
reaches the kernel only through `socket`. The `taar_*` surface is identical on
both targets, so consumers never branch — the bundle ships both arms and the
branch resolves at the **consumer's** compile target.

Address packing mirrors `agnos/kernel/core/net.cyr` `ip4()`
(`(a<<24)|(b<<16)|(c<<8)|d`), so a parsed address is byte-comparable with
kernel struct fields and ready as the packed-addr argument to the AGNOS
`sock_connect` / `udp_send` syscalls.

### Targets

| Target | Built | Tests executed |
|--------|-------|----------------|
| Linux x86_64 | CI | yes — unit + integration |
| Linux aarch64 | CI | yes — unit + smoke, under `qemu-user` |
| AGNOS | CI | **no** — compiled only; see the roadmap |

## Consuming taar

Add a dep block to your `cyrius.cyml` (local path during development;
git+tag once published):

```toml
[deps.taar]
git = "https://github.com/MacCracken/taar.git"
path = "../taar"
tag = "0.5.0"
modules = ["dist/taar.cyr"]
```

Then `include "lib/taar.cyr"` after `cyrius deps`.

The dist bundle leaves stdlib symbols (`fmt_int_buf`, `store8`, the `sys_*`
wrappers, …) unresolved by design — they come from the consumer's own
`[deps] stdlib`. The bundle needs exactly two leaves in scope: **`syscalls`
and `fmt`**. `cyrius distlib` also emits `dist/taar.deps`, but that file
echoes taar's full `[deps] stdlib` (which additionally carries `assert` and
`alloc` for taar's own test suite), so it over-declares — harmless, but it is
not the bundle's real requirement.

## Build & test

Requires the cyrius toolchain pinned in `cyrius.cyml` (`6.5.35`); run
`cyrius deps` first to vendor the stdlib into `lib/`.

```sh
cyrius audit                                        # fmt + lint + docs + tests
cyrius tests tests/                                 # tests/taar.tcyr — 93 assertions
cyrius tests --aarch64 tests/                       # same suite on aarch64 (needs qemu-user)
cyrius build programs/smoke.cyr build/taar-smoke    # compiles + round-trips an address
cyrius distlib                                      # regenerate dist/taar.cyr + .deps
```

Live checks need a real resolver, so they are not CI jobs:

```sh
cyrius build programs/resolve-smoke.cyr build/taar-resolve            # DNS over UDP
cyrius build programs/tcp-resolve-smoke.cyr build/taar-tcp-resolve    # DNS over TCP
```

The DNS truncation path can't be unit-tested — no live resolver truncates on
demand — so `tests/integration/` stands up a fake resolver that answers
differently over UDP and TCP, inside `unshare -rn` so it can hold port 53
without root. This runs in CI:

```sh
tests/integration/tc_fallback.sh
```

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md) — release history (the only record of it).
- [`docs/development/state.md`](docs/development/state.md) — current snapshot:
  module surface, consumer adoption, what is and isn't verified.
- [`docs/development/roadmap.md`](docs/development/roadmap.md) — forward work
  and the trigger each planned module waits on.
- [`CLAUDE.md`](CLAUDE.md) — durable conventions and the work loop.

## License

GPL-3.0-only.
