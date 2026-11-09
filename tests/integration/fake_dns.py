#!/usr/bin/env python3
"""Minimal DNS responder for taar's integration tests.

Answers exactly one A question, and deliberately answers it *differently*
over UDP and TCP so the harness can tell which transport the client believed.

Modes (argv[1]):
  full       UDP replies with TC=0 and the answer      -> client must use UDP_IP
  tc         UDP replies with TC=1 and no answer;
             TCP serves the full answer                -> client must use TCP_IP
  tc_answer  UDP replies with TC=1 but still carries a
             usable answer; NO TCP listener at all     -> client must fall back
                                                          to UDP_IP, not fail
  tc_huge    as tc_answer, but TCP declares a length
             far larger than the client's buffer       -> client must refuse the
                                                          frame and fall back
  tc_runt    as tc_answer, but TCP declares a length
             shorter than a DNS header                 -> client must refuse the
                                                          frame and fall back
  tc_blackhole
             as tc_answer, but the TCP listener's accept
             queue is full, so the kernel drops the
             client's SYNs and connect() never completes -> client must give
                                                          up within its TCP
                                                          timeout and fall back
                                                          (an unbounded connect
                                                          waits out ~127 s of
                                                          SYN retries)
  spoof      before the real UDP reply, a forged one
             (right ID, right question, SPOOF_IP) from
             the same address but port SPOOF_PORT      -> client must ignore the
                                                          forgery and use UDP_IP
  servfail   UDP replies SERVFAIL (rcode 2), no answer  -> client must ask its
                                                          next nameserver
  refused    UDP replies REFUSED (rcode 5), no answer   -> likewise
  nxdomain   UDP replies NXDOMAIN (rcode 3)             -> client must stop: the
                                                          name does not exist,
                                                          and no other server is
                                                          asked
  silent     UDP bound, never replies                   -> client must give up on
                                                          this server at its
                                                          timeout
  slow       as full, but the reply waits SLOW_S        -> lets the harness stop
                                                          and continue the client
                                                          mid-wait
  tc_slow    as tc, but the TCP reply waits SLOW_S      -> the same, during the
                                                          TCP retry's read
  tc_empty   UDP replies TC=1 with no answer, and no
             TCP listener                               -> this server said
                                                          nothing usable: client
                                                          must ask the next one
  bylabel    every mode above but tc_blackhole at once: each query's first
             label names its mode ("tc_huge.taar.test" behaves as tc_huge).
             One TCP listener serves them all, so the no-listener modes
             (tc_answer) are approximated by accepting and closing without a
             reply — still a TCP retry that fails after connect. Used by the
             AGNOS harness (tests/agnos/run.sh), which boots once for every
             case instead of once per mode.

Binds 127.0.0.53:53 so an unmodified /etc/resolv.conf points at it, or
`--addr A` to bind another loopback address (several servers at once, for
tests/integration/resolver.sh). `--log F` appends one line to F per UDP query
received ("query <id>", the query ID in hex), so a harness can count what was
asked and check that each query carried a fresh ID. Port 53 needs
CAP_NET_BIND_SERVICE, so run this inside `unshare -rn` (see tc_fallback.sh).
"""
import os
import socket
import struct
import sys
import threading
import time

UDP_IP = "10.0.0.1"
TCP_IP = "10.11.12.13"
SPOOF_IP = "10.6.6.6"
ADDR = "127.0.0.53"
SPOOF_PORT = 5353
SPOOF_LEAD_S = 0.05           # how far the forgery runs ahead of the real reply
SLOW_S = 1.5                  # the slow mode's reply delay

# What each mode does. tc: set TC on the UDP reply. keep: the UDP reply still
# carries the answer. tcp: "serve" | "none" (no listener) | "blackhole".
# bad_len: lie about the TCP frame length. spoof: forge a UDP reply first.
MODES = {
    "full":         dict(tc=False, keep=True,  tcp="serve"),
    "tc":           dict(tc=True,  keep=False, tcp="serve"),
    "tc_answer":    dict(tc=True,  keep=True,  tcp="none"),
    "tc_huge":      dict(tc=True,  keep=True,  tcp="serve", bad_len=60000),
    "tc_runt":      dict(tc=True,  keep=True,  tcp="serve", bad_len=4),
    "tc_blackhole": dict(tc=True,  keep=True,  tcp="blackhole"),
    "spoof":        dict(tc=False, keep=True,  tcp="serve", spoof=True),
    "servfail":     dict(tc=False, keep=False, tcp="none", rcode=2),
    "refused":      dict(tc=False, keep=False, tcp="none", rcode=5),
    "nxdomain":     dict(tc=False, keep=False, tcp="none", rcode=3),
    "silent":       dict(tc=False, keep=False, tcp="none", silent=True),
    "slow":         dict(tc=False, keep=True,  tcp="none", delay=SLOW_S),
    "tc_slow":      dict(tc=True,  keep=False, tcp="serve", tcp_delay=SLOW_S),
    "tc_empty":     dict(tc=True,  keep=False, tcp="none"),
}

