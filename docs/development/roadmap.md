# taar — Roadmap

> **Forward-looking only.** What has already shipped is recorded once, in
> [`CHANGELOG.md`](../../CHANGELOG.md) — it is not duplicated here, because two
> copies of a release history drift. Current state (version, module surface,
> what is verified) lives in [`state.md`](state.md).

## Growth rule

taar grows **per second-consumer trigger**, not up-front. A module folds in
when a real consumer's duplication forces it — the founding case being `ipv4`,
which `yo` and `dig` shipped byte-identical. Nothing below is built until its
trigger actually fires; a plausible future need is not a trigger.

## Next

Ordered by value, not by sequence — none of these blocks another.

- **Executed coverage for the AGNOS backend.** The largest untested surface in
  the repo. `src/socket.cyr`'s `#ifdef CYRIUS_TARGET_AGNOS` arm is compiled and
  confirmed to emit a different image from the Linux build, but nothing ever
  runs it — every behavioural guarantee on that target rests on review alone.
  The open design question is the harness: a QEMU-booted agnos image in CI, or
  something smaller in-repo.

- **`icmp` module** — echo packet construction + checksum, lifted from `yo`'s
  `icmp.cyr`; the AGNOS side is `icmp_echo`#55.
  **Trigger has not fired.** `yo` is already on `[deps.taar]`, but it remains
  the only consumer with ICMP, so nothing is duplicated yet. This waits for a
  second ICMP consumer — traceroute is the likely one.

- **`tls` / `http` submodules** — HTTPS today stops at the TCP layer taar
  provides; `whirl` carries the rest.
  **Trigger has not fired.** Waits for a second consumer needing them.

- **File the stdlib clock/sleep/sendto gap upstream against cyrius.** taar works
  around it, and `dig` 0.3.7 hit the same wall and worked around it differently.
  At 6.5.35 the stdlib exposes **no wrapper and no named constant** for
  `sendto`, `nanosleep` or `clock_gettime` on either Linux arch, so every
  consumer needing a monotonic clock or a sleep must hardcode a number — the
  exact thing that made `dig`'s aarch64 builds call `unlinkat` for its retry
  backoff. Worse, `lib/chrono.cyr` has the same latent bug it would fix: its
  non-macOS non-Windows arm is a bare `syscall(228, CLOCK_MONOTONIC, &ts)` with
  **no aarch64 arm**, and 228 is not `clock_gettime` on aarch64 (113 is) — it is
  not in cyrius's own aarch64 table at all. Two first-party consumers hitting
  one gap independently is the filing threshold. Per the operating rule the
  cyrius tree is not modified from a consumer repo, so this is a filing, not a
  patch.

- **`ipv4_parse` leading-zero policy** — a decision, not a defect.
  `010.1.1.1` parses as decimal 10.1.1.1 where `inet_aton(3)` reads octal and
  says 8.1.1.1. Harmless while callers consume the packed return value, but a
  caller that validates a *string* here and re-parses it with libc gets a
  different address. Current behaviour is pinned by test so any change is
  deliberate. See [`state.md`](state.md) carry-forward.

## Consumer migration

Only what remains. `whirl` is fully migrated; `dig` and `yo` are on
`[deps.taar]` and have both dropped their in-tree `ipv4.cyr`.

- ~~**All three pin `taar 0.3.1`**~~ — **closed 2026-08-28.** `yo` 0.6.0,
  `whirl` 0.6.13 and `dig` 0.3.6 (carried into 0.3.7) all pin **0.5.0** now.
- **`dig` re-implemented taar's UDP socket semantics by hand at 0.3.7 — the
  `socket` fold trigger has fired.** This is the growth rule's own signal and it
  deserves to be recorded plainly rather than left as a preference. dig's audit
  independently reached both of the conclusions `taar_udp_send` is built on, and
  then wrote its own copy in `src/platform_linux.cyr`:
    - connect-then-write instead of `sendto`, so the kernel drops off-peer
      datagrams (RFC 5452) — the same reasoning, in the same order, as taar's
      comment;
    - avoiding `sendto` because the stdlib names no wrapper and no constant, and
      hardcoding 44 is the aarch64 misroute (`fstatfs` there) — the identical
      defect taar fixed at 0.3.3, rediscovered from scratch because the pin was
      stale at the time.
  So `taar.socket` and `dig`'s `platform_linux.cyr` now hold two hand-written
  copies of one contract. That is exactly the duplication the trigger exists to
  catch.

  **But note which direction the fold now runs.** The original plan had dig
  *donating* `dns.cyr` / `resolv.cyr` / its socket surface to taar, the way it
  donated `ipv4.cyr`. taar already wrote its own `socket` and `dns` on whirl's
  pull, so there is nothing left to donate — dig would be **migrating onto**
  taar's independent implementations. Different code, different contracts, and
  a behavioural review rather than a refactor. That makes it a decision for the
  consumer to take deliberately, not a mechanical dedup, and dig has it parked
  at its own 0.4.x (when `+tcp` lands and taar 0.4.0's TC-fallback path becomes
  the obvious alternative to writing dig's own).
- `yo` still carries `icmp.cyr` — the `icmp` fold above is the open piece.

Consumer repos are updated separately; none of the above is taar-side work.

## v1.0 criteria (not yet scheduled)

- Every planned consumer (`yo`, `dig`, `whirl`, + traceroute if it lands) on
  taar with no in-tree duplication.
- Every module's AGNOS backend **executed**, not merely compiled — see the
  first item under Next.
- Frozen public surface + an ADR for the module/backend contract.
