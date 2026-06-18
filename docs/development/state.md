# taar — Current State

> Refreshed every release. CLAUDE.md is preferences/process (durable); this
> file is **state** (volatile).

## Version

**0.1.0** — 2026-06-14. Extraction cut. `src/ipv4.cyr` (the byte-identical
codec yo + dig both shipped) lifted into taar as the founding module. Smoke
green; `tests/taar.tcyr` 17 assertions / 0 failed. `dist/taar.cyr` generated
(70 lines).

## Toolchain

- **Cyrius pin**: `6.2.6` (`cyrius.cyml [package].cyrius`).

## Modules

| Module | Surface | Status |
|--------|---------|--------|
| `ipv4` | `ipv4_parse`, `ipv4_format_to_buf` | shipped 0.1.0 |
| `socket` | UDP/ICMP send/recv shim (Linux + AGNOS) | planned |
| `icmp` | echo packet + checksum | planned |
| `dns` | query build / response parse / name compression | planned |

## Consumers

| Consumer | Role | taar adoption |
|----------|------|---------------|
| `dig` | DNS resolver | folds `ipv4` (pending patch cut) |
| `yo` | ping / ICMP | folds `ipv4` (pending patch cut) |
| `whirl` | curl/wget (HTTP/S) | future third consumer — adds tcp/tls/http |

## Carry-forward

- Migrate dig + yo off their in-tree `src/ipv4.cyr` onto `[deps.taar]`;
  verify each still builds host + `--agnos` (their `platform_agnos.cyr`
  backends are unaffected — ipv4 is pure code).
- `socket`/`icmp`/`dns` folds follow as the duplication between consumers
  forces them.
