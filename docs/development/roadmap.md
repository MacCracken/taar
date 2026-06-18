# taar — Roadmap

> Milestone sequence. Volatile current-state lives in
> [`state.md`](state.md).

## Shipped

- **0.1.0** — extraction cut: `ipv4` codec module (`ipv4_parse` +
  `ipv4_format_to_buf`), distlib + smoke + 17-assertion test suite, repo
  scaffold.

## Next (per second-consumer / duplication trigger)

- **`socket` module** — the UDP/ICMP send/recv shim yo + dig duplicate in
  `platform_linux.cyr` / `platform_agnos.cyr`. Linux backend (raw sockets) +
  AGNOS backend (`udp_bind`/`send`/`recv`/`unbind` #51-54, `icmp_echo` #55)
  behind `#ifdef CYRIUS_TARGET_AGNOS`. This is the next honest fold — both
  consumers already carry near-identical platform shims.
- **`icmp` module** — echo packet construction + checksum (from yo).
- **`dns` module** — query build / response parse / name-compression decode
  (the shared core of yo's and dig's `dns.cyr`; the two diverge at the
  presentation layer, so extract the codec core, leave per-tool formatting).

## Consumer migration

- dig → `[deps.taar]`, drop in-tree `ipv4.cyr` (patch cut), verify host + `--agnos`.
- yo → same.
- `whirl` (curl/wget) arrives as the third consumer; adds `tcp` / `tls` /
  `http` submodules onto the already-modular taar.

## v1.0 criteria (not yet scheduled)

- All four planned consumers (yo, dig, whirl, + traceroute if it lands) on
  taar with no in-tree duplication.
- Every module carries a working AGNOS backend, validated on the kernel.
- Frozen public surface + ADR for the module/backend contract.
