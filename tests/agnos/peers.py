#!/usr/bin/env python3
"""Host-side socket peers for taar's AGNOS harness (tests/agnos/run.sh).

The AGNOS guest reaches these through QEMU's user-mode network, where the
host's 127.0.0.1 appears as 10.0.2.2. Every port below has one fixed
behaviour, and tests/agnos/selftest.cyr names the same numbers.

UDP
  7101  echo        replies with the datagram it got, from 7101
  7102  forged      a forged datagram from 7103 (same host, wrong port), then
                    one from FORGE_ADDR:7102 (right port, wrong host), then the
                    real echo from 7102, FORGE_GAP_S apart — the AGNOS kernel
                    keeps one unread datagram per port and a later arrival
                    replaces it, so back-to-back forgeries would collapse into
                    one and the guest would never see the first
  7104  slow echo   echoes after SLOW_S, so a short receive deadline expires
                    first and a long one (or none) collects the reply
  7105  burst       answers with two datagrams back to back, BURST_FIRST then
                    BURST_SECOND — a canary for that one-datagram slot
TCP
  7201  echo        reads once, echoes it, then closes (the client sees EOF)
  7202  silent      accepts and holds the connection open, never sending
  7203  refused     nothing listens; the connect is answered with a RST
  7204  blackhole   a full zero-length accept queue, so SYNs are dropped and
                    the connect never completes
  7205  sink        accepts with a small receive buffer and never reads, so
                    the guest's sends stop making progress
  7206  slow echo   reads once, echoes it after SLOW_S, then closes

FORGE_ADDR (192.0.2.1, TEST-NET-1) is added to this namespace's loopback by
run.sh. QEMU passes a reply from a host address other than 127.0.0.1 through
to the guest with its real source, so the guest sees a datagram from
192.0.2.1:7102 — the right port from the wrong host.

Run inside the harness's private network namespace; writes "ready" to fd 3
once every socket is bound.
"""
import os
import socket
import threading
import time

LO = "127.0.0.1"
FORGE_ADDR = "192.0.2.1"
FORGE_GAP_S = 0.05
SLOW_S = 0.4
BURST_FIRST = b"FIRST"
BURST_SECOND = b"SECOND-ONE"
SINK_RCVBUF = 4096

held = []                     # sockets kept alive for the run


def udp(port, addr=LO):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((addr, port))
    held.append(s)
    return s


def tcp_listener(port, backlog=8, rcvbuf=0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if rcvbuf:
        # Set before listen() so accepted sockets inherit it, and with it the
        # small window they advertise.
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.bind((LO, port))
    s.listen(backlog)
    held.append(s)
    return s


def forever(fn, *args):
    threading.Thread(target=fn, args=args, daemon=True).start()


def udp_echo(s):
    while True:
        data, addr = s.recvfrom(2048)
        s.sendto(data, addr)


def udp_forged(s, wrong_port, wrong_host):
    while True:
        data, addr = s.recvfrom(2048)
        wrong_port.sendto(b"FORGED-PORT", addr)
        time.sleep(FORGE_GAP_S)
        wrong_host.sendto(b"FORGED-HOST", addr)
        time.sleep(FORGE_GAP_S)
        s.sendto(data, addr)


def udp_slow(s):
    while True:
        data, addr = s.recvfrom(2048)
        threading.Timer(SLOW_S, s.sendto, (data, addr)).start()


def udp_burst(s):
    while True:
        _, addr = s.recvfrom(2048)
        s.sendto(BURST_FIRST, addr)
        s.sendto(BURST_SECOND, addr)


def tcp_echo(s):
    while True:
        conn, _ = s.accept()
        try:
            data = conn.recv(4096)
            if data:
                conn.sendall(data)
        finally:
            conn.close()


def tcp_slow_echo(s):
    while True:
        conn, _ = s.accept()
        data = conn.recv(4096)

        def reply(c=conn, d=data):
            try:
                if d:
                    c.sendall(d)
            finally:
                c.close()
        threading.Timer(SLOW_S, reply).start()


def tcp_silent(s):
    while True:
        conn, _ = s.accept()
        held.append(conn)


forever(udp_echo, udp(7101))
forever(udp_forged, udp(7102), udp(7103), udp(7102, FORGE_ADDR))
forever(udp_slow, udp(7104))
forever(udp_burst, udp(7105))
forever(tcp_echo, tcp_listener(7201))
forever(tcp_silent, tcp_listener(7202))
forever(tcp_silent, tcp_listener(7205, rcvbuf=SINK_RCVBUF))
forever(tcp_slow_echo, tcp_listener(7206))
# 7203: deliberately unbound.
blackhole = tcp_listener(7204, backlog=0)
held.append(socket.create_connection((LO, 7204)))    # fills the queue
os.write(3, b"ready\n")
threading.Event().wait()
