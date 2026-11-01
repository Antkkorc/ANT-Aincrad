#include <jni.h>
#include <android/log.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "offsets.h"

#define TAG "ANT_Aincrad_Dumper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

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

    #define DUMPOFF(name, rva) \
        pos += snprintf(out + pos, sizeof(out) - pos, \
            "%s=0x%lx [%s]\n", #name, (unsigned long)(rva), \
            probeFunc(base + (rva)) ? "OK" : "MISS")

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
