<#
  build_native.ps1
  ================
  Builds jni/core.cpp into libant_aincrad.so and copies it into the FFMODROOT
  project, replacing the old shipped binary.

  Why clang and not ndk-build
  ---------------------------
  With NDK 30, `ndk-build` aborts before compiling anything:

      Android NDK: APP_PLATFORM not set. Defaulting to minimum supported
                   version android-21.
      add-application.mk:88: *** Android NDK: Aborting...

  So we drive the NDK's clang++ directly:

      aarch64-linux-android<api>-clang++ --target=aarch64-linux-android<api> \
          -shared -fPIC -O2 -std=c++17 -fno-exceptions -fno-rtti -nostdlib++ \
          -Ijni core.cpp -Lprebuilt/arm64-v8a -lshadowhook -llog -lm -o ...

  jni/Android.mk and jni/Application.mk are kept for reference only.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1 -Api 24
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1 -Ndk "C:\Android\Sdk\ndk\26.1.10909125"
      powershell -ExecutionPolicy Bypass -File .\build_native.ps1 -NoCopy
#>

[CmdletBinding()]
param(
    # Deliberately empty by default. $PSScriptRoot is NOT reliable in a param
    # default under `powershell -File`, which is what produced
    # "Cannot bind argument to parameter 'Path' because it is an empty string".
    [string] $RepoRoot      = "",
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
Step 1 "Locating the repository"
# ---------------------------------------------------------------------------
# Try, in order: explicit -RepoRoot, the script's own folder, the session's
# definition path, the current directory. Accept the first one that has jni/.
$candidates = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { $candidates.Add($RepoRoot) }
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $candidates.Add($PSScriptRoot) }
if ($MyInvocation.MyCommand.Path) {
    $ownDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not [string]::IsNullOrWhiteSpace($ownDir)) { $candidates.Add($ownDir) }
}
if ($MyInvocation.MyCommand.Definition) {
    $ownDir2 = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (-not [string]::IsNullOrWhiteSpace($ownDir2)) { $candidates.Add($ownDir2) }
}
$here = (Get-Location).Path
if (-not [string]::IsNullOrWhiteSpace($here)) { $candidates.Add($here) }

$RepoRoot = $null
foreach ($c in $candidates) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    if (-not (Test-Path $c)) { continue }
    $probe = Join-Path $c "jni"
    if (Test-Path $probe) { $RepoRoot = (Resolve-Path $c).Path; break }
}

if (-not $RepoRoot) {
    Bad "Could not find the repository (a folder containing 'jni')."
    Write-Host "   Tried:" -ForegroundColor DarkGray
    foreach ($c in $candidates) { Write-Host "     - $c" -ForegroundColor DarkGray }
    Bad "Pass it explicitly: -RepoRoot C:\Users\anton\ANT-Aincrad-repo"
    exit 1
}
Ok "repo: $RepoRoot"

$coreSrc   = Join-Path $RepoRoot "jni\core.cpp"
if (-not (Test-Path $coreSrc)) { $coreSrc = Join-Path $RepoRoot "jni/core.cpp" }
if (-not (Test-Path $coreSrc)) { Bad "jni/core.cpp not found under $RepoRoot"; exit 1 }
Ok "source: $coreSrc"

$prebuilt  = Join-Path $RepoRoot "prebuilt\arm64-v8a"
if (-not (Test-Path $prebuilt)) { $prebuilt = Join-Path $RepoRoot "prebuilt/arm64-v8a" }
if (-not (Test-Path $prebuilt)) { Bad "prebuilt/arm64-v8a not found (libshadowhook.so lives there)"; exit 1 }

$outDir    = Join-Path $RepoRoot "libs\arm64-v8a"
if (-not (Test-Path $outDir)) { $outDir = Join-Path $RepoRoot "libs/arm64-v8a" }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outLib    = Join-Path $outDir "libant_aincrad.so"

# ---------------------------------------------------------------------------
Step 2 "Locating the NDK"
# ---------------------------------------------------------------------------
function Test-Ndk([string] $p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    if (-not (Test-Path $p)) { return $false }
    return (Test-Path (Join-Path $p "toolchains\llvm")) -or (Test-Path (Join-Path $p "toolchains/llvm"))
}

