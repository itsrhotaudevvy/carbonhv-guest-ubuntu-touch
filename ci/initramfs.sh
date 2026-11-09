#!/usr/bin/env bash
# Builds the CVD1 initramfs: a statically linked init and nothing else.
#
#   ci/initramfs.sh <out-dir>
#
# Needs an aarch64 cross compiler (`apt-get install gcc-aarch64-linux-gnu`) and cpio. The init is
# ci/init.c; it mounts the root filesystem the bootconfig names and execs /sbin/init, so the
# initramfs carries no shell and no busybox to get wrong.
set -euo pipefail

out="${1:?usage: initramfs.sh <out-dir>}"
here="$(cd "$(dirname "$0")" && pwd)"
cc="aarch64-linux-gnu-gcc"

command -v "$cc" >/dev/null || { echo "initramfs: missing $cc" >&2; exit 4; }
command -v cpio >/dev/null || { echo "initramfs: missing cpio" >&2; exit 4; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out" "$work/root"

"$cc" -static -Os -o "$work/root/init" "$here/init.c"
aarch64-linux-gnu-strip "$work/root/init" 2>/dev/null || true

( cd "$work/root" && find . -print0 | cpio --null --create --format=newc 2>/dev/null ) \
  | gzip -9 >"$out/cvd1-initramfs.cpio.gz"

bytes="$(wc -c <"$out/cvd1-initramfs.cpio.gz" | tr -d ' ')"
[[ "$bytes" -gt 1024 ]] || { echo "initramfs: output is only $bytes bytes" >&2; exit 5; }
echo "initramfs: $out/cvd1-initramfs.cpio.gz ($bytes bytes)"
