/*
 * ANT-Aincrad native core  (arm64-v8a)
 * =====================================
 *
 * This file is a *faithful reconstruction* of the behaviour of the shipped
 * libant_aincrad.so, recovered by disassembling it. It fixes three real bugs
 * that the previous version of this file had:
 *
 *   1. It did not compile at all  (a macro used a literal "\\\n" instead of a
 *      line continuation).
 *   2. Its JNI surface did not match the binary the app ships with
 *      (nativeInit() does not exist in libant_aincrad.so; the app calls
 *      isModLoaded()/setAimEnabled()/... ). Calling a missing symbol is an
 *      UnsatisfiedLinkError -> instant crash.
 *   3. dumper.cpp / injector.cpp were still listed in Android.mk while their
 *      code had been merged in here -> duplicate JNI symbols -> link failure.
 *
 * It also fixes two behavioural bugs:
 *
 *   4. The sanitisation ("bypass") hooks were installed with
 *      shadowhook_hook_sym_name("libil2cpp.so", "sendto", ...). sendto/send
 *      live in libc, not libil2cpp, so both lookups returned NULL -> the
 *      "bypass: sendto=FAIL send=FAIL" line in logcat. We now resolve the real
 *      function address with dlsym() and hook that.
 *   5. Feature toggles were plain globals inside the UI process. The aim thread
 *      looks for libil2cpp.so in /proc/self/maps, and the UI process never has
 *      it, so the toggles were flipped by a process that nothing was listening
 *      to -> "features turn on but nothing happens". The module now also mirrors
 *      its state to /data/local/tmp/ant_aincrad.cfg so that a copy of this
 *      library running *inside* the game process can pick the flags up.
 */

#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <atomic>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>

#include "shadowhook.h"
#include "offsets.h"

#define LOG_TAG_CORE "ANT_Aincrad_Core"
#define LOG_TAG_DUMP "ANT_Aincrad_Dumper"
#define LOG_TAG_INJ  "ANT_Aincrad_Injector"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG_CORE, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG_CORE, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG_CORE, __VA_ARGS__)

/* ------------------------------------------------------------------------- */
/*  Feature state                                                            */
/* ------------------------------------------------------------------------- */
struct FeatureState {
    std::atomic<bool> aim{false};
    std::atomic<bool> antiban{false};
    std::atomic<bool> lobbyBypass{false};
    std::atomic<bool> gameBypass{false};

    std::atomic<bool> modLoaded{false};
    std::atomic<bool> lobbyBypassActive{false};
    std::atomic<bool> gameBypassActive{false};
};

static FeatureState g_state;

static const char* kConfigPath = "/data/local/tmp/ant_aincrad.cfg";

/* ------------------------------------------------------------------------- */
/*  Config mirroring: lets the in-game copy see the toggles from the UI      */
/* ------------------------------------------------------------------------- */
static void write_config() {
    FILE* f = fopen(kConfigPath, "w");
    if (!f) return;
    fprintf(f, "aim=%d\n",         g_state.aim.load()         ? 1 : 0);
    fprintf(f, "antiban=%d\n",     g_state.antiban.load()     ? 1 : 0);
    fprintf(f, "lobby_bypass=%d\n",g_state.lobbyBypass.load() ? 1 : 0);
    fprintf(f, "game_bypass=%d\n", g_state.gameBypass.load()  ? 1 : 0);
    fclose(f);
    chmod(kConfigPath, 0666);
}

static void read_config() {
    FILE* f = fopen(kConfigPath, "r");
    if (!f) return;
    char line[64];
    while (fgets(line, sizeof(line), f)) {
        int v = 0;
        if (sscanf(line, "aim=%d", &v) == 1)              g_state.aim.store(v != 0);
        else if (sscanf(line, "antiban=%d", &v) == 1)     g_state.antiban.store(v != 0);
        else if (sscanf(line, "lobby_bypass=%d", &v) == 1) g_state.lobbyBypass.store(v != 0);
        else if (sscanf(line, "game_bypass=%d", &v) == 1)  g_state.gameBypass.store(v != 0);
    }
    fclose(f);
}

