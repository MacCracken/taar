#!/usr/bin/env bash
# taar — resolver integration test (Linux): nameserver failover, resolv.conf
# options, which answers are final, and a resolve surviving a signal.
#
# Each case runs in a private user + network + mount + PID namespace with its
# own /etc/resolv.conf (a bind mount) and one or more fake nameservers
# (tests/integration/fake_dns.py) on 127.0.0.53, .54, ... — every one on the
# namespace's loopback, so nothing touches a real network and no root is
# needed. Each server logs the queries it receives, so a case can assert how
# many times a server was asked, not only what the client printed.
#
#   tests/integration/resolver.sh            # builds its own binary
#   tests/integration/resolver.sh <binary>   # or tests one you built
#
# The binary is programs/resolve-smoke.cyr: it prints the address and exits 0,
# or prints nothing and exits 1.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CASE_TIMEOUT=40

if [ $# -ge 1 ]; then
    BIN="$1"
else
    BIN="$WORK/taar-resolve"
    (cd "$HERE/../.." && cyrius build programs/resolve-smoke.cyr "$BIN") >"$WORK/build.log" 2>&1 \
        || { cat "$WORK/build.log"; echo "could not build programs/resolve-smoke.cyr"; exit 2; }
fi
[ -x "$BIN" ] || { echo "missing $BIN"; exit 2; }
unshare -rnm --pid --fork --kill-child true 2>/dev/null \
    || { echo "VOID: unprivileged user+net+mount+pid namespaces are not permitted — nothing was tested"; exit 2; }

# run <case-dir> <resolv.conf text> <signal?> <addr:mode>...
# Writes <case-dir>/out (what the client printed), /ms (its run time) and
# /q.<addr> (one line per query that server received).
run() {
    d="$1"; conf="$2"; sig="$3"; shift 3
    mkdir -p "$d"
    printf '%b' "$conf" > "$d/resolv.conf"
    timeout "$CASE_TIMEOUT" unshare -rnm --pid --fork --kill-child bash -c '
        set -u
        d="$1"; here="$2"; bin="$3"; sig="$4"; shift 4
        mount --bind "$d/resolv.conf" /etc/resolv.conf || exit 90
        ip link set lo up || exit 91
        for s in "$@"; do
            a="${s%%:*}"; m="${s#*:}"
            : > "$d/q.$a"
            python3 "$here/fake_dns.py" "$m" --addr "$a" --log "$d/q.$a" \
                3>"$d/ready.$a" >"$d/srv.$a.log" 2>&1 &
        done
        for s in "$@"; do
            a="${s%%:*}"
            for _ in $(seq 1 50); do [ -s "$d/ready.$a" ] && break; sleep 0.1; done
            [ -s "$d/ready.$a" ] || exit 92
        done
        t0=$(date +%s%N)
        if [ "$sig" = stopcont ]; then
            # Stop the client while it waits on the slow server, then let it
            # go. With SO_RCVTIMEO set, Linux fails the interrupted recvfrom
            # with EINTR rather than restarting it, even with no handler.
            "$bin" >"$d/out" 2>/dev/null &
            c=$!
            sleep 0.4; kill -STOP "$c"; sleep 0.3; kill -CONT "$c"
            wait "$c"
        else
            "$bin" >"$d/out" 2>/dev/null
        fi
        echo $(( ($(date +%s%N) - t0) / 1000000 )) > "$d/ms"
        exit 0
    ' _ "$d" "$HERE" "$BIN" "$sig" "$@"
    rc=$?
    [ $rc -eq 0 ] || echo "  (case runner exited $rc)"
}

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
got()     { cat "$1/out" 2>/dev/null; }
queries() { wc -l < "$1/q.$2" 2>/dev/null | tr -d ' ' || echo "?"; }
ids()     { sort -u "$1/q.$2" 2>/dev/null | wc -l | tr -d ' '; }
ms()      { cat "$1/ms" 2>/dev/null || echo 999999; }

# expect <name> <case-dir> <want-output> [<addr> <want-queries>]...
expect() {
    name="$1"; d="$2"; want="$3"; shift 3
    g="$(got "$d")"
    detail="got '${g:-<nothing>}'"
    good=1
    [ "$g" = "$want" ] || good=0
    while [ $# -ge 2 ]; do
        q="$(queries "$d" "$1")"
        detail="$detail, $1 asked $q"
        [ "$q" = "$2" ] || good=0
        shift 2
    done
    detail="$detail, $(ms "$d") ms"
    if [ $good -eq 1 ]; then ok "$name ($detail)"; else bad "$name: wanted '${want:-<nothing>}' — $detail"; fi
}

A=10.0.0.1                       # fake_dns.py's UDP answer
NS1=127.0.0.53; NS2=127.0.0.54; NS3=127.0.0.55; NS4=127.0.0.56

echo "=== taar resolver integration (Linux) ==="

run "$WORK/dead" "nameserver $NS2\nnameserver $NS1\n" - "$NS1:full"
expect "first server unreachable: the second answers" "$WORK/dead" "$A" "$NS1" 1

run "$WORK/silent" "nameserver $NS2\nnameserver $NS1\noptions timeout:1\n" - "$NS2:silent" "$NS1:full"
expect "first server silent: the second answers after its 1 s timeout" "$WORK/silent" "$A" "$NS2" 1 "$NS1" 1
[ "$(ms "$WORK/silent")" -ge 900 ] && [ "$(ms "$WORK/silent")" -lt 4000 ] \
    && ok "... and the wait was the configured timeout" || bad "silent-server wait was $(ms "$WORK/silent") ms, wanted ~1000"

run "$WORK/servfail" "nameserver $NS2\nnameserver $NS1\n" - "$NS2:servfail" "$NS1:full"
expect "SERVFAIL: the next server is asked" "$WORK/servfail" "$A" "$NS2" 1 "$NS1" 1

run "$WORK/refused" "nameserver $NS2\nnameserver $NS1\n" - "$NS2:refused" "$NS1:full"
expect "REFUSED: the next server is asked" "$WORK/refused" "$A" "$NS2" 1 "$NS1" 1

run "$WORK/nxdomain" "nameserver $NS2\nnameserver $NS1\n" - "$NS2:nxdomain" "$NS1:full"
expect "NXDOMAIN is final: no other server is asked" "$WORK/nxdomain" "" "$NS2" 1 "$NS1" 0

run "$WORK/attempts" "nameserver $NS2\noptions timeout:1 attempts:3\n" - "$NS2:silent"
expect "options attempts:3: three rounds, then failure" "$WORK/attempts" "" "$NS2" 3

run "$WORK/default" "nameserver $NS2\noptions timeout:1\n" - "$NS2:silent"
expect "default attempts: two rounds" "$WORK/default" "" "$NS2" 2
[ "$(ids "$WORK/default" "$NS2")" = 2 ] && ok "... each query with a fresh ID" \
    || bad "the two queries reused an ID: $(cat "$WORK/default/q.$NS2" | tr '\n' ' ')"

run "$WORK/rounds" "nameserver $NS2\nnameserver $NS3\noptions timeout:1\n" - "$NS2:silent" "$NS3:silent"
expect "each round asks every server" "$WORK/rounds" "" "$NS2" 2 "$NS3" 2

run "$WORK/maxns" "nameserver $NS2\nnameserver $NS3\nnameserver $NS4\nnameserver $NS1\n" - \
    "$NS2:servfail" "$NS3:servfail" "$NS4:servfail" "$NS1:full"
expect "only three nameservers are used" "$WORK/maxns" "" "$NS2" 2 "$NS1" 0

run "$WORK/unroutable" "nameserver 192.0.2.99\nnameserver $NS1\n" - "$NS1:full"
expect "first server unroutable (send fails): the second answers" "$WORK/unroutable" "$A" "$NS1" 1

run "$WORK/tcempty" "nameserver $NS2\nnameserver $NS1\n" - "$NS2:tc_empty" "$NS1:full"
expect "TC=1, no answer, TCP refused: the next server is asked" "$WORK/tcempty" "$A" "$NS2" 1 "$NS1" 1

run "$WORK/eintr" "nameserver $NS1\n" stopcont "$NS1:slow"
expect "a stop/continue mid-wait does not end the resolve (EINTR)" "$WORK/eintr" "$A" "$NS1" 1

# attempts:1, so a lost TCP read cannot be rescued by a second round.
run "$WORK/eintr_tcp" "nameserver $NS1\noptions attempts:1\n" stopcont "$NS1:tc_slow"
expect "... nor one during the TCP retry's read" "$WORK/eintr_tcp" "10.11.12.13" "$NS1" 1

# Answer validation (0.8.1): only records for the name asked, or its CNAME
# chain, are an answer.
run "$WORK/other_first" "nameserver $NS1\n" - "$NS1:other_first"
expect "an A for another name before the real one is skipped" "$WORK/other_first" "$A" "$NS1" 1

run "$WORK/other_only" "nameserver $NS1\nnameserver $NS2\n" - "$NS1:other_only" "$NS2:full"
expect "only an A for another name: no answer, and final" "$WORK/other_only" "" "$NS1" 1 "$NS2" 0

run "$WORK/cname" "nameserver $NS1\n" - "$NS1:cname"
expect "a CNAME chain is followed to its A" "$WORK/cname" "$A" "$NS1" 1

[ $fail -eq 0 ] && echo "all cases passed" || echo "FAILURES"
exit $fail
