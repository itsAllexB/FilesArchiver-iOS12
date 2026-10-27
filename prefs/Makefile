# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FilesArchiverPrefs
FilesArchiverPrefs_FILES = FARootListController.m
FilesArchiverPrefs_FRAMEWORKS = UIKit
FilesArchiverPrefs_PRIVATE_FRAMEWORKS = Preferences
FilesArchiverPrefs_INSTALL_PATH = /Library/PreferenceBundles
FilesArchiverPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
