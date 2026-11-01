<#
  build_native.ps1
  ================
  Builds jni/core.cpp into libant_aincrad.so and copies it into the FFMODROOT
  project, replacing the old shipped binary.

  Why this does not use ndk-build any more
  ----------------------------------------
  With NDK 30, `ndk-build` aborts before compiling anything:

      Android NDK: APP_PLATFORM not set. Defaulting to minimum supported
                   version android-21.
      add-application.mk:88: *** Android NDK: Aborting...

  Newer NDKs no longer accept the legacy Application.mk flow the way this
  project used it. Instead we drive the NDK's clang++ directly:

      aarch64-linux-android<api>-clang++ --target=... -shared -fPIC ...

  That is one deterministic command, it picks whichever API level your NDK
  actually ships, and it does not care which ndk-build release you have.
  jni/Android.mk and jni/Application.mk are kept for reference only; nothing
  in this script uses them.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1 -Api 24
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1 -Ndk "C:\Android\Sdk\ndk\26.1.10909125"
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1 -NoCopy
#>

[CmdletBinding()]
param(
    [string] $RepoRoot      = $PSScriptRoot,
    [string] $TargetProject = "C:\Users\anton\AndroidStudioProjects\FFMODROOT",
    [string] $Ndk           = "",
    [int]    $Api           = 0,
    [switch] $NoCopy
)

$ErrorActionPreference = "Stop"

function Step($n, $t) { Write-Host ""; Write-Host "== [$n] $t " -ForegroundColor Cyan; Write-Host ("-" * 70) -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
Step 1 "Locating the NDK"
# ---------------------------------------------------------------------------
function Test-Ndk([string] $p) {
    if (-not $p) { return $false }
    return (Test-Path (Join-Path $p "toolchains\llvm")) -or (Test-Path (Join-Path $p "toolchains/llvm"))
}

if (-not (Test-Ndk $Ndk)) {
    $candidates = @()
    foreach ($root in @($env:ANDROID_NDK_HOME, $env:ANDROID_NDK_ROOT)) {
        if (Test-Ndk $root) { $candidates += $root }
    }
    foreach ($sdkBase in @(
            (Join-Path $env:LOCALAPPDATA "Android\Sdk"),
            $env:ANDROID_HOME,
            $env:ANDROID_SDK_ROOT,
            "C:\Android\Sdk")) {
        if (-not $sdkBase) { continue }
        $ndkRoot = Join-Path $sdkBase "ndk"
        if (Test-Path $ndkRoot) {
            $candidates += (Get-ChildItem $ndkRoot -Directory |
                            Sort-Object Name -Descending |
                            Select-Object -ExpandProperty FullName)
        }
    }
    $Ndk = $candidates | Where-Object { Test-Ndk $_ } | Select-Object -First 1
}

if (-not (Test-Ndk $Ndk)) {
    Bad "No usable NDK found."
    Bad "Android Studio -> SDK Manager -> SDK Tools -> tick 'NDK (Side by side)' -> Apply."
    Bad "Then re-run, or pass -Ndk C:\path\to\ndk\26.1.10909125"
    exit 1
}
Ok "NDK: $Ndk"

# ---------------------------------------------------------------------------
Step 2 "Locating the clang toolchain"
# ---------------------------------------------------------------------------
$llvmRoot = Join-Path $Ndk "toolchains\llvm\prebuilt"
if (-not (Test-Path $llvmRoot)) { $llvmRoot = Join-Path $Ndk "toolchains/llvm/prebuilt" }
$prebuilt = Get-ChildItem $llvmRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $prebuilt) { Bad "no prebuilt toolchain under $llvmRoot"; exit 1 }
$bin = Join-Path $prebuilt.FullName "bin"
Ok "toolchain: $($prebuilt.Name)"

$wrappers = Get-ChildItem $bin -Filter "aarch64-linux-android*-clang++*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'aarch64-linux-android(\d+)-clang\+\+' }

if (-not $wrappers) { Bad "no aarch64 clang++ wrapper in $bin"; exit 1 }

$parsed = $wrappers | ForEach-Object {
    $null = $_.Name -match 'aarch64-linux-android(\d+)-clang\+\+'
    [pscustomobject]@{ Api = [int]$Matches[1]; Path = $_.FullName; Name = $_.Name }
}

if ($Api -gt 0) {
    $chosen = $parsed | Where-Object { $_.Api -eq $Api } | Select-Object -First 1
    if (-not $chosen) {
        Warn "your NDK has no api-$Api wrapper; available: $(($parsed.Api | Sort-Object -Unique) -join ', ')"
    }
}
if (-not $chosen) {
    # Prefer 24 (matches the project's minSdk), else the lowest api >= 21.
    $chosen = $parsed | Where-Object { $_.Api -eq 24 } | Select-Object -First 1
}
if (-not $chosen) {
    $chosen = $parsed | Where-Object { $_.Api -ge 21 } | Sort-Object Api | Select-Object -First 1
}
if (-not $chosen) {
    $chosen = $parsed | Sort-Object Api | Select-Object -First 1
}
Ok "compiler: $($chosen.Name)  (api $($chosen.Api))"

