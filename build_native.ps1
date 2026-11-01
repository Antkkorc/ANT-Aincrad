<#
  build_native.ps1
  ================
  Builds jni/core.cpp into libant_aincrad.so with ndk-build and copies the
  result next to the prebuilt ShadowHook.

  IMPORTANT: building is optional. The app already ships a working
  libant_aincrad.so in app/src/main/jniLibs/arm64-v8a/. Only run this if you
  changed the C++ source.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1 -Ndk "C:\Android\Sdk\ndk\26.1.10909125"
#>

[CmdletBinding()]
param(
    [string] $RepoRoot = $PSScriptRoot,
    [string] $TargetProject = "C:\Users\anton\AndroidStudioProjects\FFMODROOT",
    [string] $Ndk = ""
)

$ErrorActionPreference = "Stop"

function Step($n, $t) { Write-Host ""; Write-Host "== [$n] $t " -ForegroundColor Cyan; Write-Host ("-" * 70) -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red }

Step 1 "Locating the NDK"
if ([string]::IsNullOrWhiteSpace($Ndk)) {
    $candidates = @()
    if ($env:ANDROID_NDK_HOME) { $candidates += $env:ANDROID_NDK_HOME }
    if ($env:LOCALAPPDATA) {
        $ndkRoot = Join-Path $env:LOCALAPPDATA "Android\Sdk\ndk"
        if (Test-Path $ndkRoot) {
            $candidates += (Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending |
                            Select-Object -ExpandProperty FullName)
        }
    }
    if ($env:ANDROID_HOME) {
        $ndkRoot2 = Join-Path $env:ANDROID_HOME "ndk"
        if (Test-Path $ndkRoot2) {
            $candidates += (Get-ChildItem $ndkRoot2 -Directory | Sort-Object Name -Descending |
                            Select-Object -ExpandProperty FullName)
        }
    }
    $Ndk = $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ "ndk-build.cmd")) } | Select-Object -First 1
}

if (-not $Ndk -or -not (Test-Path (Join-Path $Ndk "ndk-build.cmd"))) {
    Bad "No NDK with ndk-build.cmd found. Install it from Android Studio -> SDK Manager -> NDK (Side by side), then re-run with -Ndk <path>."
    exit 1
}
Ok "NDK: $Ndk"

$ndkBuild = Join-Path $Ndk "ndk-build.cmd"

Step 2 "Building libant_aincrad.so"
Push-Location $RepoRoot
try {
    & $ndkBuild "NDK_PROJECT_PATH=." "APP_BUILD_SCRIPT=jni/Android.mk" "NDK_APPLICATION_MK=jni/Application.mk" 2>&1 | Out-Host
    $exit = $LASTEXITCODE
} finally { Pop-Location }

if ($exit -ne 0) { Bad "ndk-build failed (exit $exit)"; exit $exit }

$built = Join-Path $RepoRoot "libs\arm64-v8a\libant_aincrad.so"
if (-not (Test-Path $built)) { Bad "expected output missing: $built"; exit 1 }
Ok ("built {0:N0} bytes" -f (Get-Item $built).Length)

Step 3 "Copying into the Android project"
$dst = Join-Path $TargetProject "app\src\main\jniLibs\arm64-v8a"
if (Test-Path $dst) {
    Copy-Item $built (Join-Path $dst "libant_aincrad.so") -Force
    Ok "copied to $dst"
    Get-ChildItem $dst -Filter *.so | ForEach-Object { Ok ("{0}  ({1:N0} bytes)" -f $_.Name, $_.Length) }
} else {
    Bad "target folder not found: $dst"
    exit 1
}

Write-Host ""
Ok "Done. Now run .\fix_ffmodroot.ps1 to rebuild the APK."