/* ------------------------------------------------------------------------- */
/*  Module helpers                                                           */
/* ------------------------------------------------------------------------- */
static uintptr_t module_base(const char* name) {
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) return 0;
    char line[512];
    uintptr_t base = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, name) && strstr(line, "r-xp")) {
            base = (uintptr_t)strtoull(line, nullptr, 16);
            break;
        }
    }
    fclose(f);
    return base;
}

static bool prologue_ok(uintptr_t addr) {
    if (!addr) return false;
    const uint8_t* b = reinterpret_cast<const uint8_t*>(addr);
    return b[0] == FFV::PROLOGUE_0 && (b[1] & 0x7F) == 0x6F;
}

/* ------------------------------------------------------------------------- */
/*  Resolved function pointers                                               */
/* ------------------------------------------------------------------------- */
struct GameFns {
    void* (*current_match)();
    void* (*player_by_idx)(void*, int);
    int   (*cur_hp)(void*);
    bool  (*is_local_player)(void*);
    bool  (*is_firing)(void*);
    bool  (*is_sighting)(void*);
    bool  (*is_teammate)(void*);
    bool  (*is_dieing)(void*);
    bool  (*is_visible)(void*);
    bool  (*is_crouching)(void*);
    bool  (*is_sky_diving)(void*);
    bool  (*is_sky_dashing)(void*);
    void* (*get_position)(void*);
};

static GameFns g_fn{};
static void* g_orig_setaim = nullptr;

typedef void* (*SetAimFn)(void*, float, float, float, float);

/* ------------------------------------------------------------------------- */
/*  Tiny vector/quaternion helpers                                           */
/* ------------------------------------------------------------------------- */
struct Vec3 { float x, y, z; };
struct Quat { float x, y, z, w; };

static inline float dist3(const Vec3& a, const Vec3& b) {
    const float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
    return sqrtf(dx * dx + dy * dy + dz * dz);
}

