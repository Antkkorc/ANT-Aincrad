#include <jni.h>
#include <android/log.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include "shadowhook.h"

#define LOG_TAG "FFMODROOT"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// --- NEW: Global ModBridge bridge to Java ---
static JNIEnv* g_env = nullptr;
static jobject g_obj = nullptr;

static void call_java_boolean(const char* methodName, bool val) {
    if (!g_env || !g_obj) return;
    jclass cls = g_env->GetObjectClass(g_obj);
    jmethodID mid = g_env->GetMethodID(cls, methodName, "(Z)V");
    if (mid) g_env->CallVoidMethod(g_obj, mid, (jboolean)val);
    g_env->DeleteLocalRef(cls);
}

static void call_java_void(const char* methodName) {
    if (!g_env || !g_obj) return;
    jclass cls = g_env->GetObjectClass(g_obj);
    jmethodID mid = g_env->GetMethodID(cls, methodName, "()V");
    if (mid) g_env->CallVoidMethod(g_obj, mid);
    g_env->DeleteLocalRef(cls);
}

// --- Hooked functions for features ---
static void* (*orig_target_func)(void* arg) = nullptr;
static void* hooked_target_func(void* arg) {
    LOGI("Hook triggered successfully inside target function!");
    // Feature logic: if aim enabled, trigger
    call_java_void("onHookTriggered");
    if (orig_target_func) {
        return orig_target_func(arg);
    }
    return nullptr;
}

// Background thread waiting safely for libil2cpp.so without crashing
void* init_thread(void*) {
    LOGI("Background worker started. Waiting for libil2cpp.so...");
    void* handle = nullptr;
    
    int retries = 0;
    while (!handle && retries < 60) { // Timeout after ~30 seconds to prevent deadlocks
        handle = dlopen("libil2cpp.so", RTLD_NOLOAD);
        if (!handle) {
            usleep(500000); // 0.5s
            retries++;
        }
    }

    if (!handle) {
        LOGE("Timeout: libil2cpp.so not loaded within 30 seconds.");
        call_java_boolean("isModLoaded", false);
        return nullptr;
    }

    LOGI("libil2cpp.so located in memory! Initializing ShadowHook...");

    if (shadowhook_init(0, 0) != 0) {
        LOGE("Failed to initialize ShadowHook! Error: %d", shadowhook_get_errno());
        call_java_boolean("isModLoaded", false);
        return nullptr;
    }
    LOGI("ShadowHook initialized cleanly.");
    call_java_boolean("isModLoaded", true);

    // Optional safe hook placement (replace with valid symbol when ready)
    // Safe check: shadowhook will return NULL safely if symbol doesn't exist yet instead of crashing
    void* hook_handle = shadowhook_hook_sym_name(
        "libil2cpp.so",
        "il2cpp_domain_get", // Using a stable Unity internal symbol as a safe test hook
        (void*)hooked_target_func,
        (void**)&orig_target_func
    );

    if (!hook_handle) {
        LOGE("Target symbol not found or hook failed. Error code: %d", shadowhook_get_errno());
    } else {
        LOGI("Successfully hooked target symbol!");
    }

    return nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_ffmodroot_ModBridge_nativeInit(JNIEnv* env, jobject thiz) {
    LOGI("nativeInit JNI call received from Java. Spawning worker thread...");
    // Cache env and object for callbacks
    g_env = env;
    g_obj = env->NewGlobalRef(thiz);
    
    pthread_t t;
    if (pthread_create(&t, nullptr, init_thread, nullptr) != 0) {
        LOGE("Failed to create background initialization thread!");
        return -1;
    }
    pthread_detach(t);
    return 0;
}

// --- Dumper ---
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "offsets.h"

#define TAG "ANT_Aincrad_Dumper"

static uintptr_t getBase(const char* soName) {
    char line[512];
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) return 0;
    uintptr_t result = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, soName) && strstr(line, "r-xp")) {
            result = (uintptr_t)strtoull(line, nullptr, 16);
            break;
        }
    }
    fclose(f);
    return result;
}

