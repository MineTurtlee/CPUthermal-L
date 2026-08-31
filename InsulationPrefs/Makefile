ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CPUthermalLPrefs
CPUthermalLPrefs_FILES = RootListController.m
CPUthermalLPrefs_CFLAGS = -fobjc-arc
CPUthermalLPrefs_FRAMEWORKS = UIKit IOKit
CPUthermalLPrefs_PRIVATE_FRAMEWORKS = Preferences
CPUthermalLPrefs_LIBRARIES = roothide
CPUthermalLPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
