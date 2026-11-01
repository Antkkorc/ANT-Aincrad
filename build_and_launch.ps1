$ErrorActionPreference = "Continue"
$PROJECT   = "C:\Users\anton\ANT-Aincrad"
$FFMODROOT = "C:\Users\anton\AndroidStudioProjects\FFMODROOT"
$NDK       = (Get-ChildItem "$env:LOCALAPPDATA\Android\Sdk\ndk\" | Sort-Object Name -Descending | Select-Object -First 1).FullName
$DST_JNI   = "$FFMODROOT\app\src\main\jniLibs\arm64-v8a"

Write-Host "NDK: $NDK"
Set-Location $PROJECT

$shadowPaths = @(
    "C:\ffmod\libs\arm64-v8a\libshadowhook.so",
    "C:\ffmod\apk\base_out\lib\arm64-v8a\libshadowhook.so",
    "C:\shadowhook_build\libshadowhook.so",
    "C:\Users\anton\Downloads\shadowhook_build\libshadowhook.so"
)
$shadowSrc = $null
foreach ($p in $shadowPaths) { if (Test-Path $p) { $shadowSrc = $p; break } }
if (!$shadowSrc) { Write-Host "ERROR: libshadowhook.so not found"; exit 1 }
Write-Host "Found shadowhook: $shadowSrc"
Copy-Item $shadowSrc "$PROJECT\libs\arm64-v8a\libshadowhook.so" -Force

$absPath = ($PROJECT -replace "\\","/") + "/libs/arm64-v8a/libshadowhook.so"

$mk = @"
LOCAL_PATH := `$(call my-dir)

include `$(CLEAR_VARS)
LOCAL_MODULE            := shadowhook_prebuilt
LOCAL_SRC_FILES         := $absPath
LOCAL_EXPORT_C_INCLUDES := `$(LOCAL_PATH)
include `$(PREBUILT_SHARED_LIBRARY)

include `$(CLEAR_VARS)
LOCAL_MODULE           := ant_aincrad
LOCAL_SRC_FILES        := dumper.cpp core.cpp injector.cpp
LOCAL_LDLIBS           := -llog -landroid
LOCAL_SHARED_LIBRARIES := shadowhook_prebuilt
LOCAL_CPPFLAGS         := -std=c++17 -O3 -fvisibility=hidden
include `$(BUILD_SHARED_LIBRARY)
"@
$mk | Set-Content "jni\Android.mk"

@"
APP_ABI      := arm64-v8a
APP_PLATFORM := android-24
APP_STL      := c++_shared
"@ | Set-Content "jni\Application.mk"

Write-Host "Building..."
& "$NDK\ndk-build.cmd" NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=jni/Android.mk APP_ABI=arm64-v8a

$soPath = "$PROJECT\libs\arm64-v8a\libant_aincrad.so"
if (!(Test-Path $soPath)) { Write-Host "BUILD FAILED"; exit 1 }
Write-Host "Build OK"

New-Item -ItemType Directory -Force -Path $DST_JNI | Out-Null
Copy-Item "$PROJECT\libs\arm64-v8a\libant_aincrad.so" "$DST_JNI\" -Force
Copy-Item "$PROJECT\libs\arm64-v8a\libshadowhook.so"  "$DST_JNI\" -Force
Copy-Item "$PROJECT\libs\arm64-v8a\libc++_shared.so"  "$DST_JNI\" -Force
Write-Host "Copied .so files to FFMODROOT"

Set-Location $FFMODROOT
cmd /c "gradlew.bat assembleDebug 2>&1"

$apk = "$FFMODROOT\app\build\outputs\apk\debug\app-debug.apk"
if (!(Test-Path $apk)) { Write-Host "GRADLE FAILED"; exit 1 }
Write-Host "APK built OK"

adb connect 127.0.0.1:5555
adb install -r $apk
adb shell am start -n "com.ffmodroot/.MainActivity"
Write-Host "Done. Watching logcat..."
adb logcat -s ANT_Aincrad_Core ANT_Aincrad_Dumper ANT_Aincrad_Injector