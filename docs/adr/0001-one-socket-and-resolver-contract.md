# 0001 — One socket and resolver contract across the Linux and AGNOS backends

**Status**: Accepted
**Date**: 2026-11-09

## Context

taar ships one public surface — `ipv4_*`, `taar_udp_*`, `taar_tcp_*`,
`taar_sock_close`, `taar_fill_sockaddr`, `taar_resolve_ipv4` — and two
implementations of its socket half, chosen at the *consumer's* compile target by
the one `#ifdef CYRIUS_TARGET_AGNOS` split in `src/socket.cyr`.

**The two kernels do not agree on what a socket is.**
- **Linux** has the POSIX family: kernel fds, blocking calls, `SO_RCVTIMEO` /
  `SO_SNDTIMEO`, negative errno returns, and signals that can interrupt a wait.
- **AGNOS** has connection ids rather than sockets:
  - `sock_connect#47` combines `socket()` and `connect()`, and blocks for its own
    ~8 s;
  - `sock_recv#49` and `udp_recv#53` never block;
  - there is no `setsockopt`, no errno space and no SIGPIPE;
  - its error answer is almost always -1.

The AGNOS arm bridges the gap: it polls against a deadline, keeps its own
per-socket tables, and maps the kernel's answers back to the Linux sense.

**Until now the contract was implied, not written.** It lived in doc comments on
each arm, and it drifted. Every fix from 0.5.0 to 0.7.1 was a place where the two
arms quietly disagreed:
- **0.5.0:** an AGNOS receive deadline read as a clean close.
- **0.6.2:** the AGNOS UDP source filter was missing, and Linux's TCP timeout
  bounded receive only.
- **0.7.0:** an AGNOS send ignored its deadline, and a receive with no connection
  read as EOF.
- **0.7.1:** a resolve disturbed the caller's AGNOS sockets.

Each was found by reading one arm against the other, or against a consumer. 0.7.0
added an execution harness for the AGNOS arm (`tests/agnos/run.sh`). A harness
needs a written contract to test against. Without one, a test pins whatever the
code does today.

**Writing this contract found one more disagreement.** On Linux, `taar_tcp_send`
is `write(2)`. A send to a peer that has gone raises SIGPIPE and kills the
calling process: measured exit 141, before the call returns. On AGNOS the same
call returns -1. whirl does not ignore SIGPIPE, so a plain-HTTP upload to a
server that resets mid-send ended whirl silently.

## Decision

**Both targets keep one contract.** Where AGNOS cannot meet it, the difference
is named in the table below and tracked until closed. A test enforces every
clause, and a change to the contract supersedes this ADR rather than editing it.

### Rules every call shares

- **Returns.** A count is `> 0`, and `0` has one stated meaning per call. Any
  negative value is an error, and a caller may test for only these:
  - **`_TAAR_ERR_TIMEOUT` (-11):** a receive or send deadline expired, on both
    targets.
  - **`_TAAR_ERR_INTR` (-4):** a signal interrupted a receive. This happens on
    Linux only; the AGNOS waits are polls and never return it.
  - **anything else `< 0`:** an error whose value is target-specific. Linux
    returns a negative errno; AGNOS mostly returns -1. Do not branch on these
    values.
- **Timeouts.** Each socket has its own timeout, in milliseconds.
  - `0` means no deadline, and a negative value is refused.
  - Both targets bound the receive and the send with it. A Linux connect is bound
    too; an AGNOS connect is not (see the differences table).
  - **The default is not part of the contract.** Linux starts with no deadline
    and AGNOS with 10 s. A caller that wants a bound sets one, and a caller that
    wants none sets `0`.
- **fds are opaque handles.** Their values differ by target:
  - **Linux:** kernel fds.
  - **AGNOS:** UDP listener ids 0–7, and TCP fds 64–71 from taar's own table.

  Pass an fd only to its own family's calls: `taar_udp_*` for UDP, and
  `taar_tcp_*` / `taar_sock_close` for TCP.
  - An fd taar has closed is an error on both targets.
  - Any other value is outside the contract. AGNOS refuses it, since it checks
    every fd against its tables; Linux acts on whatever kernel fd the value
    names.
