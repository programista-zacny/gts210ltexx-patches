# Copyright (C) 2013-2016, The CyanogenMod Project
# Copyright (C) 2017, The LineageOS Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Inherit device configuration
$(call inherit-product, device/samsung/gts210ltexx/device.mk)
$(call inherit-product, device/samsung/gts2-common/device-common.mk)

# Inherit from the common Open Source product configuration
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)

# Inherit some common LineageOS stuff.
$(call inherit-product, vendor/lineage/config/common_full_tablet_wifionly.mk)

# ART garbage collector: this kernel has no userfaultfd (no CONFIG_USERFAULTFD in 3.10; the
# backport in staging/backport-userfaultfd is not applied), so ART uses the concurrent copying
# collector at run time. Tell the build, or it compiles the boot image and the system apps for the
# userfaultfd GC (default_art_config.mk sets "true") and the runtime rejects all of it ("Read
# barrier state mismatch", "Userfaultfd GC check failed" in logcat) and compiles again on the
# device.
#
# This has to be set here, in the product's own makefile, not in device.mk: for a variable that
# takes a single value, a product without a value of its own gets the one of the first inherited
# makefile that has one, and the inherited makefiles are tried in the alphabetical order of their
# paths (build/make/core/node_fns.mk, _expand-inherited-values). build/make/target/product/
# aosp_base.mk, which brings in default_art_config.mk, sorts before device/samsung/..., so a value
# set in device.mk would be ignored. Set to "true" (or remove) only together with a kernel that
# has userfaultfd.
PRODUCT_ENABLE_UFFD_GC := false

PRODUCT_NAME := lineage_gts210ltexx
PRODUCT_DEVICE := gts210ltexx
PRODUCT_BRAND := samsung
PRODUCT_MODEL := SM-T815
PRODUCT_MANUFACTURER := samsung

PRODUCT_BUILD_PROP_OVERRIDES += \
  SystemName=gts210ltexx \
  BuildDesc="gts210ltexx-user 7.0 NRD90M T815XXU2CRH1 release-keys"

BUILD_FINGERPRINT := samsung/gts210ltexx/gts210lte:7.0/NRD90M/T815XXU2CRH1:user/release-keys
