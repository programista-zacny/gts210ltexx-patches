LOCAL_PATH := device/samsung/gts210ltexx

# Ramdisk
PRODUCT_PACKAGES += \
    ueventd.universal5433.rc

# Audio
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/audio/mixer_paths_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/mixer_paths_0.xml

# Bluetooth
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bluetooth/bt_vendor.conf:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth/bt_vendor.conf

# --- fixes-3 item 5: Bluetooth audio output (A2DP) ---------------------------------------------
# Media audio to a Bluetooth speaker was silent (build 8): the Bluetooth stack sends A2DP audio
# only through a "Bluetooth audio provider" HAL, and none was installed (boot log: "Failed to
# dlopen android.hardware.bluetooth.audio-impl.so", "BluetoothAudio AIDL implementation does not
# exist"). This is the AOSP provider. android.hardware.audio.service loads the library by name
# and registers android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default; its
# VINTF fragment (bluetooth_audio.xml) is installed with it. audio.bluetooth.default, the audio
# HAL module the audio policy routes A2DP to, is already installed by gts2-common.
PRODUCT_PACKAGES += \
    android.hardware.bluetooth.audio-impl

# gts2-common's audio_policy_configuration.xml is a version 7.0 file (lists separated by
# spaces) but includes the pre-7.0 bluetooth_audio_policy_configuration.xml (lists separated by
# commas), so the sample rates of the Bluetooth device ports are not parsed. Install the 7.0
# variant under the included name; the two files differ in nothing else. This entry wins over
# gts2-common's because this makefile is inherited first (the other is listed in
# out/target/product/gts210ltexx/product_copy_files_ignored.txt).
PRODUCT_COPY_FILES += \
    frameworks/av/services/audiopolicy/config/bluetooth_audio_policy_configuration_7_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_audio_policy_configuration.xml
# --- end of item 5 ------------------------------------------------------------------------------

# Hardware video decoders (2026-11-08). The Exynos OMX core (libExynosOMX_Core.so, a blob) loads
# its components only from the hard-coded /vendor/lib/omx/, but the gts2-common blobs and the
# openmax source modules install to /system/lib/omx/, so IOmx listed no nodes and every video
# was decoded in software. Now:
# - MPEG4 (MFC): the gts2-common blob, copied to /vendor/lib/omx/ below;
# - AVC (MFC, also OMX.Exynos.avc.dec.secure): built from hardware/samsung_slsi/openmax and
#   installed to vendor by patches/hardware_samsung_slsi_openmax/0002, which also adds
#   allocateNativeHandle for the secure decoder's input buffers. Builds 11-17 copied the AVC blob
#   instead; Widevine L1 decryption into its secure decoder failed ("Invalid secure handle":
#   the blob hands out fds, liboemcrypto needs native handles), so the secure entry was hidden.
#   The blob still lands in /system/lib/omx/ through find-vendor-blobs; the core never looks there;
# - HEVC (separate HEVC IP, exynos-hevc-dec) and VP8 (MFC): the components built from
#   hardware/samsung_slsi/openmax, installed to vendor by patches/hardware_samsung_slsi_openmax/0001
#   (the gts2-common blobs of these are an Android 9 build the resource manager rejects);
# - libExynosOMX_Resourcemanager built from source: the blob reads the components' codecType at
#   the wrong offset and refused every node (patches/vendor_samsung/0001 keeps the blob out).
# media_codecs.xml: patches/gts2-common/0010 adds OMX.Exynos.hevc.dec; OMX.Exynos.avc.dec.secure
# is listed again (hidden in builds 11-17). No VP9 hardware on the 5433.
# Tested on the device: logs/omx-test2-20261108/, omx-test3-hevc-20261108/, omx-test4-vp8-20261108/.
PRODUCT_PACKAGES += \
    libExynosOMX_Resourcemanager \
    libOMX.Exynos.AVC.Decoder \
    libOMX.Exynos.HEVC.Decoder \
    libOMX.Exynos.VP8.Decoder

PRODUCT_COPY_FILES += \
    vendor/samsung/gts2-common/proprietary/system/lib/omx/libOMX.Exynos.MPEG4.Decoder.so:$(TARGET_COPY_OUT_VENDOR)/lib/omx/libOMX.Exynos.MPEG4.Decoder.so