static bool probeFunc(uintptr_t addr) {
    if (!addr) return false;
    const uint8_t* b = reinterpret_cast<const uint8_t*>(addr);
    return (b[1] & 0x7F) == 0x6F && b[0] == 0xFD;
}

extern "C" {

JNIEXPORT jstring JNICALL
Java_com_ffmodroot_Dumper_getBase(JNIEnv* env, jobject) {
    uintptr_t base = getBase("libil2cpp.so");
    char buf[64];
    snprintf(buf, sizeof(buf), "0x%lx", (unsigned long)base);
    return env->NewStringUTF(buf);
}

JNIEXPORT jstring JNICALL
Java_com_ffmodroot_Dumper_dumpOffsets(JNIEnv* env, jobject) {
    uintptr_t base = getBase("libil2cpp.so");
    char out[2048];
    int  pos = 0;

    #define DUMPOFF(name, rva) \\\n        pos += snprintf(out + pos, sizeof(out) - pos, \\\n            "%s=0x%lx [%s]\\n", #name, (unsigned long)(rva), \\\n            probeFunc(base + (rva)) ? "OK" : "MISS")

    pos += snprintf(out + pos, sizeof(out) - pos,
        "base=0x%lx\n", (unsigned long)base);

    DUMPOFF(CurrentMatch,    FF::CurrentMatch);
    DUMPOFF(GetLocalPlayer,  FF::GetLocalPlayer);
    DUMPOFF(GetPlayerByIdx,  FF::GetPlayerByIdx);
    DUMPOFF(SetAimRot_v1,    FF::SetAimRotation_v1);
    DUMPOFF(SetAimRot_v2,    FF::SetAimRotation_v2);
    DUMPOFF(get_CurHP,       FF::get_CurHP);
    DUMPOFF(IsVisible,       FF::IsVisible);
    DUMPOFF(IsFiring,        FF::IsFiring);
    DUMPOFF(get_IsSighting,  FF::get_IsSighting);
    DUMPOFF(IsLocalPlayer,   FF::IsLocalPlayer);
    DUMPOFF(IsLocalTeammate, FF::IsLocalTeammate);
    DUMPOFF(get_IsDieing,    FF::get_IsDieing);
    DUMPOFF(IsCrouching,     FF::IsCrouching);
    DUMPOFF(get_IsSkyDiving, FF::get_IsSkyDiving);
    DUMPOFF(Transform_pos,   FF::Transform_get_position);

    #undef DUMPOFF

    LOGI("%s", out);
    return env->NewStringUTF(out);
}

} // extern "C"

// --- Injector ---
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define TAG "ANT_Aincrad_Injector"

static uintptr_t GetModuleBase(const char* name) {
    FILE* fp = fopen("/proc/self/maps", "r");
    if (!fp) return 0;
    uintptr_t base = 0;
    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, name) && strstr(line, "r-xp")) {
            char* dash = strchr(line, '-');
            if (dash) { *dash = '\0'; base = strtoull(line, nullptr, 16); break; }
        }
    }
    fclose(fp);
    return base;
}

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_ffmodroot_Injector_initHooks(JNIEnv*, jobject) {
    LOGI("Waiting for libil2cpp.so...");
    uintptr_t base = 0;
    for (int t = 0; t < 120 && !base; ++t) {
        base = GetModuleBase("libil2cpp.so");
        if (!base) usleep(500000);
    }
    if (!base) { LOGE("libil2cpp.so not found"); return (jboolean)false; }
    LOGI("base=0x%lx", (unsigned long)base);
    return (jboolean)true;
}

JNIEXPORT jstring JNICALL
Java_com_ffmodroot_Injector_getIl2cppBase(JNIEnv* env, jobject) {
    uintptr_t base = GetModuleBase("libil2cpp.so");
    char buf[64];
    snprintf(buf, sizeof(buf), "0x%lx", (unsigned long)base);
    return env->NewStringUTF(buf);
}

} // extern "C"
