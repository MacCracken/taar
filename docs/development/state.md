# taar — Current State

> **Snapshot, refreshed every release.** Only what is true *now* — release
> history belongs in [`CHANGELOG.md`](../../CHANGELOG.md), forward work in
> [`roadmap.md`](roadmap.md), durable process in
> [`CLAUDE.md`](../../CLAUDE.md). If a fact here is also stated in one of
> those, this file is the one that goes stale; prefer deleting it.

## Version

**0.6.1** — 2026-11-08.

`dist/taar.cyr` is 984 lines (`wc -l`; `cyrius distlib` reports 967, excluding
its 17-line generated header and `# Requires` block — the two numbers are the
same bundle).

## Toolchain

- **Cyrius pin**: `6.7.18` (`cyrius.cyml [package].cyrius`) — the single source
  of truth. Both CI workflows read it to install the toolchain; no version is
  hardcoded in YAML.
- **`lib/`** is a `cyrius deps` build artifact (gitignored), not source. At this
  pin it resolves to 19 files, every one byte-identical to the 6.7.18 bundled
  stdlib snapshot.
- **Dependency surface.** `[deps] stdlib` is `syscalls`, `fmt`, `assert`,
  `alloc` — taar's *build* list. What a consumer needs is what `distlib`'s
  compile-verify derives: **`syscalls` and `fmt`**, written to both
  `dist/taar.deps` and the bundle's `# Requires` block. `assert` and `alloc`
  are test-suite only and do not reach the sidecar.
- Known benign `distlib` warning: `sys_openat (x86_64-windows)` still undefined
  after the sidecar verify. taar's non-AGNOS `socket` arm is Linux-only
  (`sys_openat` lives in `lib/syscalls_linux_common.cyr`), and Windows is not a
  taar target. The verify compiles six targets and reports the gap; it does not
  fail the run.

## Modules

`[lib].modules` order (single-pass — a module may only reference earlier ones):
`ipv4` → `socket` → `dns`.

| Module | Surface | Since |
|--------|---------|-------|
| `ipv4` | `ipv4_parse`, `ipv4_format_to_buf` | 0.1.0 |
| `socket` | `taar_udp_open/send/recv/set_timeout_ms/close`, `taar_tcp_open/connect/send/recv/set_timeout_ms`, `taar_sock_close`, `taar_fill_sockaddr` | 0.2.0 (Linux); AGNOS backend 0.3.0; arch-dispatched syscalls 0.3.3; recv-timeout parity 0.5.0 |
| `dns` | `taar_resolve_ipv4` — resolver discovery, RFC 1035 A-record query/parse over UDP-53, TCP-53 retry on TC | 0.2.0; AGNOS kernel-leased resolver 0.3.1; reply-acceptance hardening 0.3.3; TCP fallback 0.4.0 |

Planned modules and their triggers live in [`roadmap.md`](roadmap.md).

**`src/socket.cyr` is the only module with per-target arms** — one
`#ifdef CYRIUS_TARGET_AGNOS` split, resolved at the *consumer's* compile
target. `ipv4` is a pure codec with no syscalls; `dns` is platform-neutral
RFC-1035 framing that reaches the kernel only through `socket`'s helpers. The
`taar_*` surface is identical on both targets, so consumers never branch.

## Consumers

| Consumer | Role | Adoption | Pinned at |
|----------|------|----------|-----------|
| `whirl` | curl/wget (HTTP/S) | fully migrated — HTTP transport on `taar_tcp_*` + `taar_resolve_ipv4` | 0.5.0 |
| `dig` | DNS resolver | on `[deps.taar]`, in-tree `ipv4.cyr` dropped; own `dns.cyr` + `resolv.cyr` still to dedup | 0.5.0 |
| `yo` | ping / ICMP | on `[deps.taar]`, in-tree `ipv4.cyr` dropped; still carries `icmp.cyr` | 0.5.0 |

All three are on cyrius `6.6.2` and already declare every leaf the sidecar
used to over-report (`assert`, `alloc`, `vec`) in their own `[deps] stdlib`, so
the two-leaf sidecar (since 0.5.2) does not change what they vendor.

The bundle uses no 6.7 language feature, so it still compiles on a consumer's
`6.6.2` toolchain: x86_64 and aarch64 build and run, and AGNOS builds. One
caveat: the two-leaf sidecar is exact at taar's own pin, not below it. `6.6.2`'s
`fmt.cyr` does not include its own `string` / `alloc` / `vec`, so on that
stdlib, `syscalls` + `fmt` alone leave `alloc`, `strlen`, `memcpy` and
`vec_get` undefined. All three consumers declare those leaves, so none is
affected.

## Verification

What is actually gated, and what is not.

**Automated (CI: `build`, `aarch64`, `integration`, `security`, `docs`)**

- `cyrius audit` — fmt, lint, docs and tests all green over `src/`,
  `programs/` and `tests/`. Lint and doc coverage are hard gates in the `build`
  job over the same three directories; `audit` alone only reports them.
- **x86_64**: smoke round-trip; unit suite **93 passed / 0 failed**.
- **aarch64** (`qemu-aarch64`, `unit` + smoke *executed*, not just built) — 93
  passed / 0 failed. This leg exists because the 0.3.3 `sendto` defect built
  clean and only failed at runtime.
- **Integration** (`tests/integration/tc_fallback.sh`): five TC cases — TC=0
  uses UDP, TC=1 retries TCP, TC=1 with no TCP listener falls back, and a TCP
  peer lying about its framed length (too long, too short) is refused. The job
  probes `unshare -rn` and warns-and-skips where user namespaces are forbidden.
- `cyrius distlib --check` — committed bundle current.

**Manual / local only**

- `programs/resolve-smoke.cyr` (UDP) and `programs/tcp-resolve-smoke.cyr` (TCP)
  need a live resolver, so they are not CI jobs.
- **AGNOS is build-only.** `CYRIUS_TARGET_AGNOS=1 cyrius build --agnos` succeeds
  and the image is confirmed to differ from the Linux build, which proves the
  `#ifdef` arm is *selected* — not that it works. Nothing executes it.

**Guard coverage is mutation-verified.** Removing any single bounds check in
`dns.cyr` turns the suite red, with two documented exceptions, both commented
in-source: the `ptr >= msg_len` check in `_taar_dns_skip_name` (provably
redundant given the backward-pointer rule) and the `len < _TAAR_DNS_HEADER_LEN`
check in `_taar_dns_reply_ok` (the question-echo check rejects the same inputs;
it is kept because it is what makes the header reads above it in-bounds).

## Carry-forward

- **The AGNOS backend has no executed coverage.** With lint, docs, aarch64 and
  the TC path all gated, this is the largest untested surface in the repo.
- **`ipv4_parse` accepts leading zeros as decimal** — a pending decision, not a
  defect; behaviour is pinned by test. Detail in [`roadmap.md`](roadmap.md).
- **Check the consumer before parking an item as "breaking".** The AGNOS
  `taar_tcp_recv` fix sat parked for two releases on the belief it would break
  `whirl`. It did not — whirl's loop and cyrius's `tls_native` transport
  contract both treat `<= 0` uniformly, which reading the call sites would have
  shown. Verify the claim before it becomes a blocker.
