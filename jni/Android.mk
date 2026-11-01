LOCAL_PATH := $(call my-dir)

# ---------------------------------------------------------------------------
# Prebuilt ShadowHook (arm64-v8a only - the game is 64-bit)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE           := shadowhook
LOCAL_SRC_FILES        := prebuilt/arm64-v8a/libshadowhook.so
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)
include $(PREBUILT_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# ant_aincrad
#
# NOTE: dumper.cpp and injector.cpp no longer exist. Their code was merged into
# core.cpp; keeping them in LOCAL_SRC_FILES produced duplicate JNIDefinition
# symbols and the link step failed.
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE    := ant_aincrad
LOCAL_SRC_FILES := core.cpp
LOCAL_LDLIBS    := -llog -landroid -lm
LOCAL_SHARED_LIBRARIES := shadowhook
LOCAL_CPPFLAGS  := -std=c++17 -O2 -fno-exceptions -fno-rtti -Wall
include $(BUILD_SHARED_LIBRARY)