- **No call raises a signal.** In particular, a send never raises SIGPIPE.
- **Not thread-safe.** Use taar from one thread of control per process: the AGNOS
  arm's tables are process-wide.
- **Resolving does not disturb the caller's sockets.** A `taar_resolve_ipv4`
  uses sockets of its own, and leaves every caller socket's connection,
  timeout, source port and peer as they were.

### Per function

| Call | Returns | Notes |
|---|---|---|
| `ipv4_parse(s)` | the packed address `(a<<24)\|(b<<16)\|(c<<8)\|d`, or `IPV4_PARSE_FAIL` (-1) | Strict dotted quad: four decimal octets 0–255, no leading zero (`0` is an octet; `00` and `010` are not), and no surrounding text. Pure. |
| `ipv4_format_to_buf(addr, buf)` | the text length | `buf` must hold 16 bytes. Writes the text and a NUL. Pure. |
| `taar_fill_sockaddr(sa, addr, port)` | 0 | Writes a 16-byte `sockaddr_in`. Pure. |
| `taar_udp_open()` | fd, or `< 0` | Close it with `taar_udp_close`. |
| `taar_udp_set_timeout_ms(fd, ms)` | 0, or `< 0` | Refuses a negative `ms` and a bad fd. |
| `taar_udp_send(fd, addr, port, p, n)` | `n`, or `< 0` | Records the peer. AGNOS returns `n`, not the kernel's frame length. |
| `taar_udp_recv(fd, buf, max)` | bytes `> 0`, `_TAAR_ERR_TIMEOUT`, `_TAAR_ERR_INTR` (Linux), or `< 0` | Returns only datagrams from the peer of this socket's last send. A longer datagram is cut to `max`. `max` must be `> 0`. |
| `taar_udp_close(fd)` | 0, or `< 0` | AGNOS also refuses a listener that taar did not open. |
| `taar_tcp_open()` | fd, or `< 0` | AGNOS refuses a ninth open socket. |
| `taar_tcp_set_timeout_ms(fd, ms)` | 0, or `< 0` | As for UDP. Set it before connecting, so the connect is bound where the target can bind it. |
| `taar_tcp_connect(fd, addr, port)` | 0, or `< 0` | A second connect on a connected socket is an error (Linux: -EISCONN). |
| `taar_tcp_send(fd, buf, n)` | bytes `> 0` (possibly fewer than `n`, so loop), `0` for `n == 0` on a live connection, `_TAAR_ERR_TIMEOUT` when nothing could be sent by the deadline, or `< 0` | Never raises SIGPIPE. A peer that has gone is `< 0` (Linux: -EPIPE, even for an empty send). |
| `taar_tcp_recv(fd, buf, max)` | bytes `> 0`, `0` (the peer closed, or `max == 0`), `_TAAR_ERR_TIMEOUT`, `_TAAR_ERR_INTR` (Linux), or `< 0` | `0` never means "timed out" or "no connection". |
| `taar_sock_close(fd)` | 0, or `< 0` | A second close is an error. |
| `taar_resolve_ipv4(host)` | the packed address (`0` is 0.0.0.0, so test `< 0`), or -1 | A literal returns at once. Otherwise up to three nameservers, `options timeout:` / `attempts:`, NXDOMAIN final, the reply-acceptance and owner-name rules, and the TCP retry on TC. The rules are `src/dns.cyr`'s and identical on both targets; only discovery differs (below). |

### Where the targets differ