if (-not (Test-Ndk $Ndk)) {
    $ndkCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($env:ANDROID_NDK_HOME, $env:ANDROID_NDK_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Ndk $root)) { $ndkCandidates.Add($root) }
    }
    $sdkBases = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $sdkBases.Add((Join-Path $env:LOCALAPPDATA "Android\Sdk"))
    }
    foreach ($v in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "C:\Android\Sdk")) {
        if (-not [string]::IsNullOrWhiteSpace($v)) { $sdkBases.Add($v) }
    }
    foreach ($sdkBase in $sdkBases) {
        if (-not (Test-Path $sdkBase)) { continue }
        $ndkRoot = Join-Path $sdkBase "ndk"
        if (-not (Test-Path $ndkRoot)) { continue }
        $ndkCandidates.AddRange([string[]]@(Get-ChildItem $ndkRoot -Directory |
                                           Sort-Object Name -Descending |
                                           Select-Object -ExpandProperty FullName))
    }
    $Ndk = $null
    foreach ($c in $ndkCandidates) { if (Test-Ndk $c) { $Ndk = $c; break } }
}

if (-not (Test-Ndk $Ndk)) {
    Bad "No usable NDK found."
    Bad "Android Studio -> SDK Manager -> SDK Tools -> tick 'NDK (Side by side)' -> Apply."
    Bad "Then re-run, or pass -Ndk C:\path\to\ndk\26.1.10909125"
    exit 1
}
Ok "NDK: $Ndk"

# ---------------------------------------------------------------------------
Step 3 "Locating the clang toolchain"
# ---------------------------------------------------------------------------
$llvmRoot = Join-Path $Ndk "toolchains\llvm\prebuilt"
if (-not (Test-Path $llvmRoot)) { $llvmRoot = Join-Path $Ndk "toolchains/llvm/prebuilt" }
if (-not (Test-Path $llvmRoot)) { Bad "no toolchains/llvm/prebuilt under $Ndk"; exit 1 }

$hostDir = Get-ChildItem $llvmRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $hostDir) { Bad "no host toolchain folder under $llvmRoot"; exit 1 }
$bin = Join-Path $hostDir.FullName "bin"
Ok "toolchain: $($hostDir.Name)"

# On Windows the NDK ships target wrappers as .cmd batch files, but some
# releases also contain an extensionless POSIX shell script with the same name,
# which PowerShell cannot execute. Only ever pick something Windows can run.
$isWin = $false
if ($env:OS -eq "Windows_NT") { $isWin = $true }
if (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) { $isWin = $true }

$parsed = @()
foreach ($w in @(Get-ChildItem $bin -ErrorAction SilentlyContinue)) {
    if ($w.Name -notmatch '^aarch64-linux-android(\d+)-clang\+\+(\.cmd|\.exe)?$') { continue }
    $apiLevel = [int]$Matches[1]
    $ext      = $Matches[2]
    if ($isWin -and [string]::IsNullOrEmpty($ext)) { continue }   # not runnable here
    $rank = 2
    if ($ext -eq ".cmd") { $rank = 0 } elseif ($ext -eq ".exe") { $rank = 1 }
    $parsed += [pscustomobject]@{ Api = $apiLevel; Path = $w.FullName; Name = $w.Name; Rank = $rank }
}

$chosen = $null
if ($Api -gt 0) {
    $chosen = $parsed | Where-Object { $_.Api -eq $Api } | Sort-Object Rank | Select-Object -First 1
    if (-not $chosen) {
        Warn "no runnable api-$Api wrapper in this NDK; available: $(($parsed.Api | Sort-Object -Unique) -join ', ')"
    }
}
if (-not $chosen) { $chosen = $parsed | Where-Object { $_.Api -eq 24 }   | Sort-Object Rank     | Select-Object -First 1 }
if (-not $chosen) { $chosen = $parsed | Where-Object { $_.Api -ge 21 }   | Sort-Object Api, Rank | Select-Object -First 1 }
if (-not $chosen) { $chosen = $parsed | Sort-Object Api, Rank | Select-Object -First 1 }

if ($chosen) {
    Ok "compiler: $($chosen.Name)  (api $($chosen.Api))"
} else {
    # Last resort: the plain compiler. We pass --target explicitly anyway, so
    # this is equivalent to going through the wrapper.
    $plain = $null
    foreach ($name in @("clang++.exe", "clang++.cmd", "clang++")) {
        $probe = Join-Path $bin $name
        if (-not (Test-Path $probe)) { continue }
        if ($isWin -and [string]::IsNullOrEmpty([System.IO.Path]::GetExtension($probe))) { continue }
        $plain = $probe
        break
    }
    if (-not $plain) {
        Bad "No runnable clang++ in $bin"
        Get-ChildItem $bin -Filter "*clang*" | Select-Object -First 15 |
            ForEach-Object { Write-Host "     $($_.Name)" -ForegroundColor DarkGray }
        exit 1
    }
    $chosen = [pscustomobject]@{ Api = 24; Path = $plain; Name = (Split-Path -Leaf $plain); Rank = 9 }
    Warn "using the plain compiler directly: $($chosen.Name)"
}

