#include <jni.h>
#include <android/log.h>
#include <sys/mman.h>
#include <unistd.h>
#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cstdio>

#define TAG "ANT_Aincrad_Injector"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

uintptr_t GetModuleBase(const char* module_name) {
    FILE* fp = fopen("/proc/self/maps", "r");
    if (!fp) return 0;

    uintptr_t base = 0;
    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, module_name)) {
            char* dash = strchr(line, '-');
            if (dash) {
                *dash = '\0';
                base = strtoull(line, NULL, 16);
                break;
            }
        }
    }
    fclose(fp);
    return base;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_ant_aincrad_Injector_initHooks(JNIEnv* env, jobject thiz) {
    LOGI("Initiating dynamic runtime memory attachment...");
    
    uintptr_t il2cpp_base = GetModuleBase("libil2cpp.so");
    while (il2cpp_base == 0) {
        usleep(500000);
        il2cpp_base = GetModuleBase("libil2cpp.so");
    }

    LOGI("libil2cpp.so successfully targeted at: 0x%lx", (unsigned long)il2cpp_base);
    return (jboolean)true;
}