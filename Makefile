ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless

INSTALL_TARGET_PROCESSES = thermalmonitord SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CPUthermalL
CPUthermalL_FILES = Sources/CPUthermalL/Tweak.m
CPUthermalL_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CPUthermalL_FRAMEWORKS = Foundation IOKit
CPUthermalL_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += InsulationPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -TERM thermalmonitord 2>/dev/null || true; killall -TERM SpringBoard 2>/dev/null || true"
