# Notice

This repository combines files under different licenses.

- **Scripts and documentation** of this repository (`scripts/`, `docker/`, `README.md`,
  `NOTICE.md`, `tree-overrides/README`, `manifests/`): Apache License 2.0, see `LICENSE`.
- **Device tree** (`device/gts210ltexx/`): Apache License 2.0. The files keep their original
  headers; the tree is based on the T815 work of Jan Huijsmans and Christopher N. Hesse (see
  `device/gts210ltexx/README`).
- **Kernel patches** (`patches/kernel/`) and the kernel configuration (`kernel/`): GPL-2.0, as
  they modify the Linux kernel. Kernel patch 0001 is by Dominggoes Isakh and keeps its author.
- **AOSP / LineageOS patches** (`patches/art`, `patches/bionic`, `patches/frameworks_base`,
  `patches/frameworks_native`, `patches/system_core`, `patches/gts2-common`): Apache License 2.0,
  the license of the projects they modify.
- **Prebuilt APKs** are not part of this repository. `scripts/fetch-prebuilts.sh` downloads them
  from upstream, where they are distributed under their own licenses: Aurora Store under
  GPL-3.0, microG GmsCore under Apache License 2.0.
- **Samsung proprietary files** are in the separate repository
  `proprietary_vendor_samsung_gts210ltexx` and are not covered by any license of this
  repository.
