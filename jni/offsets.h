#pragma once
#include <stdint.h>
namespace FF {
    // Updated offsets based on the latest Free Fire Cheat Offsets and Bypass Codes (Scribd doc 823870034)
    // GameFacade offsets
    constexpr uintptr_t CurrentMatch    = 0x15E6540; // GameFacade CurrentMatch
    constexpr uintptr_t GetLocalPlayer  = 0x210D7C4; // UavMapObject GetLocalPlayer (or GameFacade CurrentLocalPlayer 0x15E6B40)
    constexpr uintptr_t GetPlayerByIdx  = 0x15E7440; // GameFacade GetLocalPlayerOrObServer (proxy for GetPlayerByIdx)
    
    // Aim Rotation (Player Class SetAimRotation)
    constexpr uintptr_t SetAimRotation_v1 = 0x11AD820; // SetAimRotation (Aimbot Use)
    constexpr uintptr_t SetAimRotation_v2 = 0x11AD820; // Unified for v1/v2 in latest build
    
    // Player Attributes
    constexpr uintptr_t get_CurHP       = 0x1207CBC; // GetHp
    constexpr uintptr_t IsVisible       = 0x11B1254; // IsVisible
    constexpr uintptr_t IsFiring        = 0x11A1844; // IsFiring
    constexpr uintptr_t get_IsSighting  = 0x11A18E0; // get_IsSighting
    constexpr uintptr_t IsLocalPlayer   = 0x15E6B40; // CurrentLocalPlayer
    constexpr uintptr_t IsLocalTeammate = 0x11BFEA4; // IsLocalTeammate
    constexpr uintptr_t get_IsDieing    = 0x11A11E8; // get_IsDieing
    constexpr uintptr_t IsCrouching     = 0x11C315C; // IsCrouching
    constexpr uintptr_t get_IsSkyDiving = 0x11A13CC; // IsMoving (proxy for SkyDiving state)
    constexpr uintptr_t get_IsSkyDashing= 0x11B0D5C; // IsSkyDashing
    constexpr uintptr_t get_IsParachuting= 0x11A13CC; // IsMoving (proxy)
    
    // Transforms
    constexpr uintptr_t FIELD_HEAD_TF   = 0x1220990; // GetHeadTF
    constexpr uintptr_t FIELD_HIP_TF    = 0x1220B74; // GetHipTF
    constexpr uintptr_t Transform_get_position = 0x61B5E1C; // get_position_Injected
    constexpr uintptr_t Transform_get_forward  = 0x61B697C; // Get Forward
}
