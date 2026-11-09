# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.9.1] - 2026-11-09

The public-surface review: the names 1.0 will freeze. The decisions and their
reasoning are
[ADR 0002](docs/adr/0002-the-public-surface-for-1-0.md). ADR 0001's tables now
use the new names.

### Changed

- **Every public name carries `taar_` / `TAAR_`.** Each old name keeps working
  until **1.0.0**, which removes it:

  | Was | Is |
  |---|---|
  | `_TAAR_ERR_TIMEOUT`, `_TAAR_ERR_INTR` | `TAAR_ERR_TIMEOUT`, `TAAR_ERR_INTR` |
  | `ipv4_parse`, `ipv4_format_to_buf` | `taar_ipv4_parse`, `taar_ipv4_format_to_buf` |
  | `IPV4_PARSE_FAIL` | `TAAR_IPV4_PARSE_FAIL` |
  | `taar_sock_close` | `taar_tcp_close` (matches `taar_udp_close`) |
  | `taar_fill_sockaddr` | internal (`_taar_fill_sockaddr`): no consumer called it |

  - **The error constants were the real defect.** ADR 0001 tells callers to
    test them, but the leading underscore marked them internal, so dig
    re-declared -11 rather than naming taar's.
  - **Deprecated functions** carry `#deprecated("…")`, so cyrius warns at each
    call site. `cyrius lint` does not warn, so a consumer's lint gate stays
    green.
  - **Deprecated constants** can't warn (cyrius has no marker for a `var`), so
    they are deprecated in their doc comment only.
- **A Linux connect that misses its deadline returns `TAAR_ERR_TIMEOUT`.** It
  used to pass through `connect(2)`'s -EINPROGRESS, which made dig re-declare
  -115 to tell a timeout from a refusal. "Timed out" is now one value on every
  receive, send and connect.
  - **dig's outcome is unchanged:** -11 is the value it already treats as a
    timeout.
  - **AGNOS still answers -1:** its kernel doesn't say why a connect failed.

### Tests

- **Unit suite: 210 → 221.**
  - **`tcp-connect-timeout`:** a loopback listener whose zero-length accept
    queue is already full, and a connect to it that must end in
    `TAAR_ERR_TIMEOUT`. Removing the map gives -115, so the test fails.
  - **`deprecated-names`:** each alias answers as its new name. Its build
    prints the expected deprecation warnings.
- **Callers inside taar** (`src/`, `programs/`, `tests/`, `benches/`, the
  AGNOS selftest) use the new names, so nothing else warns.
- **The AGNOS harness passes all 87 checks** on the renamed arm.

### Documentation

- **ADR 0002** records the decisions and the alternatives rejected:
  - keeping `ipv4_*` unprefixed;
  - keeping the aliases through 1.x;
  - documenting -EINPROGRESS;
  - making the internals that tests use public.
- **ADR conventions:** an accepted ADR's Decision tables may take a later ADR's
  amendment, named on its status line.
- **`CLAUDE.md`** gains the naming rule.
- **The roadmap:**
  - 0.9.x is done;
  - 1.0.0 adds "deprecated aliases removed";
  - the consumer-migration list gains the rename table;
  - its stale note about dig is corrected. dig's DNS-over-TCP already runs on
    `taar_tcp_*`, its UDP transport is the remaining fold, and its DNS layer
    stays its own by design.

## [0.9.0] - 2026-11-09

The backend contract, written down. Writing it found a Linux defect, fixed
here too.

### Added

- **ADR 0001, the contract both backends keep**
  (`docs/adr/0001-one-socket-and-resolver-contract.md`).
  - **Shared rules:**
    - a caller may branch only on `_TAAR_ERR_TIMEOUT` and `_TAAR_ERR_INTR`;
      every other negative value is target-specific;
    - each socket has its own timeout, where 0 means no deadline and a
      negative value is refused, and the default is not part of the contract;
    - fds are opaque and belong to their own family's calls;
    - no call raises a signal;
    - taar is not thread-safe;
    - a resolve leaves the caller's sockets alone.
  - **A per-call table** of return values and notes.
  - **A table of where the targets still differ**, each row with its standing
    and what it waits on: the connect deadline, reset vs EOF, UDP queueing,
    the largest datagram, the default timeout, the resolver fallback, EINTR,
    and limits.
  - **How each clause is enforced**, plus the alternatives rejected: a POSIX
    shim on AGNOS, per-target contracts, specified errno values, and a
    specified default timeout.
- **`docs/adr/`**, with an index and the template shared with yo and dig.
  `CLAUDE.md` records ADR 0001 as the contract and the convention that a
  change to the contract changes the ADR and its test in the same release.

### Fixed

- **On Linux, a send to a peer that has gone no longer kills the process.**
  `taar_tcp_send` was `write(2)`, which raises SIGPIPE when the peer has gone,
  and SIGPIPE's default action ends the process: measured exit 141, before
  the call returned. It is now `sendto(…, MSG_NOSIGNAL)`, which returns
  -EPIPE instead.
  - **Who it hit:** whirl does not ignore SIGPIPE, so a plain-HTTP upload to a
    server that reset mid-send ended whirl silently.
  - **AGNOS** has no SIGPIPE and already returned -1.
  - **Unchanged:** SO_SNDTIMEO still bounds the call, and still reports
    `_TAAR_ERR_TIMEOUT`.

### Tests

- **Unit suite: 208 → 210.** `socket-send-timeout` checks that a send to a
  closed peer is -EPIPE, which only passes if the process survives the call,
  and that an empty send on a live connection is 0.
  - Mutation: reverting to `write(2)` kills the test binary with signal 13.
  - On Linux, an empty send on a broken connection is -EPIPE too, so the ADR
    says "0 on a live connection".

## [0.8.2] - 2026-11-09

Three behaviour decisions the roadmap had held open, settled. Each changes what
a caller sees.

### Changed

- **No resolver configured → 127.0.0.1 on Linux.** When
  `/etc/resolv.conf` is missing, unreadable (EACCES counts) or names no
  nameserver, taar now asks 127.0.0.1, as glibc and musl do. It used to send
  every hostname to Google's 8.8.8.8, a third party the host never chose.
  AGNOS, which runs no local resolver, keeps 8.8.8.8 behind its DHCP-leased
  resolver.
  - The fallback is now a per-target helper, `_taar_plat_dns_fallback`, in
    `socket.cyr`, the one module with per-target arms. `dns.cyr` loses the
    `_TAAR_RESOLV_FALLBACK` constant.
  - A file naming only resolvers taar can't use still fails closed (0.6.2).
- **The question echo compares without case.** taar requires a reply to echo
  the question it asked, and that comparison was byte for byte. So a resolver
  that echoes "Example.COM" as "example.com" made every such lookup fail.
  - The name now compares the way 0.8.1's owner check does (RFC 4343, A–Z
    only).
  - QTYPE and QCLASS still match exactly.
  - This was chosen over randomising the query's letter case (DNS 0x20). A
    stub gains little from 0x20's extra bits, on top of its 16-bit ID, random
    source port and source filter, and it fails every lookup through a
    resolver that rewrites case.
- **`ipv4_parse` refuses leading zeros.** A multi-digit octet may not start
  with 0, so `010.1.1.1` and `00.0.0.0` are refused, while `0.0.0.0` is
  still accepted.
  - **Why:** the string was ambiguous. inet_aton(3) reads `010` as octal 8,
    and taar read it as decimal 10. This matches glibc's inet_pton, Go 1.17+
    and Python 3.9.5+ (CVE-2021-29921).
  - **Consumer impact:** yo and dig parse user-typed addresses with it, and
    dig also parses its resolv.conf with it. Neither tool's tests relied on
    the old reading.
  - **Resolver impact:** `taar_resolve_ipv4("010.1.1.1")` is no longer a
    literal, so it goes to DNS as a name.

### Tests

- **Unit suite: 198 → 208.**
  - Leading zeros in any octet, with a lone `0` still accepted.
  - The Linux fallback is 127.0.0.1, for a missing file and an unreadable one.
  - The echo in another case is accepted. Only letters fold, so `{` is not
    `[`. QTYPE never folds.
- **`resolver.sh`: 18 → 20 checks.**
  - With no resolv.conf at all (an empty tmpfs over `/etc`), 127.0.0.1 is
    asked.
  - A question echoed in upper case is accepted. `fake_dns.py` gains an
    `upper_echo` mode.
