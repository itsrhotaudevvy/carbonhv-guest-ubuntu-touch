#!/usr/bin/env bash
# Builds the CVD1 near-native ARM64 kernel for the Ubuntu Touch guest.
#
#   ci/kernel.sh <kernel-version> <out-dir>
#
# The configuration is not invented here: CarbonHV's fragments are merged with
# `carbonctl guest kernel-config`, which is the same contract check the phone-side plan uses, and
# the merged .config is then verified again after the build. A kernel that boots but cannot use the
# near-native plan exits 5 from that check and is recorded as such instead of being called verified.
set -euo pipefail

version="${1:?usage: kernel.sh <kernel-version> <out-dir> [family]}"
out="${2:?usage: kernel.sh <kernel-version> <out-dir> [family]}"
# The contract differs by family: Android requires SELinux in the image, Ubuntu Touch requires
# AppArmor. Checking a Ubuntu Touch kernel against the Android list fails for the wrong reason.
family="${3:-ubuntu-touch}"
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../carbonhv" && pwd)"

major="${version%%.*}"
url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${version}.tar.xz"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

echo "kernel: fetching $url"
curl --fail --location --retry 3 --output "$work/linux.tar.xz" -- "$url"

# Verify against the release's own checksums file, fetched over the same TLS connection. This is a
# transport-integrity check, not a signature check; signing keys are recorded in provenance.
echo "kernel: verifying against sha256sums"
curl --fail --location --retry 3 --output "$work/sums" -- \
  "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/sha256sums.asc"
expected="$(grep -E "linux-${version}\.tar\.xz$" "$work/sums" | awk '{print $1}')"
[[ -n "$expected" ]] || { echo "kernel: version $version is not listed in sha256sums.asc" >&2; exit 4; }
actual="$(sha256sum "$work/linux.tar.xz" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo "kernel: checksum mismatch" >&2; exit 4; }
echo "kernel: sha256 $actual"

tar -xf "$work/linux.tar.xz" -C "$work"
src="$work/linux-${version}"

# The CarbonHV CLI is the contract, so build it rather than trusting a version on PATH.
cargo build --release --manifest-path "$repo_root/crates/carbon-cli/Cargo.toml"
carbonctl="$repo_root/target/release/carbonctl"

echo "kernel: defconfig, then the CarbonHV fragments"
make -C "$src" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig >/dev/null

fragments=(
  "$repo_root/guest/common/kernel/cvd1-near-native.fragment"
  "$repo_root/guest/ubuntu-touch/device/kernel.fragment"
)
# The emulated-engine profile is optional until CarbonHV ships it.
[[ -f "$repo_root/guest/common/kernel/cvd1-emulated.fragment" ]] && \
  fragments+=("$repo_root/guest/common/kernel/cvd1-emulated.fragment")

for fragment in "${fragments[@]}"; do
  [[ -f "$fragment" ]] || { echo "kernel: missing fragment $fragment" >&2; exit 4; }
  # Fragment lines are CONFIG_X=y, CONFIG_X=<value> or "# CONFIG_X is not set".
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#\ *[!n]* ]] && continue
    if [[ "$line" == "# CONFIG_"*" is not set" ]]; then
      symbol="${line#\# CONFIG_}"; symbol="${symbol%% is not set}"
      "$src/scripts/config" --file "$src/.config" --disable "$symbol"
    elif [[ "$line" == CONFIG_*=* ]]; then
      symbol="${line#CONFIG_}"; symbol="${symbol%%=*}"; value="${line#*=}"
      case "$value" in
        y|m) "$src/scripts/config" --file "$src/.config" --enable "$symbol" ;;
        n)   "$src/scripts/config" --file "$src/.config" --disable "$symbol" ;;
        *)   "$src/scripts/config" --file "$src/.config" --set-val "$symbol" "$value" ;;
      esac
    fi
  done <"$fragment"
done
make -C "$src" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig >/dev/null

echo "kernel: checking the CVD1 kernel contract with carbonctl"
set +e
"$carbonctl" guest kernel-config "$family" "$src/.config" "${fragments[@]}" >"$work/contract.txt" 2>&1
contract=$?
set -e
cat "$work/contract.txt"
case "$contract" in
  0) echo "kernel: contract verified (near-native)" ;;
  5) echo "kernel: contract boots but cannot use the near-native plan (exit 5), recorded as such" ;;
  *) echo "kernel: contract failed with exit $contract; refusing to publish this kernel" >&2; exit "$contract" ;;
esac

echo "kernel: building Image"
make -C "$src" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image modules

install -m0644 "$src/arch/arm64/boot/Image" "$out/Image"
install -m0644 "$src/.config" "$out/kernel.config"
echo "kernel: contract_exit=$contract" >"$out/kernel.env"
echo "kernel: version=$version" >>"$out/kernel.env"
echo "kernel: sha256=$actual" >>"$out/kernel.env"
cat "$out/kernel.env"
