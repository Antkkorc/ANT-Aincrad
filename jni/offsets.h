#pragma once
#include <stdint.h>
namespace FF {
    constexpr uintptr_t CurrentMatch = 0x25C277C;
    constexpr uintptr_t GetLocalPlayer = 0x12B1178;
    constexpr uintptr_t GetPlayerByIdx = 0x12B1600;
    constexpr uintptr_t SetAimRotation_v1 = 0x00AAD320;
    constexpr uintptr_t SetAimRotation_v2 = 0x011AD820;
    constexpr uintptr_t get_CurHP = 0x00AA1A74;
    constexpr uintptr_t IsVisible = 0x00AAEB6C;
    constexpr uintptr_t IsFiring = 0x00AC77A8;
    constexpr uintptr_t get_IsSighting = 0x00AF8410;
    constexpr uintptr_t IsLocalPlayer = 0x00AAF4E8;
    constexpr uintptr_t IsLocalTeammate = 0x00AB4ABC;
    constexpr uintptr_t get_IsDieing = 0x00AACEC8;
    constexpr uintptr_t IsCrouching = 0x00AB60C4;
    constexpr uintptr_t get_IsSkyDiving = 0x00AAE66C;
    constexpr uintptr_t get_IsSkyDashing = 0x00AAEA48;
    constexpr uintptr_t get_IsParachuting = 0x00AAE264;
    constexpr uintptr_t FIELD_HEAD_TF = 0x18C;
    constexpr uintptr_t FIELD_HIP_TF = 0x190;
    constexpr uintptr_t Transform_get_position = 0x2908DF8;
    constexpr uintptr_t Transform_get_forward = 0x2909524;
}
