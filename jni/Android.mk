LOCAL_PATH := $(call my-dir)

# --- 1. Define prebuilt shadowhook module ---
include $(CLEAR_VARS)
LOCAL_MODULE := shadowhook
LOCAL_SRC_FILES := prebuilt/arm64-v8a/libshadowhook.so
include $(PREBUILT_SHARED_LIBRARY)

# --- 2. Define main ant_aincrad module ---
include $(CLEAR_VARS)
LOCAL_MODULE    := ant_aincrad
LOCAL_SRC_FILES := core.cpp dumper.cpp injector.cpp
LOCAL_LDLIBS    := -llog -landroid -latomic
LOCAL_SHARED_LIBRARIES := shadowhook
LOCAL_CPPFLAGS  := -std=c++17 -O3
include $(BUILD_SHARED_LIBRARY)