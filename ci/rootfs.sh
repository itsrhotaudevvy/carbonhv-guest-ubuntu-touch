#!/usr/bin/env bash
# Turns the pinned Ubuntu Touch rootfs tarball into the ext4 image the bundle declares.
#
#   ci/rootfs.sh <url> <sha256> <size_mib> <out-dir>
#
# mkfs.ext4 -d populates the image from a directory, so this needs no root, no loop device and no
# mount: the same property that lets it run on a hosted runner also means a bug here cannot touch
# the runner's own filesystem.
set -euo pipefail

url="${1:-}"
expected="${2:-}"
size_mib="${3:-16384}"
out="${4:-out}"
[[ -n "$size_mib" && -n "$out" ]] || { echo "usage: rootfs.sh <url> <sha256> <size_mib> <out-dir>" >&2; exit 64; }

[[ -n "$url" && -n "$expected" ]] || {
  echo "rootfs: no pinned rootfs. Set the repository variables CARBONHV_UT_ROOTFS_URL and" >&2
  echo "rootfs: CARBONHV_UT_ROOTFS_SHA256 to the UBports tarball you intend to ship." >&2
  exit 4
}
for tool in mkfs.ext4 curl tar; do
  command -v "$tool" >/dev/null || { echo "rootfs: missing $tool" >&2; exit 4; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

echo "rootfs: downloading (this is the multi-hundred-megabyte step)"
curl --fail --location --retry 3 --retry-delay 5 --output "$work/rootfs.tar.$$" -- "$url"
actual="$(sha256sum "$work/rootfs.tar.$$" | awk '{print $1}')"
echo "rootfs: sha256 $actual"
[[ "$actual" == "$expected" ]] || { echo "rootfs: checksum mismatch, refusing to assemble" >&2; exit 5; }

mkdir "$work/tree"
tar -xf "$work/rootfs.tar.$$" -C "$work/tree" --numeric-owner
rm -f "$work/rootfs.tar.$$"

# The guest's own identity, so a running guest can say which image it is. Written into the image
# rather than into the tar, because the tar's hash is what the pin above covers.
cat >"$work/tree/etc/carbonhv-guest" <<EOF
id=ubuntu-touch
builder=carbonhv-guest-ubuntu-touch
rootfs_url=$url
rootfs_sha256=$expected
EOF

truncate -s "${size_mib}M" "$out/rootfs.img"
mkfs.ext4 -q -F -L carbonhv-rootfs -d "$work/tree" "$out/rootfs.img"
echo "rootfs: $out/rootfs.img ($(du -h "$out/rootfs.img" | awk '{print $1}') on disk, ${size_mib} MiB virtual)"
