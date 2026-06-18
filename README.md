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

**v0.1.0** — opened at the extraction trigger: `yo` (ping/ICMP) and `dig`
(DNS) shipped with a byte-identical `ipv4.cyr`, and that duplication is the
signal to extract. taar starts with the module both already share and grows
per-protocol as each consumer folds in.

| Module | Surface | Status |
|--------|---------|--------|
| `ipv4` | `ipv4_parse` (strict dotted-quad → packed u32), `ipv4_format_to_buf` | **shipped** |
| `socket` | UDP/ICMP send-recv shim (Linux + AGNOS backends) | planned |
| `icmp` | echo packet build + checksum | planned |
| `dns` | query build / response parse / name-compression decode | planned |

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
tag = "0.1.0"
modules = ["dist/taar.cyr"]
```

Then `include "lib/taar.cyr"` after `cyrius deps`. The dist bundle leaves
stdlib symbols (`fmt_int_buf`, `store8`, …) unresolved by design — they're
supplied by the consumer's own `[deps] stdlib` list (carry `fmt`).

## Build & test

```sh
cyrius build programs/smoke.cyr build/taar-smoke   # compiles + round-trips an address
cyrius test                                         # tests/taar.tcyr
cyrius distlib                                       # regenerate dist/taar.cyr
```

## License

GPL-3.0-only.
