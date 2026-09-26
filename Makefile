TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = debpack
debpack_FILES = main.m
debpack_CFLAGS = -fobjc-arc -O2 -Wno-unused-parameter
debpack_FRAMEWORKS = Foundation
debpack_INSTALL_PATH = /usr/bin

include $(THEOS)/makefiles/tool.mk
