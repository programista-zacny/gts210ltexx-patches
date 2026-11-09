# LineageOS 24.0 (Android 17) for the SM-T815

Samsung Galaxy Tab S2 9.7 LTE (SM-T815, codename `gts210ltexx`, Exynos 5433, 32-bit ARM),
built **Wi-Fi only** (no modem/RIL), with microG, F-Droid and Aurora Store.

This repository is an overlay on top of [rINanDO's gts210wifi work](https://github.com/rINanDO/gts210wifi-patches):
the T815 device tree, a set of kernel and Android patches, the kernel defconfig and the build
scripts. It does not contain Samsung's proprietary files (they are in
[proprietary_vendor_samsung_gts210ltexx](https://github.com/programista-zacny/proprietary_vendor_samsung_gts210ltexx))
or any APK (they are downloaded and verified by `scripts/fetch-prebuilts.sh`).

The state of this branch is **build 17** (2026-11-09), the build that was tested on the owner's
tablet.

## Status

### Verified on hardware

- Boot, display, touch, Wi-Fi.
- Bluetooth, including A2DP audio.
- Camera: photos, and video recording (fixed in build 10 by kernel patch 0025, OFD locks).
- Sensors.
- Fingerprint reader (enrolment and unlock).
- Deep sleep: about 1% battery drain overnight.
- App freezer (cgroup v1 freezer with binder freeze support) and cpusets (top-app and
  foreground on all eight cores, background and restricted on the four little cores).
- microG Services 0.3.16.1, F-Droid, Aurora Store (an existing login through microG keeps
  working; see the microG note under "Build").
- Hardware video decoding: H.264/AVC, HEVC, VP8 and MPEG-4 (since build 11). YouTube plays
  1080p through the hardware AVC decoder. The Exynos 5433 has no VP9 hardware.
- Lineage Recovery with USB: adb and ADB sideload (since build 17; the 3.10 kernel only has the
  legacy android_usb gadget, see `device/gts210ltexx/rootdir/etc/init.recovery.universal5433.rc`).
- OTA updates through the LineageOS Updater (Settings > System > Updater), served from this
  repository's GitHub Releases (since build 17).
- Hardware composer overlays (GSC) without leaking memory (since build 13). Before, every
  video-overlay session leaked three full-screen buffers (about 38 MB); after hours of video the
  tablet ran out of RAM and the launcher crashed. Verified over 20 h with 36 video sessions.
- Widevine L3 playback: Prime Video and HBO Max play in SD. Since build 11 the ART heap is
  capped at 384m; with the default 512m Prime Video aborted at playback start (see "Known
  limitations").
- SELinux enforcing.

### Not yet verified

- GPS (the GPS daemon starts and uses the motion sensors; a position fix has not been tested).
- Wired headset and microphone (the owner has no 3.5 mm headset).
- Wi-Fi hotspot.

### Not working, or not tested

- LTE, SMS, calls: not built. This is a Wi-Fi only build; there is no RIL.
- Widevine L1 (HD playback). The L1 CDM initialises and provisions, and the secure AVC decoder
  opens the secure MFC node, but decryption into it fails ("Invalid secure handle" in
  Samsung's liboemcrypto: the OMX component has no native-handle secure buffers). The HEVC IP
  has no secure path at all, and Prime Video serves HD as HEVC. The secure decoder is hidden
  from apps. Prime Video still opens an L1 session first and falls back by itself; once in a
  while playback needs a second tap. Even with L1, Netflix would stay at SD (the Tab S2 was
  never Netflix-certified).
- Hardware video encoders: not enabled yet (camera recording uses the software encoder).

## Known limitations

- **32-bit userspace.** Samsung's signed boot chain starts the kernel in 32-bit mode, so the
  whole system is armv7. Apps that ship only 64-bit code do not install.
- **Linux 3.10.108 with targeted backports.** The kernel is Samsung's 3.10 tree (rINanDO's
  fork) with the patches listed below. There is no eBPF, no cgroup v2, no PSI and no
  userfaultfd; rINanDO's patches make Android 17 run without them. ART uses the concurrent
  copying collector, which in a 32-bit process reserves twice the maximum heap in address space
  (hence the Prime Video issue above).
- **GPU capped at 550 MHz, on purpose.** Samsung's Mali platform code limits the big CPU cluster
  to 1.3 GHz whenever the GPU runs at 600 MHz or more. Measured on this tablet, keeping the GPU
  at or below 550 MHz was never worse for scrolling and animations and was better wherever the
  power HAL had held a 600 MHz minimum. The 600/700 MHz steps would mainly help games, which are
  not a goal of this build (gts2-common patch 0009).
- Builds are `userdebug` with adb secured, as official LineageOS: the computer must be
  authorized on the tablet. Unlike official builds `ro.debuggable` stays 1, so "Rooted debugging"
  (off by default) is available in Developer options for diagnosis (patches/vendor_lineage/0001,
  `LINEAGE_KEEP_DEBUGGABLE_IN_USERDEBUG`). `WITH_ADB_INSECURE=true` builds open root adb without
  authorization for bring-up only and must never be published.
- Builds are signed with the public LineageOS test keys unless you build with your own keys
  (see "Own signing keys").

## Build

You need a Linux host with `repo`, `git`, `git-lfs` and Docker, and the disk space and memory
LineageOS usually needs. Soong's analysis phase needs a lot of memory: build 10 ran with
`BUILD_JOBS=8` on 30 GB of RAM plus 16 GB of swap; 20 jobs ran out of memory. The kernel is built with the GCC 4.9 prebuilts that rINanDO's manifest adds.

The layout below keeps everything in one directory: this repository, with the LineageOS tree
in `lineage/`, rINanDO's patches in `patches-rinando/` and the Samsung blobs in
`vendor/gts210ltexx/`. All four paths are ignored by git. The scripts find the project root from
their own location; `GTS_ROOT`, `LINEAGE_ROOT` and `VENDOR_BLOBS` override the defaults.

```bash
git clone -b lineage-24.0 https://github.com/programista-zacny/gts210ltexx-patches gts210ltexx
cd gts210ltexx
```

1. **Initialise the LineageOS 24.0 tree.**

   ```bash
   mkdir lineage && cd lineage
   repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs
   ```

2. **Add rINanDO's local manifest and ours.**

   ```bash
   git clone https://github.com/rINanDO/gts210wifi-patches ../patches-rinando
   mkdir -p .repo/local_manifests
   cp ../patches-rinando/LOS-24.0/exynos5433-24.0.xml .repo/local_manifests/
   cp ../manifests/gts210ltexx-extra.xml .repo/local_manifests/
   ```

   Do not use rINanDO's `setup.sh`: its cleanup step moves away local manifests of other
   devices, which includes ours.

3. **Sync.**

   ```bash
   repo sync -c -j8 --force-sync
   ```

   To get exactly the sources of build 10 instead of the current branch heads, use
   `manifests/build10-pinned.xml` (see "Pinned manifest").

4. **Apply rINanDO's patch series** (28 repositories, applied with `git am`).

   rINanDO's `android_vendor_lineage/0002-BoardConfigKernel-Preserve-device-kernel-flags…` no
   longer applies to lineage-24.0 (upstream "kernel: Kill RBE support" changed its context), and
   the patch is needed: it keeps the GCC make flags of the 3.10 kernel. `rinando-fixes/` holds
   the same patch rebased on lineage-24.0; copy it over rINanDO's file **before** `apply.sh`:

   ```bash
   cp -r ../rinando-fixes/LOS-24.0/. ../patches-rinando/LOS-24.0/
   ../patches-rinando/LOS-24.0/apply.sh
   cd ..
   ```

5. **Clone the Samsung blobs.**

   ```bash
   git clone -b lineage-24.0 https://github.com/programista-zacny/proprietary_vendor_samsung_gts210ltexx vendor/gts210ltexx
   ```

   `scripts/prepare-tree.sh` copies this directory (without its `.git`) to
   `lineage/vendor/samsung/gts210ltexx`. The copy sits inside rINanDO's `vendor/samsung`
   checkout, so a nested repo project in the manifest would put one git repository inside
   another; a plain copy avoids that. Set `VENDOR_BLOBS=/some/other/path` to keep the blobs
   elsewhere.

6. **Download the prebuilt APKs.**

   ```bash
   scripts/fetch-prebuilts.sh
   ```

   Downloads Aurora Store 4.8.4 from F-Droid and microG GmsCore 0.3.16.1.252432 from microG's
   GitHub releases, checks their sha256 and, with the apksigner from the synced tree, their
   signer certificates. GmsCore 0.3.16.1 (0.3.16 with the security fixes of 2026-09-29) replaces
   the 0.3.17 that `vendor/partner_gms` pins. Note: Aurora Store's first login through microG
   can hang in both 0.3.17 and 0.3.16.1
   ([microg/GmsCore#3853](https://github.com/microg/GmsCore/issues/3853), fixed upstream but not
   released yet); an existing login keeps working. See `tree-overrides/README`.

7. **Prepare the tree.**

   ```bash
   scripts/prepare-tree.sh
   ```

   Copies the device tree, the blobs and the kernel defconfig into `lineage/`, applies
   `patches/<name>/*.patch` to the repository named in `patches/<name>/TARGET`, and copies
   `tree-overrides/`. It is safe to re-run: applied patches are reported as "already applied".
   `scripts/build.sh` runs it again before every build.

8. **Build in Docker.**

   ```bash
   docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t gts210ltexx-build:latest docker
   scripts/docker-run.sh scripts/build.sh
   ```

   The result is `lineage/out/target/product/gts210ltexx/lineage-24.0-<date>-UNOFFICIAL-gts210ltexx.zip`.
   For a bring-up build with open root adb (never publish it):
   `scripts/docker-run.sh env WITH_ADB_INSECURE=true scripts/build.sh`.
   Soong's analysis after a makefile change needs more memory than 30 GB of RAM;
   `scripts/swap-on.sh` adds a 16 GB swap file in its own btrfs subvolume (snapshots of `/`
   would make a swap file next to them unusable).
   `BUILD_JOBS=N` changes the number of jobs (default 12).

`scripts/device-check.sh` is a read-only health check of a flashed tablet over adb (services,
crashes, SELinux, suspend, cpusets, freezer, kernel features); it writes filtered logs to
`logs/`.

### Own signing keys

By default the build is signed with the public test keys. To sign with your own keys:

1. Generate a key set as described in LineageOS's
   [Signing builds](https://wiki.lineageos.org/signing_builds) guide (the keys and the
   `keys.mk` for `vendor/lineage-priv/keys`).
2. Put that directory at `keys/` in this checkout. It must contain `keys.mk` and
   `testkey.pk8`/`testkey.x509.pem` (the OTA key) besides the other key pairs. `keys/` is ignored
   by git; never commit it.
3. Build with `OWN_KEYS=1 scripts/docker-run.sh scripts/build.sh`. `prepare-tree.sh` installs
   `keys/` as `vendor/lineage-priv/keys`; without `OWN_KEYS` it removes that copy again.
4. `scripts/check-own-keys.sh` checks afterwards that the image, its APKs and APEXes and the
   OTA package are signed with the keys in `keys/` (the presigned microG, F-Droid and Aurora
   Store APKs excepted).

Moving between test-key and own-key builds needs a data wipe.

### Pinned manifest

`manifests/build10-pinned.xml` records the exact revision of every project in the tree that
produced build 10; builds 11 and 12 used the same sources (only this repository changed). It is
for reproducibility and for GPL source correspondence (the kernel source of a build is
rINanDO's kernel fork at the recorded revision plus `patches/kernel/` and
`kernel/lineage_gts210ltexx_defconfig`). For the 28 projects that rINanDO's `apply.sh` patches,
it records the upstream commit the series is applied to. It already contains the local
manifests, so after step 1 clone rINanDO's patches as in step 2 but do not copy the local
manifests; instead:

```bash
cp ../manifests/build10-pinned.xml .repo/manifests/
repo init -m build10-pinned.xml
repo sync -c -j8 --force-sync
```

Then continue with step 4, with rINanDO's patches at the revision build 10 used:
`git -C patches-rinando checkout cc3b029d2f501c37f2d55643ac373cfacaa67b12`.

## Flashing

- Recommended recovery: Lineage Recovery, the `recovery.img` from the same release (flash it once
  with Heimdall/Odin, or with `dd` to `/dev/block/by-name/RECOVERY` from a rooted shell). It
  installs Updater OTAs. TWRP 3.7.0 can sideload too, but cannot read Android 17's encrypted /data.
- Coming from another ROM, or from a build signed with other keys: clean flash. Back up first,
  then format data in recovery.
- Install with ADB sideload: in Lineage Recovery "Apply update" > "Apply from ADB" (TWRP:
  "Advanced" > "ADB Sideload"), then
  `adb sideload lineage-24.0-<date>-UNOFFICIAL-gts210ltexx.zip`.
- Updating between builds with the same keys does not need a wipe. After the first install,
  later builds arrive through Settings > System > Updater.

## Releases and OTA

Images are published as GitHub Releases of this repository. `ota/gts210ltexx.json` (served by
GitHub Pages at the URL in `lineage.updater.uri`, see `device/gts210ltexx/device.mk`) points the
Updater at the newest one. `scripts/release.sh <tag>` checks a build (adb secured, own keys,
package name and date) and prints what it would publish; `--publish` creates the release,
writes the JSON, commits and pushes it. `scripts/check-updates.sh` reports what changed
upstream (LineageOS manifest and AOSP tag, every branch project, rINanDO's patches, microG and
Aurora releases) since the tree was synced.

## What is in this repository

```
device/gts210ltexx/   T815 device tree (on top of rINanDO's device/samsung/gts2-common)
kernel/               lineage_gts210ltexx_defconfig
patches/<name>/       patches for lineage/<TARGET>, applied by scripts/prepare-tree.sh
manifests/            gts210ltexx-extra.xml (vendor/partner_gms) and build10-pinned.xml
scripts/              prepare-tree, build, docker-run, fetch-prebuilts, check-own-keys, device-check
docker/Dockerfile     build environment (Ubuntu 22.04)
tree-overrides/       files copied over lineage/ (only the microG GmsCore APK, fetched)
rinando-fixes/        rebased replacements for rINanDO patch files that no longer apply
```

### Kernel patches (`patches/kernel/`, for `kernel/samsung/universal5433`)

| # | Subject |
|---|---|
| 0001 | staging: android: lowmemorykiller: don't let file cache hold off kills when swap is low (Dominggoes Isakh) |
| 0002 | usb: gadget: f_fs: do not touch the kiocb after aio_complete() |
| 0003 | usb: gadget: f_fs: drop the kiocb reference in ffs_aio_cancel(), fix async error paths |
| 0004 | aio: do not drop reqs_active twice for cancelled requests |
| 0005 | shmem: honour MFD_ALLOW_SEALING and finish the sealing checks |
| 0006 | vfs: make renameat2() use its directory fds and reject flags |
| 0007 | mm,fork: introduce MADV_WIPEONFORK |
| 0008 | ARM: extend the syscall table to 441 and wire up close_range and epoll_pwait2 |
| 0009 | fs: add close_range() with CLOSE_RANGE_UNSHARE and CLOSE_RANGE_CLOEXEC |
| 0010 | epoll: add syscall epoll_pwait2 |
| 0011 | vfs: add d_tmpfile() and let O_TMPFILE files be linked |
| 0012 | ext4: ->tmpfile() support |
| 0013 | selinux: enable genfscon labeling for sysfs and pstore files |
| 0014 | cgroup: one credential rule for moving another user's task |
| 0015 | cpuset: restore the requested CPUs when they come back online |
| 0016 | cgroup: accept the cpuset_v2_mode mount option |
| 0017 | cpuset: keep the tasks of a cpuset whose CPUs are all offline (cpuset_v2_mode) |
| 0018 | cpuset: make sure new tasks conform to the current config of the cpuset |
| 0019 | binder: BINDER_FREEZE and BINDER_GET_FROZEN_INFO ioctls, with the freeze race fix |
| 0020 | binder: use EINTR for interrupted wait for work |
| 0021 | cgroup: freezer: let frozen tasks be killed |
| 0022 | binder: fix two use-after-frees in binder_free_transaction() |
| 0023 | modem_v1: arm the CP-to-AP interrupts for wake-up only while CP runs |
| 0024 | pidfd: add pidfd_open(), pidfd_send_signal(), exit polling and waitid(P_PIDFD) |
| 0025 | locks: add open file description locks (F_OFD_GETLK, F_OFD_SETLK, F_OFD_SETLKW) |
| 0026 | thermal: cpu_cooling: do not clamp other clusters' policies (little cluster stuck at 400 MHz) |

### Android patches

| Directory (target) | Patch |
|---|---|
| `art` | 0001 jit: leave kDone when the boot image methods fd is unavailable |
| `bionic` | 0002 arc4random: use MADV_WIPEONFORK when the kernel has it |
| `frameworks_base` (frameworks/base) | 0001 Freezer: support the cgroup v1 freezer |
| `frameworks_native` (frameworks/native) | 0001 drop the epoll_pwait2 fallback (the kernel has it, patch 0010) |
| `system_core` (system/core) | 0001 libprocessgroup: take the freezer controller out of the cgroup v2 list |
| `gts2-common` (device/samsung/gts2-common) | 0001 system.prop: hide the on-screen navigation bar |
| | 0002 powerhint: use real top frequencies for min-freq boosts |
| | 0003 fstab: periodic trim instead of online discard on /data and /cache |
| | 0004 metadata: mount a tmpfs for aconfig storage |
| | 0005 props: set two system-read properties from the system image |
| | 0006 init: fix the commands and triggers vendor_init is denied |
| | 0007 init: keep persistent logcat to /data off by default |
| | 0008 init: do not make the cpuctl tasks files world-writable |
| | 0009 powerhint: keep the GPU at or below 550MHz at all times |
| | 0010 media_codecs: add the HEVC decoder, hide the secure AVC decoder |
| `hardware_samsung_slsi_openmax` (hardware/samsung_slsi/openmax) | 0001 install the HEVC and VP8 decoders to vendor |
| `vendor_samsung` (vendor/samsung) | 0001 gts2-common: build the OMX resource manager from source |
| `hardware_samsung_slsi_exynos` (hardware/samsung_slsi/exynos) | 0001 libhwcutils: start the MPP buffer-free thread (display buffer leak) |
| `vendor_lineage` (vendor/lineage) | 0001 config: allow keeping ro.debuggable in userdebug with secured adb |

## Deliberately not included

These were analysed, and most were prepared as patches, but are left out of this build:

- **inet_diag / tcp_info:** no observed problem behind it; on a Wi-Fi only tablet the gain is
  mostly a faster "no internet" indication.
- **binderfs:** no observed problem behind it, and there is no fallback if the mount fails.
- **PSI / workingset:** too large and risky for a 3.10 kernel (about 3200 lines, rewrites page
  cache handling unconditionally); lmkd uses the in-kernel low memory killer instead.
- **userfaultfd kernel series:** no observed problem behind it; memory headroom was measured,
  and ART runs the concurrent copying collector instead.
- **eBPF:** a minimal eBPF core is not usable by Android 17; rINanDO's patches let Android run
  without BPF.
- **cgroup v2:** the largest and riskiest change, and it enables nothing visible while cpusets
  and the freezer run on cgroup v1.
- **schedutil:** no observed problem behind it; tuning the interactive governor changed neither
  launch time nor scrolling, and Samsung's HMP scheduler and cpufreq driver would need adapting.
- **Thermal HAL:** a declared thermal HAL that fails to start blocks system_server at boot, and
  the tablet has no skin-temperature sensor; the kernel still throttles on its own.
- **LTE / RIL:** Wi-Fi only by choice; the 2016 Samsung RIL on Android 17 would be a project of
  its own.

## Credits

- **rINanDO** for [gts210wifi-patches](https://github.com/rINanDO/gts210wifi-patches) and the
  Exynos 5433 device, kernel, hardware and vendor forks that this build stands on.
- **Jan Huijsmans** and **Christopher N. Hesse** for the original T815 device tree.
- [LineageOS](https://lineageos.org), [microG](https://microg.org),
  [Aurora OSS](https://gitlab.com/AuroraOSS) (Aurora Store) and [F-Droid](https://f-droid.org).
- [lineageos4microg](https://github.com/lineageos4microg) for `android_vendor_partner_gms`.

Much of this work was done with the help of an AI coding assistant (Claude Code). The changes
were reviewed and tested by the owner on their own device.

## License and disclaimer

The scripts and documentation of this repository are licensed under the Apache License 2.0
(`LICENSE`). The device tree, the kernel patches and the Android patches keep their own
licenses; see `NOTICE.md`.

This software is provided "as is", without warranty of any kind. Flashing a custom ROM can
erase your data or leave the device unusable; you do it at your own risk.
