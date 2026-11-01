#include <jni.h>
#include <android/log.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define TAG "ANT_Aincrad_Injector"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

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
