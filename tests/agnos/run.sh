#!/usr/bin/env bash
# taar — AGNOS execution harness.
#
# Runs taar's AGNOS backend on the AGNOS kernel. Everything else in tests/
# runs the Linux arm of src/socket.cyr; this is the only place the
# `#ifdef CYRIUS_TARGET_AGNOS` arm executes.
#
#   1. Fetch the pinned agnos kernel and gnoboot UEFI loader (tests/agnos/
#      pins.sh), checking each against its pinned SHA-256. Cached in
#      build/agnos-harness/.
#   2. Build tests/agnos/selftest.cyr for AGNOS from this checkout, on every
#      run, and install it as /bin/agnsh on a scratch ext2 rootfs. The kernel
#      runs /bin/agnsh as its first program, so the selftest needs no shell
#      and no keystrokes.
#   3. Boot under QEMU + OVMF with user-mode networking, inside a private
#      user + network + mount namespace that holds the fake resolver
#      (tests/integration/fake_dns.py bylabel) and the socket peers
#      (tests/agnos/peers.py). QEMU forwards the guest's DNS to the
#      namespace's resolv.conf, which a bind mount points at the fake
#      resolver. No root, no real network, no change to the host.
#   4. Read the selftest's TAAR-AGNOS lines off the serial console.
#
#   tests/agnos/run.sh
#
# Exit 0: every check passed. 1: a check failed, the selftest did not finish,
# or a download failed its checksum. 2: VOID — a prerequisite is missing
# (tools, OVMF, unprivileged namespaces), so NOTHING WAS TESTED. A void is not
# a pass; CI treats it as a failure.
#
# Overrides, for testing an unreleased kernel or loader (printed loudly, since
# the result then says nothing about the pinned environment):
#   TAAR_AGNOS_KERNEL=<path>   TAAR_GNOBOOT_EFI=<path>
#   TAAR_AGNOS_TIMEOUT=<s>     wall-clock budget for the boot (default 180)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/pins.sh"
CACHE="$ROOT/build/agnos-harness"
BUDGET="${TAAR_AGNOS_TIMEOUT:-180}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