MODE = sys.argv[1]
LOG = None
_args = sys.argv[2:]
while _args:
    if _args[0] == "--addr" and len(_args) > 1:
        ADDR = _args[1]
    elif _args[0] == "--log" and len(_args) > 1:
        LOG = _args[1]
    else:
        sys.exit("fake_dns: bad argument " + _args[0])
    _args = _args[2:]
BYLABEL = MODE == "bylabel"
if not BYLABEL and MODE not in MODES:
    sys.exit("fake_dns: unknown mode " + MODE)


def build(qid, question, ip, tc, keep, rcode=0):
    flags = 0x8180 | (0x0200 if tc else 0) | rcode      # QR|RD|RA, optionally TC
    hdr = struct.pack("!HHHHHH", qid, flags, 1, 1 if keep else 0, 0, 0)
    body = question
    if keep:
        body += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4)
        body += bytes(int(o) for o in ip.split("."))
    return hdr + body


def parse(msg):
    """Return (id, question-section-bytes) — taar echo-compares the latter."""
    qid = struct.unpack("!H", msg[:2])[0]
    i = 12
    while msg[i] != 0:
        i += 1 + msg[i]
    i += 1
    return qid, msg[12:i + 4]


def behaviour(question):
    """The mode dict for this question, or None for an unknown label."""
    if not BYLABEL:
        return MODES[MODE]
    label = question[1:1 + question[0]].decode("ascii", "replace")
    if label == "tc_blackhole":          # needs its own listener; not served here
        return None
    return MODES.get(label)


def serve_udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((ADDR, 53))
    forger = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    forger.bind((ADDR, SPOOF_PORT))
    while True:
        data, addr = s.recvfrom(2048)
        qid, q = parse(data)
        if LOG:
            with open(LOG, "a") as f:
                f.write("query %04x\n" % qid)
        b = behaviour(q)
        if b is None:
            s.sendto(build(qid, q, UDP_IP, False, False, rcode=5), addr)   # REFUSED
            continue
        if b.get("silent"):
            continue
        if b.get("rcode"):
            s.sendto(build(qid, q, UDP_IP, False, False, rcode=b["rcode"]), addr)
            continue
        if b.get("delay"):
            keep = (not b["tc"]) or b["keep"]
            reply = build(qid, q, UDP_IP, b["tc"], keep)
            threading.Timer(b["delay"], s.sendto, (reply, addr)).start()
            continue
        if b.get("spoof"):
            forger.sendto(build(qid, q, SPOOF_IP, False, True), addr)
            time.sleep(SPOOF_LEAD_S)
        keep = (not b["tc"]) or b["keep"]
        s.sendto(build(qid, q, UDP_IP, b["tc"], keep), addr)


def serve_tcp_conn(conn):
    try:
        # RFC 1035 4.2.2: 2-byte big-endian length prefix each way.
        n = struct.unpack("!H", conn.recv(2))[0]
        data = b""
        while len(data) < n:
            chunk = conn.recv(n - len(data))
            if not chunk:
                return
            data += chunk
        qid, q = parse(data)
        b = behaviour(q)
        if b is None or b["tcp"] != "serve":
            return                       # bylabel's stand-in for "no listener"
        resp = build(qid, q, TCP_IP, False, True)
        if b.get("tcp_delay"):
            time.sleep(b["tcp_delay"])
        bad_len = b.get("bad_len")
        declared = bad_len if bad_len is not None else len(resp)
        if bad_len is not None and declared > len(resp):
            # Actually deliver every byte we claimed. A client that trusts
            # the declared length without checking it against its own
            # buffer writes all of this into a 2KB stack array. Declaring
            # a large size but sending little would let a short read save
            # the client by accident, which is not the property under test.
            resp = resp + b"\x00" * (declared - len(resp))
        try:
            conn.sendall(struct.pack("!H", declared) + resp)
        except (BrokenPipeError, ConnectionResetError):
            # Expected in the passing case: the client refuses the frame
            # on the length alone and closes before we finish writing.
            pass
    finally:
        conn.close()


def serve_tcp():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ADDR, 53))
    s.listen(8)
    while True:
        conn, _ = s.accept()
        serve_tcp_conn(conn)


def blackhole_tcp():
    """A listener that is never accepted from, with a zero-length accept queue
    that one connection of our own fills. Linux drops any further SYN while the
    queue is full (tcp_abort_on_overflow=0, the default), so the client sees no
    SYN-ACK and no RST — exactly a filtered TCP/53."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ADDR, 53))
    s.listen(0)
    filler = socket.create_connection((ADDR, 53))
    return s, filler


threading.Thread(target=serve_udp, daemon=True).start()
TCP = "serve" if BYLABEL else MODES[MODE]["tcp"]
if TCP == "serve":
    threading.Thread(target=serve_tcp, daemon=True).start()
elif TCP == "blackhole":
    _held = blackhole_tcp()          # keep both sockets alive for the run
os.write(3, b"ready\n")             # fd 3 handshake: the harness waits on this
threading.Event().wait()