- **AGNOS harness: 86 → 87 checks.** AGNOS's fallback is pinned at 8.8.8.8.
- **Mutation: 6 mutations, 5 red.**
  - The green one raised the question-length floor from 12 to 16 bytes. No
    query is that short, and neither compare loop needs it, so the floor is
    back at 12 instead of shipping as an untested guard.

## [0.8.1] - 2026-11-09

Answer validation. `taar_resolve_ipv4` now takes an address only for the name
it asked, or for the end of that name's CNAME chain. Before, it took the first
class-IN A record in the answer section, whatever name it belonged to.

### Security

- **Answer owner-name validation.** An A record counts only when its owner is
  the question's name, or the current end of the CNAME chain from it.
  - **Order:** answers are read in order, as glibc reads them. A class-IN
    CNAME from the current name moves it to the CNAME's target, so an alias's
    A counts only after the CNAME that introduces it. Once the question has
    been aliased, its own A record no longer counts (RFC 1034 §3.6.2).
  - **Case:** owners compare without case (RFC 4343), with only A–Z folded.
  - **Broken CNAMEs:** a CNAME whose target cannot be read, or runs past its
    rdlength, refuses the whole reply.

  Before this, a resolver that answered with records for other names
  (broken, hostile, or serving a polluted cache) decided where taar
  connected. glibc checks owners; musl does not.
- **The reply's OPCODE must be QUERY.** A STATUS or NOTIFY message with the
  right ID and question is no longer read as an answer.

### Added

- **`_taar_dns_name_eq`** compares two wire names in a message without regard
  to case. It follows compression pointers on both sides under
  `_taar_dns_skip_name`'s rules: backward only, in bounds, and within the hop
  budget, so a hostile message cannot loop it.
- **`_taar_dns_hdr_opcode`** reads the reply's OPCODE, and
  **`_TAAR_DNS_TYPE_CNAME`** names the CNAME record type.

### Changed

- The `dns_first_a` bench row (a CNAME then an A) went from 95 to 307 ns,
  because every record's owner is now compared. That is still nanoseconds
  against milliseconds of network.

### Tests

- **Unit suite: 168 → 198**, with a small reply builder in the tests.
  - A new `dns-owner` group covers: a pointer, literal or differently-cased
    owner; another name's A record before the real one, or alone; names that
    only share a prefix or suffix; one- and two-hop CNAME chains; a chain
    that does not start at the question; the question's own A after its
    CNAME; an out-of-order chain; a looping owner; a CNAME target that cannot
    be read or overruns its rdata.
  - A new `dns-name-eq` group covers: case folding of A–Z only; pointers;
    suffixes; looping, forward, cut and reserved-prefix names.
  - `dns-reply-ok` gains the OPCODE check.
- **`resolver.sh`: 15 → 18 checks.** End to end: another name's A is skipped,
  a reply with only another name's A is a final "no answer", and a CNAME
  chain is followed. `fake_dns.py` gains `other_first`, `other_only` and
  `cname` modes.
- **Mutation: 14 mutations, 12 red.** The two green are commented in-source:
  - the "unreadable CNAME target" refusal is redundant in effect, because the
    name comparison refuses a malformed name anyway;
  - the label-content bounds in the name comparison can't change the result,
    but keep its reads inside the message.

  The pointer-bounds check first came out green, and a test now catches it: a
  pointer cut off by the message end, whose missing byte would point back at
  a good name.
- **The AGNOS harness passes all 86 checks** with the new answer rules.

## [0.8.0] - 2026-11-09

Stub-resolver failover. `taar_resolve_ipv4` now handles a nameserver that is
down, silent or failing the way the glibc and musl stubs do: it asks the
others in resolv.conf, and honours the file's `options timeout:` and
`attempts:`.

### Added

- **Nameserver failover.** Up to three nameservers from resolv.conf are asked
  in file order, for `attempts` rounds.
  - **Final answers:** NOERROR and NXDOMAIN stop the resolve.
  - **Handed to the next server:** no matching reply, a send error, SERVFAIL,
    REFUSED, NOTIMP or FORMERR, or a truncated reply with no answer whose TCP
    retry also failed.

  Before, taar asked only the first usable nameserver, and any server failure
  ended the resolve.
- **`options timeout:N` and `attempts:N`** in resolv.conf. The defaults are
  5 s and 2, capped at 30 s and 5, which are glibc's values, and 0 is raised
  to 1. Several `options` lines combine, and a later value wins. Other options
  are ignored.
- **A fresh random query ID for every server asked**, rather than one ID per
  resolve.
