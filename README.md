# carbonhv-guest-ubuntu-touch

CI that builds the **Ubuntu Touch CVD1 guest**: a near-native ARM64 kernel, a small CVD1
initramfs, and a root filesystem image assembled by CarbonHV's `guest/ubuntu-touch/build.sh`.

Unlike the GrapheneOS-derived guest, this one fits a standard GitHub-hosted runner: it compiles a
kernel (tens of minutes, not hundreds of gigabytes) and assembles images from a pinned rootfs
tarball. That is the whole reason this repository can produce a bootable guest today.

The intended guest is the genuine Ubuntu Touch mobile session (Lomiri), not generic Ubuntu
desktop. Nothing here builds a desktop image.

## Pin what you consume, including the rootfs

The Ubuntu Touch rootfs is a multi-hundred-megabyte tarball published by UBports. This repository
does **not** hard-code a URL or a hash, because an invented hash is worse than none. Set two
repository variables once:

```
gh variable set CARBONHV_UT_ROOTFS_URL    --repo itsrhotaudevvy/carbonhv-guest-ubuntu-touch \
    --body 'https://…/ubports-touch-….tar.gz'
gh variable set CARBONHV_UT_ROOTFS_SHA256 --repo itsrhotaudevvy/carbonhv-guest-ubuntu-touch \
    --body '<sha256 of that file>'
```

Until both are set, the `rootfs` job fails with that instruction instead of assembling a bundle
whose provenance nobody can check. The kernel tarball is fetched from `cdn.kernel.org` together
with the release's own `sha256sums` file for the version being built.

## Jobs

| Job | What it proves |
| --- | --- |
| `kernel` | The ARM64 kernel builds with the CarbonHV near-native fragments merged, and the result **passes `carbonctl guest kernel-config`** (exit 0, or 5 for "boots but cannot use the near-native plan"). A kernel that fails the CVD1 contract stops the run there. |
| `rootfs` | The pinned rootfs tarball has the pinned hash, and becomes an ext4 image with the size the bundle declares. |
| `initramfs` | A minimal CVD1 initramfs built from a static busybox: mounts the rootfs by UUID, `switch_root`s into it. |
| `assemble` | CarbonHV's `guest/ubuntu-touch/build.sh` accepts all three inputs and writes `boot.img`, `rootfs.img`, `bundle.toml` with real hashes, and provenance. |

## Honest status

* Kernel and initramfs: buildable here today.
* Guest image: needs the two variables above. Until they exist, no Ubuntu Touch image is claimed.
* `CARBON_GRAPHENE_*`-style feature claims do not apply: this is a Linux guest with its own
  confinement story, and the differences are recorded in CarbonHV's support matrix, not here.
