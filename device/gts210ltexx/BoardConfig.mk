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
TARGET_SYSTEM_PROP := $(LOCAL_PATH)/system.prop

# Recovery
TARGET_OTA_ASSERT_DEVICE := gts210lte,gts210ltexx

# Inherit common board flags
include device/samsung/gts2-common/BoardConfigCommon.mk

# SELinux (device-specific additions: vibrator)
# (explicit path: BoardConfigCommon.mk above redefines LOCAL_PATH)
BOARD_VENDOR_SEPOLICY_DIRS += device/samsung/gts210ltexx/sepolicy/vendor
