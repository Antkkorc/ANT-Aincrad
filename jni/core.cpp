#include <jni.h>
#include <android/log.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include "shadowhook.h"

#define LOG_TAG "FFMODROOT"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static void* (*orig_target_func)(void* arg) = nullptr;

static void* hooked_target_func(void* arg) {
    LOGI("Hook triggered successfully inside target function!");
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
        return nullptr;
    }

    LOGI("libil2cpp.so located in memory! Initializing ShadowHook...");

    if (shadowhook_init(0, 0) != 0) {
        LOGE("Failed to initialize ShadowHook! Error: %d", shadowhook_get_errno());
        return nullptr;
    }
    LOGI("ShadowHook initialized cleanly.");

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
Java_com_example_ffmodroot_MainActivity_nativeInit(JNIEnv* env, jobject thiz) {
    LOGI("nativeInit JNI call received from Java. Spawning worker thread...");
    pthread_t t;
    if (pthread_create(&t, nullptr, init_thread, nullptr) != 0) {
        LOGE("Failed to create background initialization thread!");
        return -1;
    }
    pthread_detach(t);
    return 0;
}