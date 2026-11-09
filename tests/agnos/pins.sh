# Pinned AGNOS boot chain for tests/agnos/run.sh — sourced, not executed.
#
# The kernel and the UEFI loader are taken from their projects' GitHub
# releases at these exact versions, and each download must match the SHA-256
# below. The hashes are pinned here rather than read from the release's own
# SHA256SUMS, so a re-uploaded asset cannot quietly change what taar is tested
# against. A new kernel is a new test environment: bump deliberately, run the
# harness, and say so in the CHANGELOG.
#
# Both assets are reproducible builds: at these versions they are
# byte-identical to `scripts/build.sh` in ../agnos and the build in ../gnoboot.

AGNOS_VERSION=1.57.19
AGNOS_ASSET=agnos-x86_64
AGNOS_SHA256=29c4daef3731e439a63edfcf9504af0b1e900aadbe4ad213e98b4b822f4d13d2

GNOBOOT_VERSION=0.9.0
GNOBOOT_ASSET=BOOTX64.EFI
GNOBOOT_SHA256=76999a8255768d5c4cd6ad6fee899f0dee681f1f82c34ef320002ac05a5f8cda