void() { echo "VOID: $* — nothing was tested"; exit 2; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== taar AGNOS harness ==="

for t in qemu-system-x86_64 parted sgdisk mformat mmd mcopy mkfs.ext2 python3 unshare ip curl sha256sum timeout; do
    command -v "$t" >/dev/null 2>&1 || void "missing tool '$t'"
done
OVMF_CODE=""; OVMF_VARS=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$c" ] && { OVMF_VARS="$c"; break; }
done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || void "OVMF firmware not found (edk2-ovmf / ovmf)"
# --pid --fork --kill-child: the namespace's shell is PID 1 of its own PID
# namespace, so when it exits — or `timeout` kills unshare — the kernel kills
# every server and QEMU inside it. Nothing can outlive a run.
NS="unshare -rnm --pid --fork --kill-child"
$NS true 2>/dev/null || void "unprivileged user+net+mount+pid namespaces are not permitted"

# fetch <repo> <version> <asset> <sha256> -> prints the cached path
fetch() {
    repo="$1"; ver="$2"; asset="$3"; want="$4"
    dest="$CACHE/$repo-$ver-$asset"
    mkdir -p "$CACHE"
    if [ ! -f "$dest" ] || [ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$want" ]; then
        url="https://github.com/MacCracken/$repo/releases/download/$ver/$asset"
        curl -sSfL --retry 3 -o "$dest.part" "$url" || { rm -f "$dest.part"; void "could not download $url"; }
        mv "$dest.part" "$dest"
    fi
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { rm -f "$dest"; fail "$repo $ver $asset sha256 $got, pinned $want"; }
    echo "$dest"
}

KLABEL="agnos $AGNOS_VERSION"
if [ -n "${TAAR_AGNOS_KERNEL:-}" ]; then
    KERNEL="$TAAR_AGNOS_KERNEL"
    KLABEL="override kernel $KERNEL"
    [ -f "$KERNEL" ] || void "TAAR_AGNOS_KERNEL=$KERNEL does not exist"
    echo "  kernel : OVERRIDE $KERNEL ($(sha256sum "$KERNEL" | cut -c1-16)…) — NOT the pinned agnos $AGNOS_VERSION"
else
    KERNEL="$(fetch agnos "$AGNOS_VERSION" "$AGNOS_ASSET" "$AGNOS_SHA256")" || exit $?
    echo "  kernel : agnos $AGNOS_VERSION (sha256 verified)"
fi
if [ -n "${TAAR_GNOBOOT_EFI:-}" ]; then
    LOADER="$TAAR_GNOBOOT_EFI"
    [ -f "$LOADER" ] || void "TAAR_GNOBOOT_EFI=$LOADER does not exist"
    echo "  loader : OVERRIDE $LOADER ($(sha256sum "$LOADER" | cut -c1-16)…) — NOT the pinned gnoboot $GNOBOOT_VERSION"
else
    LOADER="$(fetch gnoboot "$GNOBOOT_VERSION" "$GNOBOOT_ASSET" "$GNOBOOT_SHA256")" || exit $?
    echo "  loader : gnoboot $GNOBOOT_VERSION (sha256 verified)"
fi

# --- the selftest, from this checkout, every run ---
mkdir -p "$WORK/rootfs/bin"
(cd "$ROOT" && CYRIUS_TARGET_AGNOS=1 cyrius build --agnos tests/agnos/selftest.cyr "$WORK/rootfs/bin/agnsh") \
    >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; fail "could not build tests/agnos/selftest.cyr for AGNOS"; }
[ "$(head -c 4 "$WORK/rootfs/bin/agnsh" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] \
    || fail "selftest build is not an ELF"
chmod +x "$WORK/rootfs/bin/agnsh"
echo "  test   : tests/agnos/selftest.cyr -> /bin/agnsh ($(wc -c < "$WORK/rootfs/bin/agnsh") bytes)"

# --- disk: GPT, ESP (loader + kernel), ext2 rootfs (the selftest) ---
# The layout the agnos smokes use (agnos scripts/smoke/whirl-smoke.sh).
IMG="$WORK/disk.img"
dd if=/dev/zero of="$IMG" bs=1M count=128 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB \
    || fail "parted"
sgdisk -t 2:8300 "$IMG" >/dev/null || fail "sgdisk"
ESP="$IMG@@1048576"
mformat -i "$ESP" -F && mmd -i "$ESP" ::EFI ::EFI/BOOT ::boot \
    && mcopy -i "$ESP" "$LOADER" ::EFI/BOOT/BOOTX64.EFI && mcopy -i "$ESP" "$KERNEL" ::boot/agnos \
    || fail "could not populate the ESP"
mkfs.ext2 -F -q -L TAAR-AGNOS -b 4096 -m 0 -O "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg" \
    -d "$WORK/rootfs" -E offset=$((33 * 1048576)) "$IMG" $((95 * 1048576 / 4096)) || fail "mkfs.ext2"
cp "$OVMF_VARS" "$WORK/vars.fd" && chmod +w "$WORK/vars.fd"

ACCEL="-enable-kvm -cpu host"
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    ACCEL="-cpu max"            # TCG: slower, same result. `-cpu max` for SMEP/SMAP.
    echo "  accel  : TCG (no usable /dev/kvm)"
fi
printf 'nameserver 127.0.0.53\n' > "$WORK/resolv.conf"
SER="$WORK/serial.log"
: > "$SER"

echo "=== booting (budget ${BUDGET}s) ==="
start=$(date +%s)
timeout "$BUDGET" $NS bash -c '
    set -u
    W="$1"; HERE="$2"; ROOT="$3"; CODE="$4"; ACCEL="$5"
    mount --bind "$W/resolv.conf" /etc/resolv.conf || exit 90
    ip link set lo up && ip addr add 192.0.2.1/32 dev lo || exit 91
    # Output goes to files, so nothing here holds the caller'"'"'s pipe.
    python3 "$ROOT/tests/integration/fake_dns.py" bylabel 3>"$W/ready.dns" >"$W/dns.log" 2>&1 &
    python3 "$HERE/peers.py" 3>"$W/ready.peers" >"$W/peers.log" 2>&1 &
    for _ in $(seq 1 50); do
        [ -s "$W/ready.dns" ] && [ -s "$W/ready.peers" ] && break
        sleep 0.1
    done
    [ -s "$W/ready.dns" ] && [ -s "$W/ready.peers" ] || exit 92
    # shellcheck disable=SC2086
    qemu-system-x86_64 -machine q35 -m 512M $ACCEL \
        -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$W/disk.img,format=raw,if=none,id=disk0" -device nvme,drive=disk0,serial=TAAR-AGNOS \
        -netdev user,id=u1 -device virtio-net-pci,netdev=u1 \
        -serial "file:$W/serial.log" -display none -no-reboot -monitor none >"$W/qemu.log" 2>&1 &
    q=$!
    # The selftest powers the VM off after its DONE line. Stop early if the
    # kernel could not run it (kybernet falls back to its emergency shell).
    while kill -0 "$q" 2>/dev/null; do
        if grep -aq "TAAR-AGNOS DONE" "$W/serial.log"; then sleep 1; break; fi
        if grep -aq "kybernet: emergency shell" "$W/serial.log"; then break; fi
        sleep 0.2
    done
    kill "$q" 2>/dev/null
    wait "$q" 2>/dev/null
    exit 0
' _ "$WORK" "$HERE" "$ROOT" "$OVMF_CODE" "$ACCEL"
rc=$?
elapsed=$(( $(date +%s) - start ))
case $rc in
    0)   ;;
    90)  void "could not bind-mount resolv.conf in the namespace" ;;
    91)  void "could not configure the namespace loopback" ;;
    92)  fail "the fake resolver / socket peers did not start" ;;
    124) echo "  boot exceeded its ${BUDGET}s budget" ;;
    *)   echo "  namespace runner exited $rc" ;;
