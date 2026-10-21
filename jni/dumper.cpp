#include <jni.h>
#include <android/log.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cstdio>
#include <cstddef>

#define TAG "ANT_Aincrad_Dumper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

// All includes are strictly above this line, outside any linkage blocks.
extern "C" {
    JNIEXPORT jstring JNICALL
    Java_com_ant_aincrad_Dumper_dumpOffsets(JNIEnv* env, jobject thiz) {
        LOGI("Scanning memory space for libil2cpp.so offsets...");
        
        uintptr_t il2cpp_base = 0;
        FILE* fp = fopen("/proc/self/maps", "r");
        if (fp) {
            char line[512];
            while (fgets(line, sizeof(line), fp)) {
                if (strstr(line, "libil2cpp.so")) {
                    char* dash = strchr(line, '-');
                    if (dash) {
                        *dash = '\0';
                        il2cpp_base = strtoull(line, nullptr, 16);
                        break;
                    }
                }
            }
            fclose(fp);
        }

        char buf[128];
        snprintf(buf, sizeof(buf), "Base resolved: 0x%lx", (unsigned long)il2cpp_base);
        return env->NewStringUTF(buf);
    }
}