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
- **`src/main.cyr`** re-exports all modules so every `programs/*.cyr` and
  `tests/taar.tcyr` can pull the whole surface with one include; it is NOT in
  `[lib].modules` (would duplicate bodies in the bundle).
- **Stdlib is the consumer's job.** The dist bundle leaves stdlib symbols
  unresolved by design; consumers supply them via their own `[deps] stdlib`.

## Conventions

- Address packing mirrors `agnos/kernel/core/net.cyr` `ip4()` —
  `(a<<24)|(b<<16)|(c<<8)|d` — so addresses are byte-comparable with kernel
  struct fields and feed the AGNOS `sock_connect` / `udp_send` syscalls directly.
- **`src/socket.cyr` is the only module with per-target arms** — one `#ifdef
  CYRIUS_TARGET_AGNOS` split (the same per-backend pattern as the consumer
  tools' `platform_*.cyr`). Pure codecs (`ipv4`) have no syscalls; protocol
  framing (`dns`) stays platform-neutral and reaches the kernel only through
  `socket`'s helpers. Keep it that way — a new `#ifdef` in a framing module is
  a smell.
- **Never write a syscall number as a literal.** Go through the stdlib's
  arch-dispatched `sys_*` wrappers. cyrius's aarch64 backend remaps the x86_64
  numbers it recognises, so a hardcoded literal *looks* portable — but the
  numbers it deliberately cannot remap (those colliding with a different native
  aarch64 call, e.g. `sendto` 44 vs `fstatfs`) fail silently at runtime from a
  perfectly clean build. Where no wrapper exists, restructure to a call that has
  one rather than hardcoding.
- **A receive deadline expiry is `_TAAR_ERR_TIMEOUT`, never `0`.** `0` means
  the peer closed, and nothing else, on every backend. Collapsing the two is
  what let a stalled peer look like a finished response.
- **Every public fn carries a doc comment** — `cyrius doc --check` is a CI gate
  over `src/` and `programs/`.
- `streq` for cstring/raw-buffer compare (NOT `str_eq`, which is for the `Str`
  type).

## Work loop

1. Pick the next item from [`docs/development/roadmap.md`](docs/development/roadmap.md).
   Respect the growth rule above — if a module's trigger has not fired, it is
   not next.
2. `cyrius audit` green (fmt + lint + docs + tests).
3. `cyrius tests --aarch64 tests/` green. Not optional: the 0.3.3 `sendto`
   defect built clean on aarch64 and only failed when executed.
4. `CYRIUS_TARGET_AGNOS=1 cyrius build --agnos src/main.cyr` compiles.
5. Touched the DNS path? `tests/integration/tc_fallback.sh`.
6. `cyrius distlib` to regenerate `dist/taar.cyr` (+ `dist/taar.deps`).
7. Update `CHANGELOG.md` and `docs/development/state.md`; prune anything the
   change made stale.

New guards get a test, and the test gets **mutation-checked** — remove the
guard, confirm the suite goes red. A guard whose removal changes nothing is
either redundant (say so in a comment) or untested.

## Documentation split

Four files, one job each. When a fact belongs in two, keep it in the more
durable one and delete the copy.

- `CLAUDE.md` — durable conventions + process. Changes rarely. **No volatile
  state** (versions, counts, module lists).
- `CHANGELOG.md` — the *only* record of release history. Do not mirror it.
- `docs/development/state.md` — a snapshot of what is true now.
- `docs/development/roadmap.md` — forward-looking only; each planned item names
  the trigger it waits on.

## DO NOT

- **Do not commit or push** — the user handles all git operations.
- **NEVER use `gh` CLI** — `curl` to the GitHub API only.
- Do not add stdlib deps the consumers don't already carry.