# Wi-Fi PNO (WITH_WIFI_PNO=true, the default of scripts/build.sh): reconnect with the screen off.
# The Wi-Fi service reads its config_wifi_* values from the com.android.wifi.resources APK in the
# Wi-Fi APEX; gts2-common's config_wifi_background_scan_support=true sits in its frameworks/base
# overlay, where the service never looks, so PNO was "not supported" and Wi-Fi stayed down after
# a screen-off disconnect until the screen came on (build 21: up to 20.8 h). This RRO sets it for
# the Wi-Fi module; wificond then starts an nl80211 scheduled scan, which the kernel driver runs
# as a firmware PFN scan (patches/kernel/0027, CONFIG_BCMDHD_SCHED_SCAN). Without this switch the
# driver's scheduled scan stays unused (patches/gts2-common/0011 keeps wpa_supplicant off it).
ifeq ($(WITH_WIFI_PNO),true)
PRODUCT_PACKAGES += \
    WifiOverlayGts210ltexx
endif

# Overlay
# (LTE build: lte/overlay comes first, so that its values win over the Wi-Fi ones.)
ifeq ($(WITH_LTE),true)
DEVICE_PACKAGE_OVERLAYS += \
	device/samsung/gts210ltexx/lte/overlay
endif
DEVICE_PACKAGE_OVERLAYS += \
	device/samsung/gts210ltexx/overlay

# Device-specific init fragment (runtime tuning, see the file)
PRODUCT_COPY_FILES += \
    device/samsung/gts210ltexx/rootdir/etc/init.gts210ltexx.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.gts210ltexx.rc

# Recovery USB (adb, sideload): select the legacy android_usb gadget, see the file. Recovery
# ramdisk only.
PRODUCT_COPY_FILES += \
    device/samsung/gts210ltexx/rootdir/etc/init.recovery.universal5433.rc:$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.universal5433.rc

# Vibrator: unlike the Wi-Fi model, the T815 has an ISA1000A motor (timed_output
# "vibrator" with enable + intensity nodes); use the generic Samsung AIDL service.
PRODUCT_PACKAGES += \
    android.hardware.vibrator-service.samsung

# OTA updates: the LineageOS Updater reads its server URL from this property. The JSON is kept in
# the public repository, served by GitHub Pages (a property value may not exceed 91 bytes, the
# raw.githubusercontent.com URL does), and points at GitHub Releases; scripts/release.sh writes both.
PRODUCT_SYSTEM_PROPERTIES += \
    lineage.updater.uri=https://programista-zacny.github.io/gts210ltexx-patches/ota/gts210ltexx.json

# Bring-up builds only (WITH_ADB_INSECURE=true for scripts/build.sh): start adbd as root from
# its first start. "adb root" cannot be used on a fresh install: LineageOS refuses it until
# "Rooted debugging" is switched on in Developer options, which needs a working UI, and adbd
# restarts itself even when it refuses. A root adbd reads dmesg and /proc/last_kmsg directly,
# which the shell user is denied by SELinux.
ifneq ($(WITH_ADB_INSECURE),)
PRODUCT_SYSTEM_PROPERTIES += \
    service.adb.root=1
endif

# Aurora Store (prebuilt, see prebuilt/AuroraStore/Android.bp)
PRODUCT_PACKAGES += \
    AuroraStore \
    AuroraStoreBlacklist

# Dalvik heap: this is a 3 GB RAM device. gts2-common inherits the 4096 MB profile
# through optional ("?=") assignments; these plain assignments override it with the
# tighter values of phone-xhdpi-2048-dalvik-heap.mk.
# heapsize 384m instead of 512m: the kernel has no userfaultfd, so ART runs the CC
# collector, which reserves twice the maximum heap in virtual address space. In a
# 32-bit process (3 GB of addresses) a largeHeap app with 512m reserved 1 GB and Prime
# Video aborted with EGL_BAD_ALLOC at playback start (2026-11-08); with 384m it plays.
PRODUCT_VENDOR_PROPERTIES += \
    dalvik.vm.heapsize=384m \
    dalvik.vm.heaptargetutilization=0.75 \
    dalvik.vm.heapminfree=512k \
    dalvik.vm.heapmaxfree=8m

