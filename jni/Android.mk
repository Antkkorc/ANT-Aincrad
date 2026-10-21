LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE    := ant_aincrad
LOCAL_SRC_FILES := dumper.cpp core.cpp injector.cpp
LOCAL_LDLIBS    := -llog -landroid
LOCAL_CPPFLAGS  := -std=c++17 -O3 -fvisibility=hidden
include $(BUILD_SHARED_LIBRARY)