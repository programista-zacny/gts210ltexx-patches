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

# Overlay
DEVICE_PACKAGE_OVERLAYS += \
	device/samsung/gts210ltexx/overlay

# Device-specific init fragment (runtime tuning, see the file)
PRODUCT_COPY_FILES += \
    device/samsung/gts210ltexx/rootdir/etc/init.gts210ltexx.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.gts210ltexx.rc

# Vibrator: unlike the Wi-Fi model, the T815 has an ISA1000A motor (timed_output
# "vibrator" with enable + intensity nodes); use the generic Samsung AIDL service.
PRODUCT_PACKAGES += \
    android.hardware.vibrator-service.samsung

# Bring-up builds only (scripts/build.sh exports WITH_ADB_INSECURE): start adbd as root from
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
PRODUCT_VENDOR_PROPERTIES += \
    dalvik.vm.heaptargetutilization=0.75 \
    dalvik.vm.heapminfree=512k \
    dalvik.vm.heapmaxfree=8m

# call the proprietary setup
$(call inherit-product, vendor/samsung/gts210ltexx/gts210ltexx-vendor.mk)
