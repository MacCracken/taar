# taar — Claude Code Instructions

> **Core rule**: this file is **preferences, process, and procedures** —
> durable rules that change rarely. Volatile state (current version, module
> list, consumers, test counts) lives in
> [`docs/development/state.md`](docs/development/state.md). Do not inline
> state here.

## Identity

**taar** (तार — *wire / string / connection*) is the network-probe substrate
library for AGNOS first-party network tools. It exists so `yo` / `dig` /
`whirl` share one tested core instead of each carrying its own copy of
address codecs, socket I/O, packet construction, and DNS.

- **License**: GPL-3.0-only
- **Language**: Cyrius
- **Naming lane**: Sanskrit/Hindi (system-lib lane); consumers are
  English-wordplay-lane tools.

## Architecture

- **Modular by protocol.** Each concern is its own `src/*.cyr` module listed
  in `[lib].modules`; `cyrius distlib` concatenates them (in order) into
  `dist/taar.cyr`. Single-pass compiler — a module may only reference symbols
  from earlier modules. Order matters.
- **Grow per second-consumer trigger**, not up-front. A module folds in when a
  real consumer's duplication forces it (the `ipv4` extraction is the founding
  instance: yo + dig shipped it byte-identical). Don't pre-build speculative
  modules.
- **`src/main.cyr`** re-exports all modules for `programs/smoke.cyr` +
  `tests/taar.tcyr`; it is NOT in `[lib].modules` (would duplicate bodies).
- **Stdlib is the consumer's job.** The dist bundle leaves stdlib symbols
  unresolved by design; consumers supply them via their own `[deps] stdlib`.

## Conventions

- Address packing mirrors `agnos/kernel/core/net.cyr` `ip4()` —
  `(a<<24)|(b<<16)|(c<<8)|d` — so addresses are byte-comparable with kernel
  struct fields and feed the AGNOS `sock_connect` / `udp_send` syscalls directly.
- Socket modules carry Linux + AGNOS backends behind `#ifdef
  CYRIUS_TARGET_AGNOS` (the same per-backend pattern as the consumer tools'
  `platform_*.cyr`). Pure codecs (ipv4) have no syscalls and are backend-free.
- `streq` for cstring/raw-buffer compare (NOT `str_eq`, which is for the `Str`
  type).

## Work loop

1. Pick the next module/fix.
2. `cyrius build programs/smoke.cyr build/taar-smoke` + `cyrius test` green.
3. `cyrius distlib` to regenerate `dist/taar.cyr`.
4. Update `CHANGELOG.md` + `docs/development/state.md`.

## DO NOT

- **Do not commit or push** — the user handles all git operations.
- **NEVER use `gh` CLI** — `curl` to the GitHub API only.
- Do not add stdlib deps the consumers don't already carry.
