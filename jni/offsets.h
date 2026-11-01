#pragma once
#include <stdint.h>

/*
 * ANT-Aincrad offset table
 * ========================
 *
 * These values were RECOVERED BY DISASSEMBLING the actual working binary
 * `libs/arm64-v8a/libant_aincrad.so` (15 232 bytes, arm64-v8a).
 *
 * They are the values the shipped .so really uses. They are NOT the values that
 * were previously in this header (those came from an external offset list and
 * do not match this build of Free Fire at all).
 *
 * If Free Fire updates, every value below has to be re-derived. The runtime
 * validates the SetAimRotation prologue before hooking, so a stale table makes
 * the aim hook refuse to install instead of crashing the game.
 *
 * All values are RVAs from the load base of libil2cpp.so.
 */
namespace FFV {

/* --- match / player access --------------------------------------------- */
constexpr uintptr_t CurrentMatch      = 0x25C277C;  /* returns Match*            */
constexpr uintptr_t GetPlayerByIdx    = 0x12B1600;  /* (Match*, int) -> Player*  */

/* --- player state getters (Player*) ------------------------------------ */
constexpr uintptr_t get_CurHP         = 0x0AA1A74;  /* int  hp                   */
constexpr uintptr_t IsLocalPlayer     = 0x0AACEC8;  /* bool                      */
constexpr uintptr_t IsFiring          = 0x0AC77A8;  /* bool                      */
constexpr uintptr_t get_IsSighting    = 0x0AF8410;  /* bool                      */
constexpr uintptr_t IsLocalTeammate   = 0x0AAF4E8;  /* bool                      */
constexpr uintptr_t get_IsDieing      = 0x0AB4ABC;  /* bool                      */
constexpr uintptr_t IsVisible         = 0x0AAEB6C;  /* bool                      */
constexpr uintptr_t IsCrouching       = 0x0AAE66C;  /* bool                      */
constexpr uintptr_t get_IsSkyDiving   = 0x0AAEA48;  /* bool                      */
constexpr uintptr_t get_IsSkyDashing  = 0x0AAE264;  /* bool                      */

/* --- transforms -------------------------------------------------------- */
constexpr uintptr_t Transform_get_position = 0x2908DF8; /* Transform* -> Vector3 */

/* --- the function we hook ---------------------------------------------- */
constexpr uintptr_t SetAimRotation    = 0x11AD820;

/* Prologue probe: the first two bytes of a normal AArch64 prologue. */
constexpr uint8_t PROLOGUE_0 = 0xFD;
constexpr uint8_t PROLOGUE_1 = 0x7B;   /* (b[1] & 0x7F) == 0x6F            */

/* --- struct field ------------------------------------------------------- */
constexpr size_t PLAYER_TRANSFORM_FIELD = 0x18C;

/* --- tuning constants taken from the binary ---------------------------- */
constexpr int   MAX_PLAYER_SCAN       = 0x3B;      /* 59 players             */
constexpr float MAX_TARGET_DISTANCE   = 1.0e9f;
constexpr float AIM_SMOOTHING         = 3.0f;
constexpr float QUAT_EPSILON          = 0.99999f;  /* 0x3F7FDF3B             */

/* --- module names ------------------------------------------------------- */
constexpr const char* GAME_MODULE = "libil2cpp.so";
constexpr const char* LIBC_MODULE = "libc.so";

} // namespace FFV