# --- LTE modem: mobile data and SMS (WITH_LTE=true, the default of scripts/build.sh) -------------
# The Shannon 333 modem with the stock userspace of firmware T815XXU2CRH1 (the firmware of the CP
# image in the RADIO partition): cbd boots the CP, rild loads Samsung's libsec-ril.so through the
# Samsung libril (built from hardware/samsung/ril/libril, HIDL IRadio 1.0), and
# android.hardware.radio@1.4-service.legacy serves it to the framework as IRadio 1.4. No voice
# calls. The other parts: BoardConfig.mk (properties, SELinux, VINTF, soong config),
# lineage_gts210ltexx.mk (telephony product), lte/ (init, SELinux, overlay, properties),
# patches/hardware_ril, hardware_samsung, hardware_lineage_interfaces and system_netd.
# Without WITH_LTE=true none of this is in the build (the Wi-Fi-only configuration).
ifeq ($(WITH_LTE),true)

# Stock blobs, unmodified (sha256 in tools/stock-T815/T815XXU2CRH1/modem/MANIFEST.txt). They are
# not published: scripts/prepare-tree.sh copies them from tree-overrides/ (see its README).
# cbd is statically linked. libsec-ril.so needs libril.so (the Samsung libril, which also
# provides strdup8to16, gone from libcutils), librilutils, libcutils, libnetutils, libsqlite,
# libhardware_legacy, libcrypto, libxml2, libc++, libsecnativefeature, libfloatingfeature and
# libprotobuf-cpp-full (the stock 2016 build, under its own name; the platform protobuf library
# installs as libprotobuf-cpp-full-<version>.so, so the names do not collide).
PRODUCT_COPY_FILES += \
    vendor/samsung/gts210ltexx-modem/proprietary/vendor/bin/cbd:$(TARGET_COPY_OUT_VENDOR)/bin/cbd \
    vendor/samsung/gts210ltexx-modem/proprietary/vendor/lib/libsec-ril.so:$(TARGET_COPY_OUT_VENDOR)/lib/libsec-ril.so \
    vendor/samsung/gts210ltexx-modem/proprietary/vendor/lib/libfloatingfeature.so:$(TARGET_COPY_OUT_VENDOR)/lib/libfloatingfeature.so \
    vendor/samsung/gts210ltexx-modem/proprietary/vendor/lib/libsecnativefeature.so:$(TARGET_COPY_OUT_VENDOR)/lib/libsecnativefeature.so \
    vendor/samsung/gts210ltexx-modem/proprietary/vendor/lib/libprotobuf-cpp-full.so:$(TARGET_COPY_OUT_VENDOR)/lib/libprotobuf-cpp-full.so

# rild (hardware/ril/rild, enabled by ril.use_aosp_rild in BoardConfig.mk) with the Samsung
# libril, the IRadio 1.0 -> 1.4 wrapper, and the vendor variants of the libraries libsec-ril.so
# needs that no other vendor module pulls in (the ones that are already in /vendor/lib are
# listed too, so that the blob does not depend on them staying there by accident).
PRODUCT_PACKAGES += \
    rild \
    libril \
    librilutils \
    android.hardware.radio@1.4-service.legacy \
    libcrypto.vendor \
    libhardware_legacy.vendor \
    libnetutils.vendor \
    libsqlite.vendor \
    libxml2.vendor

# CP boot daemon, /dev/mipi-lli, DIAG node permissions.
PRODUCT_COPY_FILES += \
    device/samsung/gts210ltexx/lte/init.baseband.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.baseband.rc

# GNSS with the modem's assistance: start gpsd as /system/bin/gpsd, the name libsec-ril.so's OEM
# client whitelist expects (lte/gpsd/Android.bp; the service override is in lte/init.baseband.rc).
PRODUCT_PACKAGES += \
    gpsd_system_bin_symlink

# Telephony features: mobile data and SMS (which bring in android.hardware.telephony,
# .radio.access and .subscription). Not .calling or .gsm (android.hardware.telephony.gsm.xml
# declares calling too): this build has no voice calls.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.telephony.data.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.telephony.data.xml \
    frameworks/native/data/etc/android.hardware.telephony.messaging.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.telephony.messaging.xml

endif
# --- end of LTE modem ---------------------------------------------------------------------------

# call the proprietary setup
$(call inherit-product, vendor/samsung/gts210ltexx/gts210ltexx-vendor.mk)