- **`_TAAR_ERR_INTR`** (-4, Linux's -EINTR) next to `_TAAR_ERR_TIMEOUT` in
  `socket`.

### Fixed

- **A signal no longer ends a resolve.** With SO_RCVTIMEO set, Linux fails an
  interrupted `recvfrom`/`read` with EINTR instead of restarting it, even
  after a bare SIGSTOP/SIGCONT with no handler, and taar took that as "no
  reply". Both the UDP wait and the TCP retry's reads now retry. Each retry
  counts against their existing budgets (8 replies, 16 reads), so the wait
  stays bounded. The AGNOS arm never returns EINTR.

### Changed

- **The default pace follows libc.** A single silent nameserver used to fail
  after 5 s; with the default 2 attempts it now fails after 10 s.
  `options attempts:1` restores the old pace. A dead nameserver (ICMP
  unreachable) still fails in milliseconds and hands over at once. The TCP
  retry uses the same per-query timeout, where it used to have its own fixed
  5 s.
- **Where taar differs from glibc** (documented on `taar_resolve_ipv4` and in
  the roadmap):
  - it takes the first three *usable* IPv4 servers, where glibc takes the
    first three entries of any family;
  - the per-query timeout stays fixed across rounds, where glibc doubles it;
  - `RES_OPTIONS` in the environment is not read;
  - search domains are not applied.
- **Internals:** `_taar_resolv_parse`, `_choose` and `_discover` fill a
  48-byte config block. The `resolv_parse` bench row went from 317 to about
  600 ns, because the parser now reads the whole file for `options` instead of
  stopping at the first nameserver.

### Tests

- **Unit suite: 140 → 168**, with a new `resolv-conf` group covering three
  servers in order, a fourth ignored, unusable entries not counted, and the
  defaults, values, clamps, malformed values, CRLF and whole-word keywords of
  `options`, plus the fallback and the kernel lease.
- **New `tests/integration/resolver.sh`: 15 checks.** Each case runs in its
  own namespace with a bind-mounted resolv.conf and several fake nameservers,
  each logging the queries it receives. It covers:
  - failover from an unreachable, silent, SERVFAIL, REFUSED, unroutable or
    truncated-and-empty server;
  - NXDOMAIN being final, so the next server is never asked;
  - `attempts` rounds, the default of 2, and every round asking every server;
  - the three-server limit;
  - a fresh ID per query;
  - EINTR surviving on both the UDP and the TCP read.

  `fake_dns.py` gains `servfail`, `refused`, `nxdomain`, `silent`, `slow`,
  `tc_slow` and `tc_empty` modes, plus `--addr` and `--log`. The CI
  integration job runs the script.
- **Mutation:** 18 mutations of the new guards, all red. One is worth
  recording: with the EINTR retry removed, the client still printed the right
  address, because the second round asked again. Only the asserted query
  count (2 instead of 1) caught it.
- **AGNOS harness: 84 → 86 checks.** The kernel lease is checked as a
  single-server config with the default attempts. The full set passes with
  the new resolver loop.

### Documentation

- Filed with agnos, in its `docs/development/issues/`:
  `2026-11-09-an-epoll-instance-is-never-freed-so-short-lived-ones-run-the-heap-dry.md`.
  - **The defect:** an epoll instance's watch list is never freed. Measured
    on 1.57.19: 1,690,592 create/close pairs in 17.9 s use up the kernel
    heap, and `epoll_create` fails for good after that. Any unprivileged
    process can do it.
  - **The fix it suggests:** the pipe buffer's existing last-reference free.
  - **Also asked:** a distinct `sock_recv#49` answer for a dead connection,
    which would give taar its reset-vs-EOF bit with no epoll at all.

  The roadmap's reset item now waits on it and on cyrius's epoll peer.
- Roadmap: failover and the EINTR retry are done. Owner-name validation is
  next (0.8.1), and search domains are recorded as not handled.

## [0.7.1] - 2026-11-09

Per-socket state on AGNOS, the first 0.7.x parity item. The AGNOS arm kept
one timeout, one TCP connection and one UDP source port and peer for the
whole process. So a `taar_resolve_ipv4` call made while a consumer's sockets
were open could break them. Each disturbance below was reproduced in the
harness against 0.7.0 and is gone in 0.7.1.

### Fixed (AGNOS)

- **A resolve no longer disturbs the caller's sockets.** Measured against
  0.7.0:
  - **TCP connection:** a TC resolve's TCP retry dropped the caller's live
    connection, so its next send failed with -1, and leaked that
    connection's kernel slot;
  - **TCP timeout:** the resolver's 5 s timeout replaced the caller's, so a
    300 ms receive waited 5004 ms;
  - **UDP peer:** a UDP reply that landed while a resolve ran was dropped,
    because the source filter compared it with the resolver's peer;
  - **UDP source port:** the caller's next UDP send left from the resolver's
    freed port, so its reply never came back.

  Each socket now has its own table slot holding its timeout, connection,
  source port and recorded peer.
- **fds are validated.** The AGNOS calls used to ignore `fd` entirely. Every
  call now checks it against the table, and returns -1 for an fd that taar
  did not hand out, has closed, or that is out of range. taar no longer sends
  from, or unbinds, a listener bound outside it.
- **Connecting a connected socket is refused** with -1 (Linux:
  -EISCONN). Before, the second connect orphaned the first connection's
  kernel slot.
- **An empty `taar_tcp_recv` returns 0 at once**, as read(2) does. The
  kernel answers 0 ("nothing yet") to a zero-length `sock_recv#49`, so the
  poll loop waited out the whole deadline (3013 ms measured with a 3 s
  deadline), or forever with none. No consumer passes 0 today; this is the
  receive twin of 0.7.0's empty-send guard. Found by reading the kernel's
  `sock_recv` alongside this change.

### Changed (AGNOS, visible to callers)

- **TCP fds:** `taar_tcp_open` returns a distinct fd per socket, 64..71,
  where it used to return 0 for every socket. It returns -1 when all eight
  are open, the size of the kernel's connection table. whirl only passes the
  fd back to taar, including through its TLS layer, so the value does not
  matter to it.
- **Double close:** `taar_sock_close` on an already-closed fd returns -1
  (was 0), as Linux's close(2) returns -EBADF.
- **Defaults:** a new socket starts with the default 10 s deadline, never
  the one its slot's previous socket had.

### Decided

- **The stdlib's AGNOS socket adapter was evaluated and not adopted.** Since
  cyrius 6.6.17, the `syscalls` leaf taar already carries turns `sys_socket`,
  `sys_connect`, `sys_read` and `sys_write` into tagged fds with per-socket
  deadlines. It was not used, for three reasons:
  - its deadlines can only be set through `net.cyr`'s
    `sock_set_*_timeout`, and taar may not depend on `net` (whirl does not
    carry it); AGNOS `sys_setsockopt` declines everything;
  - its write re-arms the deadline whenever bytes move, which would change
    taar's per-call send deadline a second time in two releases;
  - it has no UDP.

  taar keeps its own tables.

### Documentation

- **Correction to 0.7.0.** 0.7.0 said `sock_connect#47` had no deadline form
  and that telling a clean EOF from a reset needed an agnos kernel change.
  Both were wrong: the kernel already has both.
  - **Connect deadline:** agnos 1.57.18 added `SC_TIMED` to `sock_connect#47`.
  - **Reset vs EOF:** agnos 1.57.17's `epoll_wait#21` reports `EPOLLERR` for a
    connection that died and `EPOLLRDHUP` for a FIN.

  What taar lacks is the cyrius stdlib wrappers for both. They are filed as
  cyrius issues 2026-11-04 and 2026-11-08, and both are open. The roadmap now
  points there.
- **One real kernel ask remains, now filed with agnos:** the one-datagram UDP
  listener, as agnos issue
  `2026-11-09-a-udp-listener-keeps-one-datagram-so-a-stray-one-evicts-the-reply.md`
  (written to agnos's `docs/development/issues/`, its file-based tracker). It
  carries the harness's measurement and asks for a small per-listener queue
  that drops new arrivals when full, with no ABI change.

### Tests

- **AGNOS harness: 53 → 84 checks.** New groups:
  - fd guards: out-of-range fds, which fault without the range checks, a
    foreign listener, and a UDP fd passed to a TCP call;
  - the TCP table: eight sockets open, the ninth is refused, each fd is
    distinct, and a second connect is refused;
  - fresh-socket defaults;
  - isolation: a consumer's TCP and UDP sockets survive a resolve.

  `peers.py` gains a slow TCP echo on port 7206.
- **Mutation-checked through the harness.** Each new guard was removed in
  turn: the range and open checks on both tables, every field open
  initialises, close marking a slot free, the connect-on-connected refusal,
  the table bound and the empty-recv guard. 16 of 17 mutations went red; the
  one green is explained below. The 0.7.0
  AGNOS set was re-run against the rewritten arm: 9 of 10 red, and the green
  one is the send-side no-connection check already documented as redundant.
  - Out-of-range fds make the selftest fault, which the harness reports as
    "did not finish".
  - Widening the TCP table's scan bound from 8 to 16 stays green, because
    the slots past the table read the connection table's -1 entries as
    "in use". Removing the bound outright is red: 16 sockets open.
- **`TAAR_AGNOS_TCG=1`** forces the harness onto TCG, which is what a CI
  runner without `/dev/kvm` gets. All 84 checks pass under it, in 23 s
  against 15 s with KVM.

## [0.7.0] - 2026-11-09

The AGNOS backend runs. Until now `src/socket.cyr`'s `#ifdef
CYRIUS_TARGET_AGNOS` arm had only ever been compiled. A new harness boots
the agnos kernel and executes it. Its first runs found two defects, and
reading `whirl` against the results found what one of them cost a
consumer.

### Added

- **`tests/agnos/run.sh` — AGNOS execution harness.**
  - **Boot chain:** the agnos 1.57.19 kernel and the gnoboot 0.9.0 UEFI
    loader, fetched from their GitHub releases. Each must match a SHA-256
    pinned in `tests/agnos/pins.sh` (both are reproducible builds,
    byte-identical to local ones). They boot under QEMU + OVMF, using KVM
    when it is available and TCG otherwise.
  - **Test program:** `tests/agnos/selftest.cyr`, built from the checkout on
    every run and installed as `/bin/agnsh`, which the kernel runs as its
    first program. No shell, no keystrokes, no change to agnos.
  - **Network:** QEMU's user-mode network reaches host-side socket peers
    (`tests/agnos/peers.py`) and the fake resolver (`fake_dns.py bylabel`).
    Both run inside a private user + network + mount + PID namespace, whose
    bind-mounted resolv.conf points QEMU's DNS forwarder at the fake. No root
    and no real network.
  - **Results:** 53 checks in about 15 s. Exit 2 means a prerequisite was
    missing, and the harness says nothing was tested; it never reads as a
    pass.
- **What it covers.** Three of the four 0.6.2 AGNOS changes now run:
  - the reply-source filter;
  - timeout 0 meaning no deadline;
  - `udp_send` returning the payload count.

  The fourth, the DNS retry's one-spin send cap, is superseded: with a
  deadline set, an AGNOS send now ends in `_TAAR_ERR_TIMEOUT` rather than 0,
  so the cap no longer fires there.

  Also covered:
  - UDP open, timeout, send, receive and close;
  - a fresh socket accepting any sender until its first send;
  - TCP connect, send, read to EOF and close;
  - the receive and send deadlines;
  - refused connects and connects whose SYNs are dropped;
  - `taar_resolve_ipv4` end to end through the kernel's DHCP lease: TC=0,
    the TC retry, three TCP-failure fallbacks, and a forged reply.

  The filter check is not vacuous. A raw-receive check proves both
  forgeries really reach the guest, and it also pins the kernel's
  `addr_out` layout (ip at +0, port at +8), which the filter reads.
- **CI `agnos` job** runs the harness on every push and PR (installs QEMU +
  OVMF, enables KVM).
- **A kernel canary.** An AGNOS UDP listener holds one unread datagram, and
  each arrival overwrites it (`net_handle_udp`). Linux queues them. taar now
  documents what that costs: a datagram landing after the real DNS reply, but
  before the next poll, evicts the reply and the resolve times out, though
  never with a wrong answer. A selftest check goes red if a kernel bump
  changes the behaviour.
- **`fake_dns.py` gains `spoof` and `bylabel` modes.** The Linux integration
  script adds a forged-reply case (seven cases), so both backends face the
  same forgery.

### Fixed (AGNOS)

- **`taar_tcp_send` honours the socket's deadline.** It was a bare
  `sock_send#48`, which ignores the timeout and returns 0 after about 8 s
  with no progress. Now:
  - it sends through `sock_send_dl#109` (agnos ≥ 1.57.13, probed once) with
    the deadline from `taar_tcp_set_timeout_ms`;
  - nothing sent by the deadline is `_TAAR_ERR_TIMEOUT`, as SO_SNDTIMEO makes
    Linux return;
  - with no deadline set it waits for progress, as a blocking write does;
  - an empty send returns 0.

  This is the defect a consumer felt: whirl's send loop treats 0 as "not
  yet" and retries up to 1000 times, so on AGNOS a peer that stopped reading
  could hold an upload for hours. Linux would have cut it off at whirl's
  10 s. The harness measured the old path at 8002 ms per call with a 500 ms
  deadline.
- **`taar_tcp_recv` with no connection returns -1, not 0.** The kernel
  answers -1 for conn -1, and taar maps -1 to "peer closed". So a socket that
  never connected, or was already closed, read as a clean hang-up. (The
  roadmap's no-connection guard.) `taar_tcp_send` gets the same guard. Today
  the kernel refuses conn -1 by itself, so mutation shows that guard is
  redundant; it is kept so the contract does not rest on kernel behaviour,
  and is commented as such.

### Changed

- `taar_tcp_set_timeout_ms` (AGNOS) now bounds recv **and send**. The connect
  is still bounded only by the kernel's ~8 s: `sock_connect#47` has no
  deadline form (new roadmap item).
- The integration scripts run each case as PID 1 of its own PID namespace
  (`--pid --fork --kill-child`), so a timed-out case cannot leave servers
  running.
- CI: the integration and agnos jobs relax Ubuntu 24.04's AppArmor
  restriction on unprivileged user namespaces, which otherwise makes the
  probe skip the cases. The lint, doc-coverage and syscall-literal gates now
  cover `tests/agnos/`.

### Documentation

- `src/socket.cyr`'s AGNOS header gains note 5 (the one-datagram slot) and
  note 6 (which deadlines the kernel can honour), and names the harness.
- Roadmap: 0.7.x is now *AGNOS parity*. Per-socket state is unblocked, and
  can perhaps sit on the stdlib's own AGNOS socket adapter. New items cover
  the connect deadline and the one-datagram slot. The consumer bump past
  0.5.0 is done and removed.

### Not verified

- The send probe's fallback for kernels older than agnos 1.57.13 is not in
  CI, because the harness boots 1.57.19. It was run once by hand against agnos
  1.57.12 (`TAAR_AGNOS_KERNEL`): 52 of 53 checks pass. The one red check is the
  500 ms send deadline, which on that kernel takes `#48`'s own ~8 s before
  ending in `_TAAR_ERR_TIMEOUT`, as documented.
- aarch64 AGNOS is still compile-only: agnos does not boot there yet.
- The CI `agnos` job has not yet run on GitHub's runners.

## [0.6.2] - 2026-11-08

A P(-1) review of everything taar ships: 17 findings, none critical or high, all
fixed. The full report, with method, evidence and the ten deferred items, is
[`docs/audit/2026-11-08-audit.md`](docs/audit/2026-11-08-audit.md).

### Security

- **No silent public-resolver fallback.** A resolv.conf naming only resolvers
  taar cannot use (IPv6, `0.0.0.0`) used to send every lookup to 8.8.8.8,
  bypassing the host's chosen resolver. Now the resolve fails closed. So does a
  resolv.conf over 4 KB whose usable line was cut at the buffer edge, which
  could otherwise yield a valid but wrong address. A missing file, or one naming
  no nameserver, still falls back.
- **AGNOS drops UDP replies from anyone but the nameserver.** The agnos kernel
  matches the destination port only, so a forger needed no address spoofing.
  `taar_udp_send` now records the peer and `taar_udp_recv` filters on it, as
  Linux's connected socket does. The match logic is unit-tested; the wiring is
  compile-only until AGNOS execution exists (roadmap 0.7.0).
- **Only class-IN A records are taken as addresses.**

### Changed

- **`taar_tcp_set_timeout_ms` also bounds connect and send (Linux).** It sets
  `SO_SNDTIMEO` as well as `SO_RCVTIMEO`. Before, a connect to a host whose
  SYNs were dropped waited out about 127 s of SYN retries whatever timeout was
  set. That applied to the DNS TCP retry and to whirl's 10 s HTTP connects. A
  timed-out connect fails -EINPROGRESS, and a send that writes nothing returns
  `_TAAR_ERR_TIMEOUT`.
- **The DNS TCP retry is bounded in reads (16) and zero-progress sends (1).**
  This caps a slow-drip peer, which before could take hours, and an AGNOS
  stall, which before could take about 8.5 minutes.
- **AGNOS parity.**
  - Timeout 0 means "no deadline", as on Linux; it used to expire at once.
  - The recv loops poll at least once.
  - A negative timeout is refused.
  - `taar_udp_send` returns the payload count, not the frame length.
- **resolv.conf parsing.** CRLF files parse, and a `0.0.0.0` entry no longer
  hides the servers after it.
- Both `set_timeout` results in `dns.cyr` are checked, so the resolve fails
  closed rather than blocking without a deadline.

### Tests

- Unit suite 93 → **140** assertions, in eight new groups. They cover the
  resolv.conf parser (previously untested), the resolver choice, name-length
  limits (with a canary proving the in-loop check stops the write), answer
  class, the read cap, the send timeout, the AGNOS deadline and peer helpers,
  and the compression loop only the hop budget stops. All 18 new guards were
  mutation-checked.
- Integration: a sixth case, `tc_blackhole` (a TCP/53 that drops SYNs). The
  script now builds its own binary on every run and runs each case under a
  timeout. It used to test whatever was left in `build/`, which locally was a
  binary from 2026-08-26. So the local integration results reported for 0.5.2,
  0.6.0 and 0.6.1 did not test those toolchains. A fresh build passes.
- **Benchmarks**: `benches/codec.bcyr`, eight rows over the per-resolve CPU
  paths, with `bench` as a `[test] stdlib` leaf. A baseline was taken before
  the repairs; the repairs cost about 30 ns per resolve. No optimisation was
  warranted.

### CI

- `cyrius distlib --check` is a hard gate (a stale bundle only warned before).
- The security job enforces the no-syscall-literal rule. It used to grep for
  `/etc/`, always warn, and never fail.
- Supply chain: `actions/checkout` and `softprops/action-gh-release` are
  SHA-pinned, and the cyrius installer is fetched at the pinned tag rather than
  `main`. The token is read-only except in the release job.
- Lint and doc gates cover `benches/`; benches compile and run in CI.

### Documentation

- `roadmap.md` is reorganised into 0.7.x (AGNOS executed), 0.8.x (resolver
  completeness), 0.9.x (surface freeze), 1.0.0 criteria and a trigger-gated v1
  backlog. A closed item and a stale stdlib claim were dropped.
- Comments the code had outgrown are corrected (listed in the report, finding
  P). The "check the consumer before parking" lesson moved from state.md to
  CLAUDE.md, which also gains the `docs/audit/` convention.
- The bundle uses no 6.7 language feature: it still builds, and resolves live,
  under the consumers' cyrius 6.6.2.

## [0.6.1] - 2026-11-08

### Changed

- **Toolchain `6.7.9` → `6.7.18`** (the latest cyrius release). No source
  change was needed. The 6.7.10–6.7.18 migration notes were checked against
  every stdlib symbol taar calls. The notes that name one of them are about
  Windows, macOS or a raw negative fd on AGNOS. taar's AGNOS arm closes and
  sends through `sys_sock_close` / `sys_sock_send`, so none applies. The new
  lint rule for constant overruns of a `var a[N]` buffer reports nothing.

  All **93 assertions** pass on x86_64 and on aarch64 (executed under
  `qemu-aarch64`), the AGNOS build still compiles with its arm selected, all
  five TC-fallback cases pass, and both live smokes (UDP and TCP) resolved.
  `lib/` was re-vendored: the same 19 files, each byte-identical to the 6.7.18
  bundled stdlib.
- **`dist/taar.cyr` differs from 0.6.0 only in its version line**, and the
  sidecar is still `syscalls` + `fmt`. The bundle body is byte-identical to
  0.6.0's, so it still builds on consumers' cyrius `6.6.2`.

## [0.6.0] - 2026-11-08

### Changed

- **Toolchain `6.6.20` → `6.7.9`** (the 6.7 language minor: checked traits,
  `dyn`, tuples, slices, bounds-checked mode). No source change was needed.
  Every 6.7.x migration note was checked against taar first:
  - no lone `!` (before 6.7.3 the lexer dropped it, so `!x` meant `x`);
  - no unary `-` / `~` on a constant followed by an operator and a literal
    (6.7.9 re-binds those);
  - no identifier the 6.7.x releases reserved (`trait`, `const`, `true` /
    `false`, `do`, `dyn`);
  - no `impl`, typed pointer or `bool`.

  All **93 assertions** pass on x86_64 and on aarch64 (executed under
  `qemu-aarch64`), the AGNOS build still compiles with its arm selected, and all
  five TC-fallback cases pass. The two live smokes (`resolve-smoke` over UDP,
  `tcp-resolve-smoke` over TCP) resolved against a real resolver. `lib/` was
  re-vendored: the same 19 files, each byte-identical to the 6.7.9 bundled
  stdlib.
- **`dist/taar.cyr` differs from 0.5.2 only in its version line.** The sidecar
  is still `syscalls` + `fmt`. The bundle still compiles on consumers' cyrius
  `6.6.2` (x86_64 and aarch64 built and run, AGNOS built), so the toolchain
  bump does not force one on `yo`, `dig` or `whirl`.
- **`cyrius tests` → `cyrius test`.** The plural form is a deprecated alias
  since 6.7.6. At 6.7.9 it prints "goes in the next release", and at 6.7.12 it
  becomes an unknown command (rc 1). CI's `aarch64` job, `CLAUDE.md`'s work
  loop, the README and a `src/test.cyr` comment now use
  `cyrius test [--aarch64] tests/`, which gives the same 93/93.

## [0.5.2] - 2026-11-08

### Changed

- **Toolchain `6.6.2` → `6.6.20`.** No behaviour change. All **93 assertions**
  pass on x86_64 and on aarch64 (executed under `qemu-aarch64`), the AGNOS
  build still compiles with its arm selected, and all five TC-fallback cases
  pass. `lib/` re-vendored to 19 files, each byte-identical to the 6.6.20
  bundled stdlib; `vec`, `poison` and `alloc_cx` now come in transitively.
- **`dist/taar.deps` lists only what the bundle uses: `syscalls`, `fmt`.**
  Since 6.6.18, `distlib` derives the sidecar by compile-verifying the bundle
  instead of copying `[deps] stdlib`, so the test-only `assert` and `alloc`
  (and `vec`) no longer go out to consumers. The bundle also gains a
  `# Requires` block (`include "lib/syscalls.cyr"`, `include "lib/fmt.cyr"`),
  which makes it includable on its own. No consumer is affected: `yo`, `dig`
  and `whirl` already declare all five leaves themselves.
- **CI lint and doc gates now cover `tests/`.** 6.6.20's `cyrius audit` added
  `tests/` to its scope. That surfaced 3 lint warnings (two lines over 120
  characters, one double blank line) and 3 undocumented fns (`test_dns_build`,
  `test_dns_parse_a`, `main`) in `tests/taar.tcyr`, all now fixed. The CI gates
  say they cover the same scope as `audit`, so they were widened to match.

### Documentation

- **`src/socket.cyr` said the stdlib has no `sendto` wrapper.** It has had
  `sys_sendto` (`SYS_SENDTO` 44 / 206) since cyrius 6.6.5. Only the comments
  changed. `taar_udp_send` keeps connect-then-write, since RFC 5452 off-path
  rejection justifies it on its own.
- **roadmap: dropped "file the stdlib clock/sleep/sendto gap upstream".** That
  gap is closed at 6.6.20. `sys_sendto` and `sys_nanosleep` exist on both Linux
  arches, and `clock_now_ns` / `sleep_ms` were checked under `qemu-aarch64`
  (a 50 ms sleep measured 50.3 ms).
- **state.md was two releases stale.** It still said 0.5.0 on `6.5.35`, and its
  consumer table and carry-forward had every consumer pinning taar `0.3.1`. All
  three pin `0.5.0`. Refreshed, and the 0.3.1 carry-forward removed. The README
  status line, example tag, toolchain pin and dependency paragraph are refreshed
  too.
- The benign `vec_get` build-warning note is gone, since the warning no longer
  appears. It is replaced by the `sys_openat (x86_64-windows)` note that
  6.6.18's `distlib` verify now prints. Windows is not a taar target.

## [0.5.1] - 2026-09-11

### Changed

- **Toolchain `6.5.35` → `6.6.2`.** No source change — taar has no `Result` /
  `Option` / `Either` surface, so the 6.6.0 value form does not reach it. Zero
  compiler rejections, zero fail-open sites, zero `callptr`. **93 assertions** pass.


### Documentation
Sweep of every doc against the actual tree, and a split of what each file is
for. Corrections, not rewording — each of these was stated and wrong:

- **README claimed TCP was planned.** The module table carried a combined
  `tcp`/`tls`/`http` "planned" row, but `taar_tcp_*` shipped in 0.2.0 and
  `whirl`'s HTTP transport has been running on it since. Split so `socket`
  reads "UDP **and TCP**" and only `tls`/`http` remain planned.
- **README and state.md both claimed `dns` carries an AGNOS backend.**
  "Both socket/dns backends ship behind `#ifdef`" — `src/dns.cyr` has zero
  `CYRIUS_TARGET_AGNOS` references. `src/socket.cyr` is the only module with
  per-target arms; `dns` is platform-neutral framing that reaches the kernel
  only through `socket`'s helpers.
- **README overstated the bundle's dependencies.** It named all four
  `[deps] stdlib` leaves as required. The shipped bundle references only
  `syscalls` and `fmt` — `assert` (and `alloc`, which it pulls in
  transitively) exist for taar's own test suite. `dist/taar.deps` echoes the
  full list and so over-declares; that is now stated rather than repeated as
  fact.
- **state.md contradicted itself on consumer status.** Its Consumers table
  said `yo` was "pending — folds `ipv4`" while its own carry-forward said `yo`
  had already dropped its in-tree `ipv4.cyr`. The latter is correct. Same for
  `icmp`: the table said "folds when `yo` migrates" (which has happened) while
  the carry-forward correctly noted it waits on a *second* ICMP consumer.
- **roadmap.md listed 0.5.0 above 0.4.0** in its Shipped section.

### Changed
- **`roadmap.md` is forward-looking only.** Its Shipped section duplicated
  `CHANGELOG.md` and had already drifted out of order — removed. Consumer
  migration now lists only what remains rather than restating finished work.
- **`state.md` is a snapshot again.** It had accumulated four releases of
  history, which is `CHANGELOG.md`'s job. One current-version block now; the
  Verification section says plainly what is gated and what is not.
- **Durable conventions moved to `CLAUDE.md`** from state.md — the
  no-syscall-literals rule and the timeout-is-never-zero contract are process,
  not state. `CLAUDE.md` gains a "Documentation split" section naming what each
  of the four docs is for, so this drift is less likely to recur, and its work
  loop now matches the real gates (it still said `cyrius test`, and predated
  the aarch64, AGNOS, doc and integration checks).
- **Bundle line counts now name their source.** state.md quoted `cyrius
  distlib`'s count in some places and `wc -l` in others — 966 and 979 are the
  same bundle, differing by the 13-line generated header.

### Added
- **CI builds the AGNOS target.** Found by the sweep: nothing in CI compiled
  the `#ifdef CYRIUS_TARGET_AGNOS` arm, so a break there would have landed
  silently despite the backend being a headline feature. The `build` job now
  compiles it and asserts the image differs from the Linux build, proving the
  arm is actually selected. It still only *compiles* — see the roadmap.
- README gains a **Targets** table (built vs. tests-executed per target, making
  the AGNOS gap visible) and a **Documentation** index.

## [0.5.0] — 2026-08-26 — recv-contract parity; docs + integration gated in CI

Closes the last taar-side roadmap item and the oldest carry-forward. The two
remaining module items (`icmp`, `tls`/`http`) stay parked — both wait on a
consumer forcing the duplication, and per CLAUDE.md are not pre-built.

### Changed
- **AGNOS `taar_tcp_recv` no longer reports a timeout as a clean close.** A
  deadline expiry now returns `_TAAR_ERR_TIMEOUT`; `0` keeps its one meaning,
  "the peer closed". Until now both were `0`, so a peer that stalled mid-body
  made a truncated read look like a finished response and the caller had no way
  to tell.

  This sat as a carry-forward on the belief it would break `whirl`. Reading the
  actual call sites settled that it does not:
  - `whirl`'s transport loops on `if (n <= 0) { go = 0; }` — a negative stops
    the loop exactly as `0` did.
  - `whirl` also installs `taar_tcp_recv` as a cyrius `tls_native` transport
    callback, whose documented contract is "bytes (>0), or **<=0** on
    EOF/error (sys_read sense)" — a negative is squarely inside it.
  - taar's own `_taar_dns_tcp_read_all` uses `if (n <= 0) { return off; }`.

  So no known consumer changes behaviour. It is a minor bump because the
  documented return value changed, not because anything is expected to break.
  Two things made the old behaviour the odd one out rather than a design
  choice: the **Linux** arm already separated the cases (a `SO_RCVTIMEO` expiry
  is `-EAGAIN` from `read(2)`, a close is `0`), and this same file's
  `taar_udp_recv` already returned `-11` on timeout. AGNOS TCP was the only
  place the two collapsed, against a module contract promising an identical
  surface on both targets.
- **`_TAAR_ERR_TIMEOUT`** replaces the bare `-11` literal in both AGNOS poll
  loops. It is `-EAGAIN` — the value the kernel itself yields on a `SO_RCVTIMEO`
  expiry — so callers need one check, not one per backend.

### Added
- **Doc comments on every public fn.** `cyrius audit` reported 15 undocumented
  across `src/` and `programs/`; it now reports `ok: docs complete`, so all four
  audit dimensions (fmt, lint, docs, tests) are green.
- **CI `integration` job** — runs `tests/integration/tc_fallback.sh`, the
  roadmap item left open in 0.4.0. It probes `unshare -rn` first and
  warns-and-skips if a runner forbids unprivileged user namespaces, so a
  sandbox policy cannot red the build. That was the open question blocking the
  wiring; the probe answers it per-run instead of once, up front.
- **CI doc-coverage gate** in the build job, over the same `src/` + `programs/`
  scope `cyrius audit` uses. `audit` counts undocumented fns but does not fail
  on them, so without this the state above would quietly rot.

### Tests
- Unit suite 89 → **93**, adding `socket-recv-contract`: an AF_UNIX socketpair
  where no peer ever writes, so the deadline is guaranteed to expire, then the
  far end is closed to give a genuine clean close to compare against. It pins
  both halves — expiry is `_TAAR_ERR_TIMEOUT`, close is `0`.
- Mutation-checked: making the Linux arm map negatives to `0` (reproducing the
  bug AGNOS had) turns the new group red. The test is host-only, like the rest
  of the suite, and passes under `--aarch64` too.
- Full sweep green: x86_64, aarch64 (`qemu-aarch64`), AGNOS build, live UDP and
  TCP resolves, and all five integration cases.

### Notes
- The AGNOS arm still has no *executed* coverage anywhere — it compiles, and
  the emitted image is confirmed to differ from the Linux one, but nothing runs
  it. That is now the largest untested surface in the repo.
- Consumer pins (`yo`, `dig`, `whirl` on `taar 0.3.1`) are unchanged here by
  design — those repos are being updated separately.

## [0.4.0] — 2026-08-26 — DNS over TCP (TC fallback); last raw syscall retired

Clears the two roadmap items that were actually actionable. The other two
(`icmp`, `tls`/`http`) stay parked: both are gated on a consumer forcing the
duplication, and neither consumer has.

### Added
- **DNS TCP fallback on truncation (RFC 1035 §4.2.2).** A reply with the TC bit
  set is a *prefix* of the real answer — taar parsed it as though it were whole.
  `taar_resolve_ipv4` now re-asks over TCP-53, which has no 512-byte ceiling:
  - `_taar_dns_tcp_frame` — the 2-byte big-endian length prefix (pure, unit-tested).
  - `_taar_dns_tcp_send_all` / `_taar_dns_tcp_read_all` — TCP is a stream that may
    split or coalesce anywhere, so both loop. The send loop is spin-bounded
    (`_TAAR_DNS_TCP_MAX_SPINS`) against a peer that accepts zero bytes forever;
    the read loop always terminates because each pass advances or returns.
  - `_taar_dns_query_tcp` — connect, framed send, framed read. A declared length
    larger than the caller's buffer is **refused outright** rather than truncated:
    trusting it would write the peer's number of bytes into a 2 KB stack array.
  - `_taar_dns_reply_ok` — the 0.3.3 acceptance rules (QR / id / QDCOUNT /
    question echo), factored out so the TCP reply is held to exactly the same
    bar as the UDP one. The UDP path now calls it too.
  - **Every failure path falls back to the truncated-but-valid datagram answer**,
    which is what taar returned before this existed. The retry can only improve
    an answer, never lose one.
- **`programs/tcp-resolve-smoke.cyr`** — drives the TCP transport directly, since
  no live resolver can be made to truncate on demand. Like `resolve-smoke`, it
  needs a real resolver and is not a CI job.
- **`tests/integration/`** — a fake DNS server (`fake_dns.py`) that answers
  *differently* over UDP and TCP, plus `tc_fallback.sh`, which runs each case
  inside `unshare -rn`. A private network namespace is what makes this possible
  without root: it grants CAP_NET_BIND_SERVICE for port 53 and frees
  127.0.0.53, so an unmodified `/etc/resolv.conf` points at the fake. Five cases:
  TC=0 uses UDP; TC=1 retries TCP; TC=1 with no TCP listener falls back; and a
  TCP peer that lies about its framed length (too long, too short) is refused.

### Changed
- **`_taar_plat_dns_server` uses `sys_net_dns_server()`** instead of the interim
  raw `syscall(61, 3)`. cyrius 6.5.35 ships the wrapper (the agnos request
  `2026-06-23-agnos-net-config-syscall-wrapper` landed), and its own comment
  spells out why it matters: #61 is `net_config` on AGNOS but **`wait4(2)` on
  Linux**. The `#ifdef` kept taar safe, but this was the last syscall number
  written as a literal anywhere in the tree — the same class 0.3.3 was about.

### Tests
- Unit suite 73 → **89** assertions: `dns-tcp-frame` (prefix encoding, zero and
  >65535 rejection, verbatim body copy) and `dns-reply-ok` (each acceptance rule
  independently, plus that TC is *not* an acceptance failure — it is the retry
  trigger).
- New guards mutation-tested as in 0.3.3. Two notes on what that showed:
  - The `mlen > rmax` bound is genuinely load-bearing — with it removed, the
    `tc_huge` case delivers 60000 bytes into a 2048-byte stack buffer and the
    process dies. The first version of that test declared a huge length without
    sending it, so a short read masked the overflow; the server now delivers
    every byte it claims.
  - The `len < _TAAR_DNS_HEADER_LEN` check in `_taar_dns_reply_ok` does not move
    the suite, because the question-echo check rejects the same inputs. It is
    kept and commented: it is what makes the header reads above it in-bounds
    rather than accidentally harmless.
- Verified on x86_64, aarch64 (`qemu-aarch64`) and the AGNOS build target; the
  integration harness passes against both the x86_64 and aarch64 binaries.

### Notes
- **`yo` 0.5.7, `dig` 0.3.5 and `whirl` 0.6.4 all pin `taar 0.3.1`.** They are
  therefore missing the 0.3.3 fixes — the aarch64 `sendto` defect and the DNS
  reply-acceptance hardening — as well as everything here. Bumping those pins is
  consumer-repo work and is not part of this cut.
- The integration harness is not wired into CI: `unshare -rn` needs to be
  confirmed permitted on the runner first. Tracked in state.md carry-forward.

## [0.3.3] — 2026-08-26 — P-1 audit: hardening + repairs

A priority-1 sweep of the whole substrate — arch portability, the DNS reply
path, entropy, and memory. Six defects fixed, all reachable from
`taar_resolve_ipv4`, the one public entry point that parses attacker-supplied
bytes. No public signature changed; consumers rebuild unmodified.

### Fixed

- **aarch64: `taar_udp_send` sent nothing and overwrote the caller's packet
  buffer.** The Linux backend hardcoded x86_64 syscall numbers. cyrius's
  aarch64 backend rewrites the numbers it recognises (ESYSXLAT), which is why
  `--aarch64` builds were clean and most calls worked — but **sendto has no
  entry**, because it has no stdlib wrapper or `SYS_SENDTO` constant. x86_64
  44 is `sendto`; aarch64 44 is `fstatfs(2)`. The old
  `syscall(44, fd, pkt, len, …)` therefore returned 0 (which passed taar's
  `sent < 0` check), transmitted nothing, and wrote ~120 bytes of
  `struct statfs` over the DNS query buffer. Every aarch64 resolve then blocked
  until the 5s timeout and failed. **Verified under `qemu-aarch64`:** the 0.3.2
  `resolve-smoke` exits 1 on aarch64 while succeeding on x86_64; 0.3.3 returns
  an address on both.
  - The whole Linux backend now goes through the stdlib's arch-dispatched
    wrappers (`sys_socket` / `sys_connect` / `sys_setsockopt` / `sys_recvfrom`
    / `sys_read` / `sys_write` / `sys_close` / `sys_openat`).
  - `taar_udp_send` is now `connect(2)` + `write(2)` instead of `sendto` —
    there is no sendto wrapper to switch to, and this closes a security gap
    at the same time (below). `_taar_plat_read_file` moved to `sys_openat`,
    since bare `open(2)` does not exist on aarch64 at all.
  - `programs/resolve-smoke.cyr` (`syscall(1, …)`) and `tests/taar.tcyr`
    (`syscall(60, …)`) carried the same literals; both now use the dispatched
    forms.

- **DNS replies were accepted on a 16-bit ID alone (RFC 5452).** The UDP socket
  was unconnected, so the kernel delivered datagrams from *any* source, and
  taar checked only the query ID and rcode. A forged reply that guessed the ID
  was accepted — its QR bit, question section and source were never examined.
  Worse, a single non-matching datagram aborted the whole resolve, so one
  stray packet was a reliable denial of service. Now:
  - the socket is connected to the nameserver, so the kernel drops anything
    not from that address/port (an off-path attacker must also guess the
    ephemeral source port);
  - a datagram is parsed only if QR=1, the ID matches, QDCOUNT is 1, and the
    question section is echoed back byte-for-byte (`_taar_dns_same_question`);
  - non-matching datagrams are skipped and the wait resumes, bounded by
    `_TAAR_DNS_MAX_REPLIES` (8).

- **The DNS query ID could be uninitialised stack.** `_taar_plat_random_u16`
  ignored the result of its `/dev/urandom` read (and, on AGNOS, of
  `sys_getrandom`), so a short or failed draw left the 2-byte buffer
  uninitialised and its garbage became the query ID — the precise opposite of
  what RFC 5452, cited in that function's own comment, asks for. The AGNOS
  ephemeral **source port** (`_taar_ag_ephemeral_port`) had the identical bug.
  Both now zero-initialise, check the byte count, and return -1 so the caller
  fails closed rather than resolving with a guessable ID. Linux draws from
  `getrandom(2)` directly instead of opening `/dev/urandom`.

- **`taar_resolve_ipv4` leaked 6.4 KB per call and never checked `alloc`.**
  cyrius's `alloc` is a bump allocator with no per-pointer `free`, so the
  300 B query, 2 KB reply and 4 KB resolv.conf buffers were gone for the
  process lifetime — unbounded growth in a long-running consumer. The return
  was also never checked, so allocator exhaustion meant stores through a null
  pointer. All three are now function-local stack, matching the allocator-free
  posture `socket.cyr` already documented. The bundle no longer references the
  allocator at all.

- **`taar_fill_sockaddr` did not exist on AGNOS.** It was defined inside the
  `#ifndef CYRIUS_TARGET_AGNOS` arm despite being public API and pure,
  syscall-free byte packing, so an AGNOS-target consumer calling it failed to
  link — against this module's "identical `taar_*` surface" contract. Hoisted
  out of both arms.

- **An empty hostname produced a well-formed query for the root zone.**
  `_taar_dns_encode_name("")` returned the bare root label and
  `_taar_dns_build_query` wrapped it into a valid A query for `"."`. Both now
  reject it, and `taar_resolve_ipv4` rejects an empty host before opening a
  socket. A trailing dot (`"example.com."`) is still accepted and encodes
  identically to the undotted form.

### Tests

- `tests/taar.tcyr` → **73 assertions** (was 40), adding four groups:
  `dns-reply-match` (QR / TC / question-echo binding), `dns-hostile`
  (self-referential, forward and out-of-range compression pointers; reserved
  label prefixes; a maximum-length label; rdata running past the message end;
  header-only truncation), `dns-encode-edges`, and `resolve-guards`
  (null/empty host and literal short-circuit — all offline).
- Every guard was **mutation-tested**: each bounds check was individually
  removed and the suite confirmed to go red. Two initial tests did not survive
  this and were rewritten — an over-long `rdlength` case that never reached the
  bounds check, and a reserved-label-prefix case masked by the
  end-of-message check.
- Suite now also run green under `--aarch64` (via `qemu-aarch64`), which is how
  the sendto defect was caught and confirmed fixed.

### Notes
- `ipv4_parse` accepts leading zeros and reads them as **decimal**: `010.1.1.1`
  is 10.1.1.1, where `inet_aton(3)` would say 8.1.1.1. taar's callers consume
  the packed return value rather than re-parsing the string, so this is now
  pinned by test rather than changed; see the state.md carry-forward.
- AGNOS `taar_tcp_recv` still reports a deadline expiry as `0`, the same value
  as a clean peer close, so a stalled peer can make a truncated read look
  complete. Giving timeout its own return is a breaking change for whirl's
  transport and is left as a tracked carry-forward, not slipped into a patch.
- `dist/taar.deps` still lists `assert` and `alloc`: the sidecar echoes the
  project's `[deps] stdlib`, and the test suite needs `assert`, which itself
  includes `lib/alloc.cyr`. The shipped bundle no longer uses either.

## [0.3.2] — 2026-08-26 — toolchain + stdlib refresh

Maintenance cut: no `src/` changes. The cyrius pin and the vendored stdlib
snapshot both move up to current, and `cyrius distlib` gains a dep sidecar.

### Changed
- **Cyrius pin `6.2.6` → `6.5.35`** (`cyrius.cyml [package].cyrius`). The pin is
  the single source of truth both CI workflows read to install the toolchain, so
  this is the only place the version appears. Clears the `toolchain drift`
  warning cycc emitted on every build.
- **Vendored stdlib re-resolved from the 6.5.35 snapshot** — all 16 `lib/*.cyr`
  files changed (`lib/` is a `cyrius deps` build artifact, gitignored, not
  source). Largest deltas are the syscall tables: `syscalls_x86_64_agnos.cyr`
  23,656 → 79,649 bytes, `syscalls_windows.cyr` 6,261 → 18,078,
  `syscalls_aarch64_linux.cyr` 20,115 → 31,870; also `alloc.cyr` 26,485 → 42,247
  and `fmt.cyr` 7,878 → 12,844. No taar source change was needed to absorb them.
- `dist/taar.cyr` regenerated at 0.3.2 — bundle body is **byte-identical** to
  0.3.1 apart from the version header, confirming the stdlib bump is
  source-transparent to consumers.

### Added
- **`dist/taar.deps`** — dep sidecar now emitted by `cyrius distlib` (6.5.35),
  listing the four stdlib leaves the bundle needs in scope (`syscalls`, `fmt`,
  `assert`, `alloc`) for a consumer's `cyrius deps` to pick up. Matches
  `[deps] stdlib` exactly. Ships alongside `dist/taar.cyr`.

### Verified
- Linux: `cyrius build programs/smoke.cyr` + smoke run green; **40** unit
  assertions / 0 failed (unchanged); `programs/resolve-smoke.cyr` resolved a
  live domain over UDP-53.
- AGNOS: `CYRIUS_TARGET_AGNOS=1 cyrius build --agnos src/main.cyr` compiles the
  sovereign backend; the emitted image differs from the Linux build, confirming
  the `#ifdef` branch is taken.
- `cyrius audit` — fmt clean, lint clean, tests green. `cyrius distlib --check`
  reports the committed bundle current.

### Notes
- The pre-existing `undefined function 'vec_get'` warning is unchanged: it comes
  from a `vec`-args variadic path in `lib/fmt.cyr` that taar never calls (taar
  uses `fmt_int_buf` only), and it is dead-code-eliminated. Adding `vec` to
  `[deps] stdlib` would push a dep onto consumers that don't carry it.

## [0.3.1] — 2026-06-23

### Added
- **AGNOS resolver discovery prefers the kernel-leased DNS server.** On agnos,
  `_taar_resolv_discover` (`src/dns.cyr`) now calls the new **`net_config(3)`#61**
  syscall first via `_taar_plat_dns_server` (`src/socket.cyr`) — the DHCP option-6
  on-subnet resolver — and uses it when `> 0`, before `/etc/resolv.conf` and the
  `8.8.8.8` fallback. The off-subnet fallback needs working gateway routing the kernel
  can't guarantee on real iron (it froze `whirl https://google.com` on archaemenid);
  the leased resolver is on-subnet + directly ARP-reachable. The Linux backend's
  `_taar_plat_dns_server` returns `0`, so the `/etc/resolv.conf` path is unchanged
  there. Interim raw `syscall(61, 3)` (a cyrius `sys_net_config` wrapper is requested,
  agnos `2026-06-23-agnos-net-config-syscall-wrapper`). **Requires agnos ≥ 1.45.16.**

## [0.3.0] — 2026-06-18 — AGNOS sovereign backend

The socket substrate gains its **AGNOS backend**, selected at compile time by the
cyrius emit target (`CYRIUS_TARGET_AGNOS=1`). The `taar_*` API is identical across
both targets — consumers (`whirl`'s transport, `taar`'s own DNS) never branch.

### Added
- **`src/socket.cyr` AGNOS backend** (`#ifdef CYRIUS_TARGET_AGNOS`) — sovereign
  ring-3 syscalls via cyrius's agnos syscall lib, mirroring `dig`'s `platform_agnos.cyr`:
  - **TCP** over `sock_connect`#47 / `sock_send`#48 / `sock_recv`#49 / `sock_close`#50.
    AGNOS has no `socket()`+`connect()` split, so `taar_tcp_open` resets the conn
    slot and `taar_tcp_connect` does the real `sock_connect` (ephemeral src port from
    `getrandom`#45), stashing the conn_id (single active conn; taar is single-threaded).
    `sock_recv`#49 is non-blocking (`>0` / `0`=WOULD_BLOCK / `-1`=EOF) — `taar_tcp_recv`
    polls it against an `uptime_ms`#40 deadline and maps the result back to the Linux
    blocking-read sense (`>0` data, `0`=closed) callers expect.
  - **UDP** over `udp_bind`#51 / `udp_send`#52 / `udp_recv`#53 / `udp_unbind`#54
    (ephemeral source port; packed `(sport<<16)|dport`; deadline-polled recv).
  - **Platform helpers** `_taar_plat_random_u16` (`getrandom`#45) + `_taar_plat_read_file`
    (`sys_open`/`read`/`close`) — relocated here from `dns.cyr` so DNS stays
    platform-neutral RFC-1035 framing.
- **`taar_udp_close`** — splits UDP teardown (`udp_unbind`#54 on AGNOS) from
  `taar_sock_close` (TCP `sock_close`#50). On Linux both remain `close(2)`. `dns.cyr`
  now closes its UDP listener via `taar_udp_close`.

### Changed
- `src/socket.cyr` Linux backend wrapped in `#ifndef CYRIUS_TARGET_AGNOS`; the
  entropy/file helpers `_taar_dns_random_u16` / `_taar_dns_read_file` removed from
  `dns.cyr` (folded into the platform helpers).
- `dist/taar.cyr` regenerated (643 lines) — the `#ifdef` blocks survive the bundle
  concatenation and resolve at the **consumer's** compile target.

### Verified
- Linux: build + smoke + **40** unit assertions green (unchanged).
- AGNOS: `CYRIUS_TARGET_AGNOS=1 cyrius build src/main.cyr` compiles the sovereign
  backend — `sys_sock_*` / `sys_udp_*` / `sys_getrandom` / `sys_uptime_ms` /
  `sys_sleep_ms` resolve from the agnos syscall lib (same path `dig` proved).

## [0.2.0] — 2026-06-18 — socket + dns (whirl extraction)

`whirl` (the third network-tools consumer) drove the next two substrate modules.
The transport `whirl` needs — TCP + hostname resolution — is lifted here as the
documented "taar grows" step, so `dig` can dedup onto it later.

### Added
- **`src/socket.cyr`** — raw-syscall UDP + TCP primitives (Linux backend; the
  AGNOS `#ifdef` backend is a follow-up). `taar_udp_open` / `taar_udp_send` /
  `taar_udp_recv` / `taar_udp_set_timeout_ms`; `taar_tcp_open` / `taar_tcp_connect`
  / `taar_tcp_send` / `taar_tcp_recv` / `taar_tcp_set_timeout_ms`; `taar_sock_close`
  + the shared `taar_fill_sockaddr`. Allocator-free (stack scratch), no lib/net.cyr.
- **`src/dns.cyr`** — `taar_resolve_ipv4(host)`: resolv.conf discovery + RFC 1035
  A-record query build + response parse (pointer-loop-guarded), over UDP-53.
  Ported from dig's `dns.cyr` + `resolv.cyr`, narrowed to the A-record path;
  framing helpers are `_taar_dns_*`-prefixed so this coexists with dig's own
  `dns.cyr` until dig refactors. A literal dotted-quad short-circuits the lookup.
- **`programs/resolve-smoke.cyr`** — live DNS check (resolves a real domain).
- `dist/taar.cyr` regenerated (ipv4 + socket + dns); `[deps] stdlib` gains `alloc`.

### Tests
- `tests/taar.tcyr` → **40 assertions** (ipv4 17 + sockaddr 10 + dns encode/build/
  parse-A 13). Live resolve confirmed (`example.com` → a real Cloudflare IP).

### Notes
- First consumer: `whirl` 0.2.0 (HTTP transport over `taar_tcp_*` + `taar_resolve_ipv4`).
- Still planned: the AGNOS socket backend (`sock_*`#47-50 / `udp_*`#51-54), `icmp`
  (for `yo`), and `tcp`/`tls`/`http` growth; `dig` dedups onto `taar.dns`/`socket`.

## [0.1.0] — 2026-06-14 — extraction: IPv4 codec

First cut of the network-tools substrate library. Opened at the documented
extraction trigger — `yo` 0.5.4 and `dig` 0.3.2 carried a byte-identical
`src/ipv4.cyr`; that duplication is the signal to extract a shared lib (the
same second-consumer pattern as `mihi → iam/chakshu`).

### Added
- **`src/ipv4.cyr`** — the strict dotted-quad IPv4 codec, taar's canonical
  home for it: `ipv4_parse` (dotted-quad → packed u32, `IPV4_PARSE_FAIL`
  sentinel on any rejection) and `ipv4_format_to_buf` (packed u32 →
  dotted-quad, returns bytes written). Packing matches
  `agnos/kernel/core/net.cyr` `ip4()` so a parsed address feeds the AGNOS
  `sock_connect` / `udp_send` packed-addr argument directly.
- **`[lib]` distlib** → `dist/taar.cyr` (consumer bundle); `[deps] stdlib`
  = `syscalls` / `fmt` / `assert`.
- **`programs/smoke.cyr`** — parse → format round-trip; **`tests/taar.tcyr`**
  — 17 assertions (valid/reject parse cases + format + round-trip).
- Repo scaffold: README, LICENSE (GPL-3.0-only), CLAUDE.md, docs/development.

### Notes
- Consumers `yo` and `dig` fold their in-tree `ipv4.cyr` onto this module in
  follow-on patch cuts; their AGNOS backends (`platform_agnos.cyr`) are
  unaffected — `ipv4` is pure code with no syscalls.
- Planned modules (grow per second-consumer trigger): `socket` (UDP/ICMP
  shim, Linux + AGNOS backends), `icmp` (echo + checksum), `dns` (query
  build / response parse / name compression). `whirl` arrives as the third
  consumer and adds the TCP/TLS/HTTP submodules.
