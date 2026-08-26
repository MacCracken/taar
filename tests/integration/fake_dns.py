#!/usr/bin/env python3
"""Minimal DNS responder for taar's TC-fallback integration test.

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

Binds 127.0.0.53:53 so an unmodified /etc/resolv.conf points at it. Port 53
needs CAP_NET_BIND_SERVICE, so run this inside `unshare -rn` (see run.sh).
"""
import os
import socket
import struct
import sys
import threading

UDP_IP = "10.0.0.1"
TCP_IP = "10.11.12.13"

MODE = sys.argv[1]
TRUNCATE = MODE.startswith("tc")
KEEP_ANSWER = MODE != "tc"          # only plain "tc" drops the answer entirely
SERVE_TCP = MODE != "tc_answer"     # tc_answer proves the no-TCP fallback
# Deliberately lie about the framed length to exercise the client's bounds checks.
BAD_LEN = {"tc_huge": 60000, "tc_runt": 4}.get(MODE)


def build(qid, question, ip, tc):
    flags = 0x8180 | (0x0200 if tc else 0)      # QR|RD|RA, optionally TC
    keep = (not tc) or KEEP_ANSWER
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


def serve_udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.53", 53))
    while True:
        data, addr = s.recvfrom(2048)
        qid, q = parse(data)
        s.sendto(build(qid, q, UDP_IP, TRUNCATE), addr)


def serve_tcp():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.53", 53))
    s.listen(8)
    while True:
        conn, _ = s.accept()
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
            resp = build(qid, q, TCP_IP, False)
            declared = BAD_LEN if BAD_LEN is not None else len(resp)
            if MODE == "tc_huge":
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


threading.Thread(target=serve_udp, daemon=True).start()
if SERVE_TCP:
    threading.Thread(target=serve_tcp, daemon=True).start()
os.write(3, b"ready\n")             # fd 3 handshake: the harness waits on this
threading.Event().wait()
