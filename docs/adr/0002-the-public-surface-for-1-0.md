# 0002 — The public surface for 1.0: one prefix, matching names, named errors

**Status**: Accepted
**Date**: 2026-11-09
**Amends**: [0001](0001-one-socket-and-resolver-contract.md) — its per-call table and rules use the names below.

## Context

1.0 freezes taar's surface. Three consumers pin the bundle by tag, so anything
named at 1.0 is named for every 1.x release. The 0.9.x review read ADR 0001's
per-call table and the consumers' call sites:
- **yo** calls `ipv4_parse` 34 times and `IPV4_PARSE_FAIL` once.
- **dig** calls the `ipv4_*` codec 26 times and `IPV4_PARSE_FAIL` 6 times. Since
  its 1.x, dig also sends DNS-over-TCP through `taar_tcp_*` and
  `taar_sock_close`.
- **whirl** calls `taar_tcp_*`, `taar_sock_close` (9 calls) and
  `taar_resolve_ipv4`.

No consumer calls anything with a leading underscore. The `_taar_*` names in
whirl's and dig's sources occur only in comments.

The review found four inconsistencies.

1. **The two error constants a caller must test were spelled as internal.**
   ADR 0001 lets a caller branch on `_TAAR_ERR_TIMEOUT` and `_TAAR_ERR_INTR` and
   on nothing else. A leading underscore is taar's mark for internal, though,
   so dig re-declared -11 as its own `PLATFORM_ERR_TIMEOUT` instead of naming
   taar's.
2. **A timed-out Linux connect returned an errno the contract says not to test.**
   `connect(2)` reports a `SO_SNDTIMEO` expiry as -EINPROGRESS (-115), and taar
   passed that through. dig re-declares -115 as `TCP_EINPROGRESS` to tell a
   connect timeout from a refusal.
3. **One family has no prefix.** The IPv4 codec kept the names yo and dig
   shipped before the extraction: `ipv4_parse`, `ipv4_format_to_buf` and
   `IPV4_PARSE_FAIL`. Every other public name carries `taar_`. cyrius has one
   global namespace, so an unprefixed name is one a consumer, or another
   library it includes, can collide with.
4. **TCP's close does not match UDP's.** The calls are `taar_udp_close` and
   `taar_sock_close`. The second is a leftover from before the AGNOS split gave
   UDP and TCP different kernel objects. Separately, `taar_fill_sockaddr` is
   public but no consumer calls it: it builds the Linux `sockaddr_in` that only
   taar's own Linux arm needs.

## Decision

**Every public name carries `taar_` (functions) or `TAAR_` (constants). Names
that change keep working as `#deprecated` aliases until 1.0.0, which removes
them.** In 0.9.1:

| Was | Is | Kind |
|---|---|---|
| `_TAAR_ERR_TIMEOUT` | `TAAR_ERR_TIMEOUT` | constant, -11 |
| `_TAAR_ERR_INTR` | `TAAR_ERR_INTR` | constant, -4 |
| `ipv4_parse` | `taar_ipv4_parse` | function |
| `ipv4_format_to_buf` | `taar_ipv4_format_to_buf` | function |
| `IPV4_PARSE_FAIL` | `TAAR_IPV4_PARSE_FAIL` | constant, -1 |
| `taar_sock_close` | `taar_tcp_close` | function |
| `taar_fill_sockaddr` | — (internal: `_taar_fill_sockaddr`) | function |

**A Linux connect that misses its deadline returns `TAAR_ERR_TIMEOUT`**, mapped
from -EINPROGRESS, so "timed out" is one value on every receive, send and
connect. AGNOS still answers -1: its kernel does not say why a connect failed,
and its connect is not bound by the caller's timeout (ADR 0001's open
difference).

**Mechanics.**
- **Deprecated functions** carry `#deprecated("…")`. cyrius warns at each call
  site on every backend; `cyrius lint` does not, so a consumer's lint gate
  stays green while its build names each call to change.
- **Deprecated constants** are plain duplicates with the same value. cyrius
  has no deprecation marker for a `var`, so they are deprecated in their doc
  comment only.
- **Internal names stay internal.** Tests and the AGNOS harness reach into
  `_taar_*` names (`_taar_ag_*`, `_taar_resolv_*`, `_taar_dns_*`). That is a
  test's prerogative, not a reason to make them public.

## Consequences

- **Positive.**
  - The contract's error values have public names, so a consumer can stop
    mirroring Linux errnos.
  - dig's -115 check goes dead: its connect timeout now arrives as -11, the
    value it already treats as a timeout.
  - The surface frozen at 1.0 is one prefix, with matching close calls and no
    helper nobody uses.
- **Negative.**
  - The renames mean about 60 call-site changes in yo and dig, and 9 in whirl.
    They are forced at 1.0.0, when the aliases go; until then each is a warning.
  - The deprecated constants cannot warn, so a consumer still using one finds
    out only when 1.0.0 removes it.
- **Neutral.**
  - The roadmap's consumer-migration list carries the rename table.
  - 1.0.0 deletes the deprecated block at the end of `src/ipv4.cyr` and
    `src/socket.cyr`, plus the deprecated constants and the alias test group.

## Alternatives considered

- **Keep the unprefixed `ipv4_*` names as a documented exception.** They
  predate taar, and keeping them would cost no churn. Rejected by the
  maintainer for one prefix across the surface: the namespace is global, and
  1.0 is the last cheap moment to make it consistent.
- **Keep the aliases through 1.x, removing them at 2.0.** That forces no churn
  at 1.0, but the frozen surface would carry both spellings for its whole
  life. 1.0 is the major bump consumers expect to adapt to.
- **Leave connect's timeout as -EINPROGRESS and document it.** Rejected: it is
  the one deadline that would not read as `TAAR_ERR_TIMEOUT`, and dig's
  re-declared errno shows callers do need to tell it apart.
- **Make the internal names tests use public.** Rejected: tests are not
  consumers, and every public name is one more thing 1.0 freezes.
