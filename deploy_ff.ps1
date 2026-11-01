<#
  deploy_ff.ps1
  =============
  Loads libant_aincrad.so INSIDE the Free Fire process.

  This is the step that actually makes the features do something.

  Background
  ----------
  libant_aincrad.so does this when it initialises:

        fopen("/proc/self/maps") -> look for "libil2cpp.so"
        -> if found:  resolve the offset table, hook SetAimRotation
        -> if absent: log "libil2cpp.so not found" and stop

  com.ffmodroot is a launcher/UI app. libil2cpp.so lives in Free Fire's
  process, never in the launcher's. So the aim thread always timed out, no hook
  was ever installed, and the Compose toggles were flipping flags in a process
  that had nothing to steer. That is exactly "features turn on but nothing
  happens".

  The fix is to preload the module into the game process with the Android
  "wrap" property, which Zygote honours for a named package:

        setprop wrap.<package> "LD_PRELOAD=/data/local/tmp/libant_aincrad.so ANT_AINCRAD_AUTOINIT=1"

  The library's __attribute__((constructor)) sees ANT_AINCRAD_AUTOINIT=1 and
  calls ant_aincrad_init() itself, so no ptrace injection is required.

  The UI keeps working: it writes /data/local/tmp/ant_aincrad.cfg and the
  in-game copy of the library polls that file for the toggle states.

  Requirements: rooted BlueStacks, `adb root` working, game force-stopped first.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\deploy_ff.ps1
      powershell -ExecutionPolicy Bypass -File .\deploy_ff.ps1 -Package com.dts.freefiremax
      powershell -ExecutionPolicy Bypass -File .\deploy_ff.ps1 -Undeploy
#>

[CmdletBinding()]
param(
    [string] $RepoRoot  = $PSScriptRoot,
    [string] $Serial    = "127.0.0.1:5555",
    [string] $Package   = "com.dts.freefireth",
    [string] $DeviceDir = "/data/local/tmp",
    [switch] $Undeploy
)

$ErrorActionPreference = "Continue"

function Step($n, $t) { Write-Host ""; Write-Host "== [$n] $t " -ForegroundColor Cyan; Write-Host ("-" * 70) -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red }

function Adb([string[]] $args_) { & adb -s $Serial @args_ 2>&1 }
function Sh([string]  $cmd)     { & adb -s $Serial shell su -c $cmd 2>&1 }

Step 0 "Checking adb + root"
$dev = (& adb devices) -join "`n"
if ($dev -notmatch [regex]::Escape($Serial)) {
    Warn "$Serial not connected, trying adb connect"
    & adb connect $Serial | Out-Host
    Start-Sleep -Seconds 2
}
$whoami = (Sh "id") -join " "
Write-Host "   su id -> $whoami"
if ($whoami -notmatch "uid=0") {
    Bad "root shell not available. In BlueStacks enable Settings -> Advanced -> Android root,"
    Bad "then:  adb -s $Serial root   (and re-run this script)"
    exit 1
}
Ok "root available"

# ---------------------------------------------------------------------------
if ($Undeploy) {
    Step 1 "Removing the preload hook"
    Sh "setprop wrap.$Package ''" | Out-Null
    Sh "rm -f $DeviceDir/libant_aincrad.so $DeviceDir/libshadowhook.so $DeviceDir/libc++_shared.so" | Out-Null
    Ok "undeployed (restart the game for it to take effect)"
    exit 0
}

# ---------------------------------------------------------------------------
Step 1 "Pushing the native libraries"
$libs = @("libant_aincrad.so", "libshadowhook.so", "libc++_shared.so")
$srcDirs = @(
    (Join-Path $RepoRoot "libs\arm64-v8a"),
    (Join-Path $RepoRoot "prebuilt\arm64-v8a"),
    "C:\Users\anton\AndroidStudioProjects\FFMODROOT\app\src\main\jniLibs\arm64-v8a"
)