$nm = Join-Path $bin "llvm-nm.exe"
if (-not (Test-Path $nm)) { $nm = Join-Path $bin "llvm-nm" }

# ---------------------------------------------------------------------------
Step 3 "Compiling core.cpp"
# ---------------------------------------------------------------------------
$src = Join-Path $RepoRoot "jni\core.cpp"
if (-not (Test-Path $src)) { $src = Join-Path $RepoRoot "jni/core.cpp" }
if (-not (Test-Path $src)) { Bad "source not found: jni/core.cpp"; exit 1 }

$outDir = Join-Path $RepoRoot "libs\arm64-v8a"
if (-not (Test-Path $outDir)) { $outDir = Join-Path $RepoRoot "libs/arm64-v8a" }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir "libant_aincrad.so"

$shadowDir = Join-Path $RepoRoot "prebuilt\arm64-v8a"
if (-not (Test-Path $shadowDir)) { $shadowDir = Join-Path $RepoRoot "prebuilt/arm64-v8a" }

$common = @(
    "--target=aarch64-linux-android$($chosen.Api)",
    "-shared", "-fPIC", "-O2", "-std=c++17",
    "-fno-exceptions", "-fno-rtti",
    "-Wall", "-Wno-unused-variable", "-Wno-unused-but-set-variable",
    "-Ijni",
    "-Wl,-soname,libant_aincrad.so",
    $src,
    "-L$shadowDir", "-lshadowhook",
    "-llog", "-lm",
    "-o", $out
)

# -nostdlib++ keeps us off libc++_shared entirely: the code uses only
# header-only pieces of <atomic>, so there is nothing to link. That also avoids
# mixing a brand-new NDK libc++ with the older libc++_shared.so the app ships.
$attempts = @(
    @("-nostdlib++") + $common,
    $common
)

$compileErrors = ""
$built = $false
Push-Location $RepoRoot
try {
    foreach ($args in $attempts) {
        Write-Host "   $($chosen.Path) $($args[0]) ..." -ForegroundColor DarkGray
        $compileErrors = (& $chosen.Path @args 2>&1) -join "`n"
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) { $built = $true; break }
        if ($compileErrors -match "unknown argument") {
            Warn "this clang rejects $($args[0]); retrying without it"
            continue
        }
        break
    }
} finally { Pop-Location }

if (-not $built) {
    Bad "compilation failed:"
    Write-Host ""
    Write-Host $compileErrors -ForegroundColor Red
    exit 1
}
Ok ("built {0:N0} bytes -> {1}" -f (Get-Item $out).Length, $out)

# ---------------------------------------------------------------------------
Step 4 "Verifying the exported JNI symbols"
# ---------------------------------------------------------------------------
if (Test-Path $nm) {
    $syms = (& $nm -D --defined-only $out 2>&1) -join "`n"
    $required = @(
        "Java_com_ffmodroot_ModBridge_isModLoaded",
        "Java_com_ffmodroot_ModBridge_setAimEnabled",
        "Java_com_ffmodroot_ModBridge_setAntibanEnabled",
        "Java_com_ffmodroot_ModBridge_setLobbyBypassEnabled",
        "Java_com_ffmodroot_ModBridge_setGameBypassEnabled",
        "Java_com_ffmodroot_ModBridge_isLobbyBypassActive",
        "Java_com_ffmodroot_ModBridge_isGameBypassActive",
        "Java_com_ffmodroot_Dumper_getBase",
        "Java_com_ffmodroot_Dumper_dumpOffsets",
        "Java_com_ffmodroot_Injector_initHooks",
        "Java_com_ffmodroot_Injector_getIl2cppBase",
        "_Z16ant_aincrad_initv"
    )
    $missing = @()
    foreach ($r in $required) { if ($syms -notmatch [regex]::Escape($r)) { $missing += $r } }

    if ($missing.Count -eq 0) {
        Ok "all $($required.Count) expected symbols present (matches ModBridge.kt)"
    } else {
        Bad "missing symbols: $($missing -join ', ')"
        exit 1
    }
    if ($syms -match "nativeInit") { Warn "nativeInit is exported - ModBridge.kt does not declare it" }
} else {
    Warn "llvm-nm not found; skipping symbol verification"
}

# ---------------------------------------------------------------------------
Step 5 "Copying into the Android project"
# ---------------------------------------------------------------------------
if ($NoCopy) { Write-Host ""; Ok "-NoCopy given, stopping here."; exit 0 }

$dst = Join-Path $TargetProject "app\src\main\jniLibs\arm64-v8a"
if (-not (Test-Path $dst)) { $dst = Join-Path $TargetProject "app/src/main/jniLibs/arm64-v8a" }

if (Test-Path $dst) {
    Copy-Item $out (Join-Path $dst "libant_aincrad.so") -Force
    Ok "copied to $dst"
    Get-ChildItem $dst -Filter *.so | ForEach-Object {
        Ok ("{0}  ({1:N0} bytes)" -f $_.Name, $_.Length)
    }
    Write-Host ""
    Ok "Now run .\fix_ffmodroot.ps1 to rebuild and reinstall the APK."
} else {
    Bad "target folder not found: $dst"
    Bad "Pass the correct one with -TargetProject C:\path\to\FFMODROOT"
    exit 1
}
