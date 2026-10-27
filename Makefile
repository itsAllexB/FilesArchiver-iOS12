# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Files
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilesArchiver
FilesArchiver_FILES = Tweak.x FAArchiver.m
FilesArchiver_FRAMEWORKS = UIKit MobileCoreServices
# libarchive comes from the Procursus package libarchive13 (/usr/lib/libarchive.13.dylib);
# only its headers and a link stub are kept in vendor/.
FilesArchiver_CFLAGS = -fobjc-arc -Ivendor/libarchive/include
FilesArchiver_LDFLAGS = -Lvendor/libarchive -larchive

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
