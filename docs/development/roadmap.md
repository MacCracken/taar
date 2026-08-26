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

- **`ipv4_parse` leading-zero policy** — a decision, not a defect.
  `010.1.1.1` parses as decimal 10.1.1.1 where `inet_aton(3)` reads octal and
  says 8.1.1.1. Harmless while callers consume the packed return value, but a
  caller that validates a *string* here and re-parses it with libc gets a
  different address. Current behaviour is pinned by test so any change is
  deliberate. See [`state.md`](state.md) carry-forward.

## Consumer migration

Only what remains. `whirl` is fully migrated; `dig` and `yo` are on
`[deps.taar]` and have both dropped their in-tree `ipv4.cyr`.

- **All three pin `taar 0.3.1`** and so lack the 0.3.3 security fixes (the
  aarch64 `sendto` defect, the DNS reply-acceptance hardening) and everything
  since. Bumping those pins is the highest-value open item across the family.
- `dig` still carries its own `dns.cyr` + `resolv.cyr` to dedup onto
  `taar.dns` / `taar.socket`. Verify host + `--agnos` after.
- `yo` still carries `icmp.cyr` — the `icmp` fold above is the open piece.

Consumer repos are updated separately; none of the above is taar-side work.

## v1.0 criteria (not yet scheduled)

- Every planned consumer (`yo`, `dig`, `whirl`, + traceroute if it lands) on
  taar with no in-tree duplication.
- Every module's AGNOS backend **executed**, not merely compiled — see the
  first item under Next.
- Frozen public surface + an ADR for the module/backend contract.