$nm = Join-Path $bin "llvm-nm.exe"
if (-not (Test-Path $nm)) { $nm = Join-Path $bin "llvm-nm" }
if (-not (Test-Path $nm)) { $nm = $null }

# ---------------------------------------------------------------------------
Step 4 "Compiling core.cpp"
# ---------------------------------------------------------------------------
$common = @(
    "--target=aarch64-linux-android$($chosen.Api)"
    "-shared"
    "-fPIC"
    "-O2"
    "-std=c++17"
    "-fno-exceptions"
    "-fno-rtti"
    "-Wall"
    "-Wno-unused-variable"
    "-Wno-unused-but-set-variable"
    "-Ijni"
    "-Wl,-soname,libant_aincrad.so"
    $coreSrc
    ("-L" + $prebuilt)
    "-lshadowhook"
    "-llog"
    "-lm"
    "-o"
    $outLib
)

# -nostdlib++ keeps us off libc++ entirely: the code only uses header-only
# parts of <atomic>, so nothing needs libc++ at link time. That also avoids
# mixing a brand-new NDK libc++ with the older libc++_shared.so the app ships.
$attempts = @(
    (@("-nostdlib++") + $common),
    $common
)

$compileLog = ""
$built = $false

# clang writes diagnostics to stderr. With ErrorActionPreference=Stop PowerShell
# turns each stderr line of a native command into a terminating error, which
# would abort before we can read $LASTEXITCODE. Relax it just for the call.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    foreach ($argList in $attempts) {
        Write-Host "   `"$($chosen.Path)`" $($argList[0]) ..." -ForegroundColor DarkGray
        $compileLog = (& $chosen.Path @argList 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($code -eq 0 -and (Test-Path $outLib)) { $built = $true; break }
        if ($compileLog -match "unknown argument") {
            Warn "this clang rejects $($argList[0]); retrying without it"
            continue
        }
        break
    }
} finally {
    $ErrorActionPreference = $prevEap
}

if (-not $built) {
    Bad "compilation failed:"
    Write-Host ""
    Write-Host $compileLog -ForegroundColor Red
    exit 1
}
Ok ("built {0:N0} bytes -> {1}" -f (Get-Item $outLib).Length, $outLib)

# ---------------------------------------------------------------------------
Step 5 "Verifying the exported JNI symbols"
# ---------------------------------------------------------------------------
if ($nm) {
    $prevEap2 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $syms = (& $nm -D --defined-only $outLib 2>&1 | Out-String) }
    finally { $ErrorActionPreference = $prevEap2 }

    $required = @(
        "Java_com_ffmodroot_ModBridge_isModLoaded"
        "Java_com_ffmodroot_ModBridge_setAimEnabled"
        "Java_com_ffmodroot_ModBridge_setAntibanEnabled"
        "Java_com_ffmodroot_ModBridge_setLobbyBypassEnabled"
        "Java_com_ffmodroot_ModBridge_setGameBypassEnabled"
        "Java_com_ffmodroot_ModBridge_isLobbyBypassActive"
        "Java_com_ffmodroot_ModBridge_isGameBypassActive"
        "Java_com_ffmodroot_Dumper_getBase"
        "Java_com_ffmodroot_Dumper_dumpOffsets"
        "Java_com_ffmodroot_Injector_initHooks"
        "Java_com_ffmodroot_Injector_getIl2cppBase"
        "_Z16ant_aincrad_initv"
    )

    $missing = @()
    foreach ($r in $required) {
        if ($syms -notmatch [regex]::Escape($r)) { $missing += $r }
    }

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
Step 6 "Copying into the Android project"
# ---------------------------------------------------------------------------
if ($NoCopy) { Write-Host ""; Ok "-NoCopy given, stopping here."; exit 0 }

$dst = Join-Path $TargetProject "app\src\main\jniLibs\arm64-v8a"
if (-not (Test-Path $dst)) { $dst = Join-Path $TargetProject "app/src/main/jniLibs/arm64-v8a" }

if (Test-Path $dst) {
    Copy-Item -Path $outLib -Destination (Join-Path $dst "libant_aincrad.so") -Force
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