foreach ($lib in $libs) {
    $found = $null
    foreach ($d in $srcDirs) {
        $candidate = Join-Path $d $lib
        if (Test-Path $candidate) { $found = $candidate; break }
    }
    if (-not $found) { Bad "cannot find $lib in any of: $($srcDirs -join ', ')"; exit 1 }

    & adb -s $Serial push $found "$DeviceDir/$lib" | Out-Null
    if ($LASTEXITCODE -ne 0) { Bad "push failed: $lib"; exit 1 }
    Sh "chmod 755 $DeviceDir/$lib" | Out-Null
    Ok ("pushed {0} ({1:N0} bytes)" -f $lib, (Get-Item $found).Length)
}

# ---------------------------------------------------------------------------
Step 2 "Preparing the shared toggle file"
# The launcher app runs as its own uid and cannot create files in
# /data/local/tmp, so we create it world-writable once, here.
Sh "touch $DeviceDir/ant_aincrad.cfg; chmod 666 $DeviceDir/ant_aincrad.cfg" | Out-Null
$cfg = (Sh "ls -l $DeviceDir/ant_aincrad.cfg") -join " "
Write-Host "   $cfg"
Ok "toggle file ready (the UI writes aim=1 / antiban=1 / ... into it)"

# ---------------------------------------------------------------------------
Step 3 "Installing the preload for $Package"
Sh "setprop wrap.$Package 'LD_PRELOAD=$DeviceDir/libant_aincrad.so LD_LIBRARY_PATH=$DeviceDir ANT_AINCRAD_AUTOINIT=1'" | Out-Null

$verify = (Sh "getprop wrap.$Package") -join ""
if ($verify -match "libant_aincrad") { Ok "wrap.$Package = $verify" }
else { Bad "setprop did not stick (got '$verify')"; exit 1 }

# Bluestacks' zygote caches props per boot on some images; a game restart is
# enough, a full `adb shell stop; start` is the fallback.
& adb -s $Serial shell am force-stop $Package | Out-Null
Start-Sleep -Seconds 1

# ---------------------------------------------------------------------------
Step 4 "Launching the game"
& adb -s $Serial logcat -c | Out-Null
& adb -s $Serial shell monkey -p $Package -c android.intent.category.LAUNCHER 1 | Out-Null

Write-Host "   waiting for the game process to come up..."
$pid_ = ""
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $pid_ = ((& adb -s $Serial shell pidof $Package) -join "").Trim()
    if ($pid_ -ne "") { break }
}
if ($pid_ -eq "") { Bad "game process did not start - launch it from the BlueStacks window and re-run step 4 manually"; exit 1 }
Ok "game pid = $pid_"

# ---------------------------------------------------------------------------
Step 5 "Verifying that the module really is inside the game"
Start-Sleep -Seconds 8
Write-Host ""
Write-Host "   --- ANT-Aincrad log inside the game ---" -ForegroundColor DarkGray
& adb -s $Serial logcat -d -s ANT_Aincrad_Core ANT_Aincrad_Dumper ANT_Aincrad_Injector |
    Select-Object -Last 40 | ForEach-Object { Write-Host "   $_" }

Write-Host ""
$maps = (& adb -s $Serial shell "cat /proc/$pid_/maps | grep -c ant_aincrad") -join ""
if ($maps.Trim() -match '^[1-9]') { Ok "libant_aincrad.so is loaded in the game process ($($maps.Trim()) mappings)" }
else { Warn "module not visible in /proc/$pid_/maps - check the log above" }

Write-Host ""
Write-Host "Expected in the log:" -ForegroundColor Yellow
Write-Host "   ANT-Aincrad initialising..."        -ForegroundColor Yellow
Write-Host "   bypass: sendto=OK send=OK"           -ForegroundColor Yellow
Write-Host "   libil2cpp.so located"                -ForegroundColor Yellow
Write-Host "   SetAimRotation RVA=0x11ad820"        -ForegroundColor Yellow
Write-Host "   aim hook live"                       -ForegroundColor Yellow
Write-Host ""
Write-Host "Then open FFMODROOT, flip a toggle, and watch the .cfg file:" -ForegroundColor Yellow
Write-Host "   adb -s $Serial shell su -c 'cat /data/local/tmp/ant_aincrad.cfg'" -ForegroundColor White