| Area | Linux | AGNOS | Standing |
|---|---|---|---|
| Connect deadline | bound by the socket's timeout (`SO_SNDTIMEO`); expiry is -EINPROGRESS | the kernel's ~8 s, whatever was set | Open. agnos 1.57.18 has `SC_TIMED`; this waits on cyrius's `sys_sock_connect` peer (cyrius issue 2026-11-08). |
| Reset vs clean close | reset is -ECONNRESET | both read as `0` | Open. Waits on cyrius's epoll peer (issue 2026-11-04) and on agnos freeing epoll instances (agnos issue 2026-11-09). |
| Unread UDP datagrams | queued, up to `SO_RCVBUF` | one per listener; a later arrival overwrites it | Open. agnos issue 2026-11-09. Costs a slow or failed resolve, never a wrong answer. |
| Largest UDP datagram | 64 KB (the buffer bounds the read) | 1016 bytes (the kernel's cap) | Accepted. DNS without EDNS stays under 512 bytes. |
| UDP receive before any send | the socket has no local port yet | bound at open, so any sender is accepted | Unspecified: send first. |
| Default timeout | none | 10 s | Unspecified (see Rules). |
| Resolver discovery | `/etc/resolv.conf`; nothing configured → 127.0.0.1 | the DHCP-leased resolver, then resolv.conf; nothing → 8.8.8.8 | By design (0.8.2): AGNOS runs no local resolver. |
| `_TAAR_ERR_INTR` | possible from a receive | never | By design. The resolver retries it. |
| Send deadline on an old kernel | — | before agnos 1.57.13 (no `sock_send_dl#109`): the kernel's ~8 s | Documented. Run once by hand against 1.57.12. |
| Limits | `RLIMIT_NOFILE` | 8 TCP and 8 UDP sockets | Accepted (the kernel's tables). |

### How it is enforced

- **The Linux arm and the resolver rules:** `tests/taar.tcyr` (`cyrius test`, on
  x86_64 and, under qemu-user, aarch64), plus `tests/integration/tc_fallback.sh`
  and `tests/integration/resolver.sh`.
- **The AGNOS arm:** `tests/agnos/selftest.cyr`, booted on the pinned agnos
  release by `tests/agnos/run.sh`. Its check names map one to one onto the rules
  above: `lease:` / `udp:` / `tcp:` / `fd:` / `iso:` / `dns:`, and `kernel:` for
  the canaries of the kernel behaviour behind the open differences.
- **Mutation:** every guard behind a clause is mutation-checked, per CLAUDE.md.
- **The SIGPIPE clause:** enforced since 0.9.0, when the Linux `taar_tcp_send`
  moved to `sendto(…, MSG_NOSIGNAL)` and the `socket-send-timeout` group gained
  a send to a closed peer.

## Consequences

- **Positive.**
  - A consumer reads one table, not two arms, and can tell which behaviours are
    portable from which are accidents of a target.
  - The AGNOS harness tests a contract, not a snapshot.
  - Each open difference names what it waits on, so closing one is a checked
    edit to this ADR's table.
- **Negative.**
  - The contract now constrains the code: a change to any clause needs a new
    ADR and its tests, not just a doc-comment edit.
  - Leaving the default timeout and the error values unspecified means
    consumers may not lean on them, even where both targets happen to agree
    today.
- **Neutral.**
  - The open rows are the 0.7.x roadmap.
  - The public-surface review (0.9.x) reads this ADR to decide what to rename
    or deprecate before 1.0.

## Alternatives considered

- **Make AGNOS pretend to be POSIX.** That would mean a full errno space, an fd
  table shared with the kernel's VFS, and a blocking connect emulated with
  polling. Rejected for the reason yo's ADR 0001 gives: the shim has nothing true
  to say about a kernel without those objects. The cyrius stdlib's own AGNOS
  socket adapter was also evaluated for taar's TCP half at 0.7.1, and not
  adopted (CHANGELOG 0.7.1).
- **Two documented contracts, one per target.** Rejected because consumers would
  `#ifdef` on them. The point of taar is that whirl, dig and yo do not.
- **Specify the error values.** Linux can return many distinct errnos from these
  calls (ECONNREFUSED, ENETUNREACH, EPIPE, ECONNRESET, EBADF, …), and AGNOS
  mostly returns -1. Mapping every AGNOS failure to an invented
  errno is the POSIX shim above by another name. Only the two values a caller
  must act on differently, timeout and interrupt, are specified.
- **Specify a default timeout.** Making AGNOS block forever by default would
  match Linux, but a forgotten `set_timeout` would then hang an AGNOS tool where
  it hangs a Linux one today. Leaving it unspecified, and telling callers to set
  it, costs one line per socket and removes the question.