esac

# --- verdict ---
LINES="$(tr -d '\r' < "$SER" | grep -a '^TAAR-AGNOS ' || true)"
show_tail() { echo "  --- serial tail ---"; tr -d '\r' < "$SER" | grep -av '^TAAR-AGNOS ' | tail -15 | sed 's/^/    /'; }
if ! echo "$LINES" | grep -q '^TAAR-AGNOS begin'; then
    show_tail; fail "the selftest never ran (${elapsed}s)"
fi
echo "$LINES" | grep -E '^TAAR-AGNOS (ok|FAIL) ' | sed -e 's/^TAAR-AGNOS ok /  ok   /' -e 's/^TAAR-AGNOS FAIL /  FAIL /'
DONE="$(echo "$LINES" | grep '^TAAR-AGNOS DONE ' | tail -1)"
if [ -z "$DONE" ]; then
    show_tail; fail "the selftest did not finish (${elapsed}s)"
fi
pass="$(echo "$DONE" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')"
nfail="$(echo "$DONE" | sed -n 's/.*fail=\([0-9]*\).*/\1/p')"
seen_ok="$(echo "$LINES" | grep -c '^TAAR-AGNOS ok ')"
seen_fail="$(echo "$LINES" | grep -c '^TAAR-AGNOS FAIL ')"
# The counts are cross-checked so a lost serial line cannot hide a failure.
[ "$pass" = "$seen_ok" ] && [ "$nfail" = "$seen_fail" ] \
    || fail "DONE says pass=$pass fail=$nfail but the log shows $seen_ok ok / $seen_fail FAIL lines"
[ "$pass" -gt 0 ] || fail "no checks ran"
if [ "$nfail" -ne 0 ]; then
    fail "$nfail of $((pass + nfail)) AGNOS checks failed (${elapsed}s, $KLABEL)"
fi
echo "all $pass AGNOS checks passed (${elapsed}s, $KLABEL)"
exit 0