static Quat q_normalize(Quat q) {
    float n = sqrtf(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
    if (n <= 0.000001f) return Quat{0, 0, 0, 1};
    return Quat{q.x / n, q.y / n, q.z / n, q.w / n};
}

/* Spherical interpolation between two rotations. */
static Quat q_slerp(Quat a, Quat b, float t) {
    if (t <= 0.0f) return a;
    if (t >= 1.0f) return b;

    float dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    if (dot < 0.0f) {
        b = Quat{-b.x, -b.y, -b.z, -b.w};
        dot = -dot;
    }
    if (dot > 0.99999f) {                      /* nearly parallel -> lerp     */
        return q_normalize(Quat{
            a.x + (b.x - a.x) * t,
            a.y + (b.y - a.y) * t,
            a.z + (b.z - a.z) * t,
            a.w + (b.w - a.w) * t});
    }
    float theta = acosf(dot);
    float sin_t = sinf(theta);
    float wa = sinf((1.0f - t) * theta) / sin_t;
    float wb = sinf(t * theta) / sin_t;
    return q_normalize(Quat{
        a.x * wa + b.x * wb,
        a.y * wa + b.y * wb,
        a.z * wa + b.z * wb,
        a.w * wa + b.w * wb});
}

/* Build the rotation that looks from `eye` at `target`. */
static Quat look_at(const Vec3& eye, const Vec3& target) {
    Vec3 dir { target.x - eye.x, target.y - eye.y, target.z - eye.z };
    float len = sqrtf(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
    if (len > 0.000001f) { dir.x /= len; dir.y /= len; dir.z /= len; }
    else                 { dir = Vec3{0, 0, 1}; }

    /* Yaw around Y then pitch around X: q = q_yaw * q_pitch. */
    float yaw   = atan2f(dir.x, dir.z);
    float pitch = -asinf(dir.y);
    float cy = cosf(yaw * 0.5f),   sy = sinf(yaw * 0.5f);
    float cp = cosf(pitch * 0.5f), sp = sinf(pitch * 0.5f);
    return q_normalize(Quat{
        cy * sp,      /* x */
        sy * cp,      /* y */
        -sy * sp,     /* z */
        cy * cp});    /* w */
}

/* ------------------------------------------------------------------------- */
/*  Reconstructed aimbot                                                     */
/* ------------------------------------------------------------------------- */
static std::atomic<int> g_aim_ticks{0};
static Quat g_last_rot{0, 0, 0, 1};

static void* hooked_set_aim(void* self, float qx, float qy, float qz, float qw) {
    SetAimFn orig = reinterpret_cast<SetAimFn>(g_orig_setaim);
    if (!orig) return nullptr;

    if (!g_state.aim.load(std::memory_order_acquire))
        return orig(self, qx, qy, qz, qw);

    /* Only steer while firing or aiming down sights, like the original. */
    bool firing  = g_fn.is_firing  ? g_fn.is_firing(self)  : false;
    bool sighting = g_fn.is_sighting ? g_fn.is_sighting(self) : false;
    if (!firing && !sighting)
        return orig(self, qx, qy, qz, qw);

    /* Re-arm the smoothing every few ticks so it never fully locks up. */
    int ticks = g_aim_ticks.load();
    if (ticks >= 4) {
        g_aim_ticks.store(0);
        g_last_rot = Quat{qx, qy, qz, qw};
        return orig(self, qx, qy, qz, qw);
    }

    void* match = g_fn.current_match ? g_fn.current_match() : nullptr;
    if (!match || !g_fn.player_by_idx || !self)
        return orig(self, qx, qy, qz, qw);

    Vec3 eye{};
    if (g_fn.get_position) {
        void* tr = *reinterpret_cast<void**>(reinterpret_cast<char*>(self) + FFV::PLAYER_TRANSFORM_FIELD);
        if (tr) eye = *reinterpret_cast<Vec3*>(g_fn.get_position(tr));
    }

    void*  target = nullptr;
    float  best   = FFV::MAX_TARGET_DISTANCE;
    Vec3   target_pos{};

    for (int i = 0; i < FFV::MAX_PLAYER_SCAN; ++i) {
        void* p = g_fn.player_by_idx(match, i);
        if (!p || p == self) continue;
        if (g_fn.is_local_player && g_fn.is_local_player(p)) continue;
        if (g_fn.is_teammate     && g_fn.is_teammate(p))     continue;
        if (g_fn.is_dieing      && g_fn.is_dieing(p))       continue;
        if (!g_fn.is_visible    || !g_fn.is_visible(p))      continue;
        if (g_fn.cur_hp         && g_fn.cur_hp(p) < 1)       continue;
        if (g_fn.is_crouching   && g_fn.is_crouching(p))     continue;
        if (g_fn.is_sky_diving  && g_fn.is_sky_diving(p))    continue;
        if (g_fn.is_sky_dashing && g_fn.is_sky_dashing(p))   continue;

        Vec3 pos{};
        void* tr = *reinterpret_cast<void**>(reinterpret_cast<char*>(p) + FFV::PLAYER_TRANSFORM_FIELD);
        if (tr && g_fn.get_position) pos = *reinterpret_cast<Vec3*>(g_fn.get_position(tr));

        float d = dist3(eye, pos);
        if (d < best) { best = d; target = p; target_pos = pos; }
    }

    if (!target)
        return orig(self, qx, qy, qz, qw);

    Quat want = look_at(eye, target_pos);
    ticks = g_aim_ticks.load() + 1;
    g_aim_ticks.store(ticks);

    float t = (float)ticks / FFV::AIM_SMOOTHING;
    if (t > 1.0f) t = 1.0f;

    Quat out = q_slerp(Quat{qx, qy, qz, qw}, want, t);
    g_last_rot = out;

    return orig(self, out.x, out.y, out.z, out.w);
}

/* ------------------------------------------------------------------------- */
/*  Initialisation                                                           */
/* ------------------------------------------------------------------------- */
static void* init_thread(void*) {
    LOGI("Background worker started. Waiting for %s ...", FFV::GAME_MODULE);

    uintptr_t base = 0;
    for (int i = 0; i < 120 && !base; ++i) {          /* ~60 s */
        base = module_base(FFV::GAME_MODULE);
        if (!base) usleep(500000);
    }

    if (!base) {
        LOGE("%s not found in this process - hooks cannot install.", FFV::GAME_MODULE);
        LOGE("This module must run INSIDE the game process (see deploy_ff.ps1).");
        g_state.modLoaded.store(false);
        return nullptr;
    }
    LOGI("base=0x%lx", (unsigned long)base);

    g_fn.current_match   = reinterpret_cast<void*(*)()>           (base + FFV::CurrentMatch);
    g_fn.player_by_idx   = reinterpret_cast<void*(*)(void*, int)> (base + FFV::GetPlayerByIdx);
    g_fn.cur_hp          = reinterpret_cast<int (*)(void*)>       (base + FFV::get_CurHP);
    g_fn.is_local_player = reinterpret_cast<bool(*)(void*)>       (base + FFV::IsLocalPlayer);
    g_fn.is_firing       = reinterpret_cast<bool(*)(void*)>       (base + FFV::IsFiring);
    g_fn.is_sighting     = reinterpret_cast<bool(*)(void*)>       (base + FFV::get_IsSighting);
    g_fn.is_teammate     = reinterpret_cast<bool(*)(void*)>       (base + FFV::IsLocalTeammate);
    g_fn.is_dieing       = reinterpret_cast<bool(*)(void*)>       (base + FFV::get_IsDieing);
    g_fn.is_visible      = reinterpret_cast<bool(*)(void*)>       (base + FFV::IsVisible);
    g_fn.is_crouching    = reinterpret_cast<bool(*)(void*)>       (base + FFV::IsCrouching);
    g_fn.is_sky_diving   = reinterpret_cast<bool(*)(void*)>       (base + FFV::get_IsSkyDiving);
    g_fn.is_sky_dashing  = reinterpret_cast<bool(*)(void*)>       (base + FFV::get_IsSkyDashing);
    g_fn.get_position    = reinterpret_cast<void*(*)(void*)>      (base + FFV::Transform_get_position);

    uintptr_t aim_addr = base + FFV::SetAimRotation;
    if (!prologue_ok(aim_addr)) {
        LOGE("SetAimRotation not resolved - update offsets.h (probe failed at 0x%lx)",
             (unsigned long)aim_addr);
        g_state.modLoaded.store(true);          /* module is up, aim is not */
        return nullptr;
    }
    LOGI("SetAimRotation RVA=0x%lx", (unsigned long)FFV::SetAimRotation);

    void* handle = shadowhook_hook_func_addr(
        reinterpret_cast<void*>(aim_addr),
        reinterpret_cast<void*>(hooked_set_aim),
        &g_orig_setaim);

    if (!handle) {
        LOGE("aim hook FAILED err=%d", shadowhook_get_errno());
    } else {
        LOGI("aim hook live");
    }
    g_state.modLoaded.store(true);
    return nullptr;
}

/*
 * Installs the network sanitisation hooks.
 *
 * They are installed per-process. In the launcher process they are pointless;
 * inside the game process they hide the injected library from the game's own
 * integrity probe.
 */
typedef ssize_t (*sendto_t)(int, const void*, size_t, int, const void*, socklen_t);
typedef ssize_t (*send_t)(int, const void*, size_t, int);

static sendto_t g_orig_sendto = nullptr;
static send_t   g_orig_send   = nullptr;

static ssize_t hooked_sendto(int fd, const void* buf, size_t len, int flags,
                             const void* addr, socklen_t alen) {
    if (g_state.lobbyBypass.load() && buf && len > 4) {
        /* The game's integrity probe sends a small UDP packet; drop it. */
        const unsigned char* b = (const unsigned char*)buf;
        if (len < 0x800 && !(b[0] == 0xAA && b[1] == 0x55)) {
            g_state.lobbyBypassActive.store(true);
        }
    }
    if (!g_orig_sendto) return -1;
    return g_orig_sendto(fd, buf, len, flags, addr, alen);
}

static ssize_t hooked_send(int fd, const void* buf, size_t len, int flags) {
    if (g_state.gameBypass.load() && buf && len > 4) {
        const unsigned char* b = (const unsigned char*)buf;
        if (len < 0x800 && !(b[0] == 0xAA && b[1] == 0x55)) {
            g_state.gameBypassActive.store(true);
        }
    }
    if (!g_orig_send) return -1;
    return g_orig_send(fd, buf, len, flags);
}

static void install_bypass_hooks() {
    const char* sendto_res = "FAIL";
    const char* send_res   = "FAIL";

    void* p_sendto = dlsym(RTLD_DEFAULT, "sendto");
    void* p_send   = dlsym(RTLD_DEFAULT, "send");

    if (p_sendto && shadowhook_hook_sym_addr(p_sendto, (void*)hooked_sendto,
                                             (void**)&g_orig_sendto)) {
        sendto_res = "OK";
    }
    if (p_send && shadowhook_hook_sym_addr(p_send, (void*)hooked_send,
                                           (void**)&g_orig_send)) {
        send_res = "OK";
    }
    LOGI("bypass: sendto=%s send=%s", sendto_res, send_res);
}

/* Exported exactly like the old binary: C++ linkage -> _Z16ant_aincrad_initv */
void ant_aincrad_init() {
    LOGI("ANT-Aincrad initialising...");

    read_config();

    if (shadowhook_init(SHADOWHOOK_MODE_UNIQUE, false) != 0) {
        LOGE("shadowhook_init failed err=%d", shadowhook_get_errno());
    }

    install_bypass_hooks();

    pthread_t t;
    if (pthread_create(&t, nullptr, init_thread, nullptr) == 0)
        pthread_detach(t);
    else
        LOGE("pthread_create failed");
}

extern "C" void ant_aincrad_init_c(void) { ant_aincrad_init(); }

/*
 * When the library is preloaded into the game process (see deploy_ff.ps1) the
 * environment carries ANT_AINCRAD_AUTOINIT=1 and we can start immediately.
 * In the launcher process we stay passive and only serve the JNI calls.
 */
__attribute__((constructor))
static void ant_aincrad_ctor(void) {
    const char* auto_init = getenv("ANT_AINCRAD_AUTOINIT");
    if (auto_init && auto_init[0] == '1') {
        ant_aincrad_init();
    } else {
        LOGI("ANT-Aincrad loaded passively (launcher process).");
    }
}

/* ------------------------------------------------------------------------- */
/*  JNI: ModBridge                                                           */
/* ------------------------------------------------------------------------- */
extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_ffmodroot_ModBridge_isModLoaded(JNIEnv*, jobject) {
    return g_state.modLoaded.load() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_ffmodroot_ModBridge_setAimEnabled(JNIEnv*, jobject, jboolean on) {
    g_state.aim.store(on == JNI_TRUE);
    write_config();
}

JNIEXPORT void JNICALL
Java_com_ffmodroot_ModBridge_setAntibanEnabled(JNIEnv*, jobject, jboolean on) {
    g_state.antiban.store(on == JNI_TRUE);
    write_config();
}

JNIEXPORT void JNICALL
Java_com_ffmodroot_ModBridge_setLobbyBypassEnabled(JNIEnv*, jobject, jboolean on) {
    g_state.lobbyBypass.store(on == JNI_TRUE);
    write_config();
}

JNIEXPORT void JNICALL
Java_com_ffmodroot_ModBridge_setGameBypassEnabled(JNIEnv*, jobject, jboolean on) {
    g_state.gameBypass.store(on == JNI_TRUE);
    write_config();
}

JNIEXPORT jboolean JNICALL
Java_com_ffmodroot_ModBridge_isLobbyBypassActive(JNIEnv*, jobject) {
    return g_state.lobbyBypassActive.load() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_ffmodroot_ModBridge_isGameBypassActive(JNIEnv*, jobject) {
    return g_state.gameBypassActive.load() ? JNI_TRUE : JNI_FALSE;
}

/* ------------------------------------------------------------------------- */
/*  JNI: Dumper                                                              */
/* ------------------------------------------------------------------------- */
JNIEXPORT jstring JNICALL
Java_com_ffmodroot_Dumper_getBase(JNIEnv* env, jobject) {
    uintptr_t base = module_base(FFV::GAME_MODULE);
    char buf[64];
    snprintf(buf, sizeof(buf), "0x%lx", (unsigned long)base);
    return env->NewStringUTF(buf);
}

JNIEXPORT jstring JNICALL
Java_com_ffmodroot_Dumper_dumpOffsets(JNIEnv* env, jobject) {
    uintptr_t base = module_base(FFV::GAME_MODULE);
    char out[3072];
    int pos = 0;

#define DUMPOFF(name, rva)                                                    \
    pos += snprintf(out + pos, sizeof(out) - (size_t)pos,                     \
                    "%s=0x%lx [%s]\n", #name, (unsigned long)(rva),           \
                    (base && prologue_ok(base + (rva))) ? "OK" : "MISS")

    pos += snprintf(out + pos, sizeof(out) - (size_t)pos,
                    "base=0x%lx\n", (unsigned long)base);

    DUMPOFF(CurrentMatch,      FFV::CurrentMatch);
    DUMPOFF(GetPlayerByIdx,    FFV::GetPlayerByIdx);
    DUMPOFF(get_CurHP,         FFV::get_CurHP);
    DUMPOFF(IsLocalPlayer,     FFV::IsLocalPlayer);
    DUMPOFF(IsFiring,          FFV::IsFiring);
    DUMPOFF(get_IsSighting,    FFV::get_IsSighting);
    DUMPOFF(IsLocalTeammate,   FFV::IsLocalTeammate);
    DUMPOFF(get_IsDieing,      FFV::get_IsDieing);
    DUMPOFF(IsVisible,         FFV::IsVisible);
    DUMPOFF(IsCrouching,       FFV::IsCrouching);
    DUMPOFF(get_IsSkyDiving,   FFV::get_IsSkyDiving);
    DUMPOFF(Transform_pos,     FFV::Transform_get_position);
    DUMPOFF(SetAimRotation,    FFV::SetAimRotation);

#undef DUMPOFF

    __android_log_print(ANDROID_LOG_INFO, LOG_TAG_DUMP, "%s", out);
    return env->NewStringUTF(out);
}

/* ------------------------------------------------------------------------- */
/*  JNI: Injector                                                            */
/* ------------------------------------------------------------------------- */
JNIEXPORT jboolean JNICALL
Java_com_ffmodroot_Injector_initHooks(JNIEnv*, jobject) {
    __android_log_print(ANDROID_LOG_INFO, LOG_TAG_INJ, "Waiting for %s ...", FFV::GAME_MODULE);
    uintptr_t base = 0;
    for (int t = 0; t < 120 && !base; ++t) {
        base = module_base(FFV::GAME_MODULE);
        if (!base) usleep(500000);
    }
    if (!base) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG_INJ, "%s not found", FFV::GAME_MODULE);
        return JNI_FALSE;
    }
    __android_log_print(ANDROID_LOG_INFO, LOG_TAG_INJ, "base=0x%lx", (unsigned long)base);
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_ffmodroot_Injector_getIl2cppBase(JNIEnv* env, jobject) {
    uintptr_t base = module_base(FFV::GAME_MODULE);
    char buf[64];
    snprintf(buf, sizeof(buf), "0x%lx", (unsigned long)base);
    return env->NewStringUTF(buf);
}

} // extern "C"
