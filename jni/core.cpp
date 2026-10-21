#include <jni.h>
#include <android/log.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/mman.h>
#include <unistd.h>
#include <dlfcn.h>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <sys/types.h>
#include <cerrno>
#include <algorithm>

#define TAG "ANT_Aincrad_Core"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

struct Quaternion {
    float x, y, z, w;
};

static Quaternion last_quat = {0, 0, 0, 1};
static int consecutive_headshots = 0;
static bool silent_aim_enabled = true;

typedef void (*SetAimRotation_t)(void* instance, Quaternion* rot);
static SetAimRotation_t orig_SetAimRotation = nullptr;

Quaternion SmoothQuaternion(Quaternion target, float smoothing) {
    const float safe_smoothing = std::max(smoothing, 0.001f);

    Quaternion result;
    result.x = last_quat.x + (target.x - last_quat.x) / safe_smoothing;
    result.y = last_quat.y + (target.y - last_quat.y) / safe_smoothing;
    result.z = last_quat.z + (target.z - last_quat.z) / safe_smoothing;
    result.w = last_quat.w + (target.w - last_quat.w) / safe_smoothing;

    const float mag = std::sqrt(result.x * result.x + result.y * result.y + result.z * result.z + result.w * result.w);
    if (mag > 0.0f) {
        const float inv_mag = 1.0f / mag;
        result.x *= inv_mag;
        result.y *= inv_mag;
        result.z *= inv_mag;
        result.w *= inv_mag;
    }
    last_quat = result;
    return result;
}

void hooked_SetAimRotation(void* instance, Quaternion* rot) {
    if (!silent_aim_enabled || !rot) {
        if (orig_SetAimRotation && instance && rot) {
            orig_SetAimRotation(instance, rot);
        }
        return;
    }

    if (consecutive_headshots >= 4) {
        rot->y -= 0.15f;
        consecutive_headshots = 0;
    } else {
        consecutive_headshots++;
    }

    Quaternion smoothed = SmoothQuaternion(*rot, 2.5f);

    if (orig_SetAimRotation && instance) {
        orig_SetAimRotation(instance, &smoothed);
    }
}

typedef ssize_t (*sendto_t)(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen);
static sendto_t orig_sendto = nullptr;

ssize_t hooked_sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen) {
    if (buf && len > 16) {
        const unsigned char* data = static_cast<const unsigned char*>(buf);
        if (data[0] == 0xAA && data[1] == 0x55 && (data[4] == 0x02 || data[4] == 0x05)) {
            return static_cast<ssize_t>(len);
        }
    }

    if (!orig_sendto) {
        errno = ENOSYS;
        return -1;
    }

    return orig_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
}

__attribute__((constructor)) void ant_aincrad_init() {
    LOGI("ANT-Aincrad root hook core loaded successfully into memory space.");
}
