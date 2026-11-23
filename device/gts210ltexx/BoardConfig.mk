LOCAL_PATH := device/samsung/gts210ltexx

# Display
# Android 14 QPR3 requires spelling out the word ORIENTATION for whatever dumb reason
# Doesn't work in .mk, put in prop.
# SF_PRIMARY_DISPLAY_ORIENTATION := ORIENTATION_270

# Include path
$(call soong_config_set,samsungVars,target_specific_header_path,$(LOCAL_PATH)/include)

# Kernel
TARGET_KERNEL_CONFIG := lineage_gts210ltexx_defconfig

# Properties
# (LTE build, WITH_LTE=true: lte/system.prop instead, without ro.radio.noril and with the
# telephony settings, and lte/vendor.prop for rild.)
ifeq ($(WITH_LTE),true)
TARGET_SYSTEM_PROP := $(LOCAL_PATH)/lte/system.prop
TARGET_VENDOR_PROP := $(LOCAL_PATH)/lte/vendor.prop
else
TARGET_SYSTEM_PROP := $(LOCAL_PATH)/system.prop
endif

# Recovery
TARGET_OTA_ASSERT_DEVICE := gts210lte,gts210ltexx

# Inherit common board flags
include device/samsung/gts2-common/BoardConfigCommon.mk

# SELinux (device-specific additions: vibrator)
# (explicit path: BoardConfigCommon.mk above redefines LOCAL_PATH)
BOARD_VENDOR_SEPOLICY_DIRS += device/samsung/gts210ltexx/sepolicy/vendor

# LTE modem (WITH_LTE=true, the default of scripts/build.sh; see the LTE block in device.mk).
# Without it this block adds nothing and the board is the Wi-Fi-only one.
ifeq ($(WITH_LTE),true)
# SELinux: cbd, rild and radio HAL additions to the samsung_slsi and LineageOS policy.
BOARD_VENDOR_SEPOLICY_DIRS += device/samsung/gts210ltexx/lte/sepolicy

# VINTF: IRadio 1.4 "slot1", and a framework matrix entry for it (target level 7 lists 1.5-1.6).
DEVICE_MANIFEST_FILE += device/samsung/gts210ltexx/lte/manifest.xml
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += device/samsung/gts210ltexx/lte/framework_compatibility_matrix.xml

# RIL. Build rild from hardware/ril, and its libril from the Samsung libril sources
# (patches/hardware_ril/0001, patches/hardware_samsung/0001). Not BOARD_PROVIDES_LIBRIL: that
# enables the make module "libril" of hardware/samsung, which clashes with the Soong one.
$(call soong_config_set_bool,ril,use_aosp_rild,true)
$(call soong_config_set_bool,ril,samsung_libril,true)

# netd: rule for the directly-connected route of rmnet0 (patches/system_netd/0001). gts2-common
# sets TARGET_NEEDS_NETD_DIRECT_CONNECT_RULE, which nothing reads any more.
$(call soong_config_set_bool,netd,direct_connect_rule,true)
endif
