#!/usr/bin/env bash
# taar — DNS TC-fallback integration test.
#
# taar_resolve_ipv4 retries over TCP-53 when a reply sets the TC (truncated)
# bit. No live resolver can be made to truncate on demand, so this stands up a
# fake one on 127.0.0.53:53 that answers differently over UDP and TCP, and
# asserts which answer taar came back with.
#
# Port 53 needs CAP_NET_BIND_SERVICE and the host's real resolver already owns
# 127.0.0.53, so each case runs inside `unshare -rn` — a private network
# namespace where we hold the capability and the port is free. No root, no
# changes to /etc/resolv.conf.
#
#   cyrius build programs/resolve-smoke.cyr build/taar-resolve
#   tests/integration/tc_fallback.sh
#
# Not wired into CI yet — needs a check that `unshare -rn` is permitted on the
# runner. See docs/development/state.md carry-forward.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${1:-$HERE/../../build/taar-resolve}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$BIN" ] || { echo "missing $BIN — build programs/resolve-smoke.cyr first"; exit 2; }

run() {
    mode="$1"
    unshare -rn bash -c "
        set -u
        ip link set lo up
        python3 '$HERE/fake_dns.py' '$mode' 3>'$WORK/ready.$mode' &
        srv=\$!
        for _ in \$(seq 1 50); do [ -s '$WORK/ready.$mode' ] && break; sleep 0.1; done
        '$BIN'
        rc=\$?
        kill \$srv 2>/dev/null
        exit \$rc
    "
}

fail=0
check() {
    name="$1"; mode="$2"; want="$3"
    got="$(run "$mode" 2>/dev/null)"
    if [ "$got" = "$want" ]; then
        echo "  ok   $name (got $got)"
    else
        echo "  FAIL $name: expected $want, got '${got:-<nothing>}'"
        fail=1
    fi
}

echo "=== taar DNS TC-fallback ==="
check "TC=0: uses the UDP answer"                full      10.0.0.1
check "TC=1: retries over TCP"                   tc        10.11.12.13
check "TC=1 + no TCP: falls back, does not fail" tc_answer 10.0.0.1
check "TCP declares > client buffer: refused"    tc_huge   10.0.0.1
check "TCP declares sub-header length: refused"  tc_runt   10.0.0.1

[ $fail -eq 0 ] && echo "all cases passed" || echo "FAILURES"
exit $fail
