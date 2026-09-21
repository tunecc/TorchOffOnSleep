TARGET = iphone:clang:latest:17.0

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
ARCHS = arm64 arm64e
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TorchOffOnSleep
TorchOffOnSleep_FILES = Tweak.xm
TorchOffOnSleep_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
