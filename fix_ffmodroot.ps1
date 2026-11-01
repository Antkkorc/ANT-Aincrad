<#
  fix_ffmodroot.ps1
  =================
  Fixes the FFMODROOT Android project build and installs it on BlueStacks.

  Why the build was failing (not a BOM problem - the BOM was a symptom):

    Android Studio's Kotlin sources already define all four classes:
        com.ffmodroot.MainActivity   (MainActivity.kt  - Compose UI)
        com.ffmodroot.ModBridge      (ModBridge.kt)
        com.ffmodroot.RootInjector   (RootInjector.kt)
    The generated Dumper.java / Injector.java / MainActivity.java /
    ModBridge.java declared the SAME classes, so even with the byte-order mark
    removed javac would have failed with "duplicate class".
    On top of that ModBridge.java declared nativeInit(), which does not exist
    in libant_aincrad.so -> UnsatisfiedLinkError at runtime.

  This script therefore DELETES those four .java files instead of rewriting
  them, then builds with a hard stop so we never install a stale APK again.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1
      powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1 -Serial 127.0.0.1:5555
      powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1 -BuildOnly
#>

[CmdletBinding()]
param(
    [string] $ProjectRoot = "C:\Users\anton\AndroidStudioProjects\FFMODROOT",
    [string] $Serial      = "127.0.0.1:5555",
    [string] $Package     = "com.ffmodroot",
    [switch] $BuildOnly
)

$ErrorActionPreference = "Stop"
$script:failed = $false

function Step($n, $t) {
    Write-Host ""
    Write-Host "== [$n] $t " -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor DarkGray
}
function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# adb device recovery
# ---------------------------------------------------------------------------
# "adb: device offline" means the adb *transport* is stale, not that the app is
# broken. It happens constantly with BlueStacks because the emulator restarts
# its adbd when the VM pauses/resumes. Walk the standard ladder instead of
# making the user do it by hand.
function Get-AdbState([string] $serial) {
    $out = (& adb -s $serial get-state 2>&1) -join " "
    if ($out -match "device")   { return "device" }
    if ($out -match "offline")  { return "offline" }
    if ($out -match "unauthorized") { return "unauthorized" }
    return "absent"
}

function Wait-AdbDevice([string] $serial, [int] $timeoutSec = 45) {
    if ((Get-AdbState $serial) -eq "device") { return $true }

    $steps = @(
        @{ Name = "adb reconnect offline"; Run = { & adb reconnect offline 2>&1 | Out-Null } },
        @{ Name = "adb disconnect + connect"; Run = {
                & adb disconnect $serial 2>&1 | Out-Null
                Start-Sleep -Milliseconds 500
                & adb connect $serial 2>&1 | Out-Null } },
        @{ Name = "restart adb server"; Run = {
                & adb kill-server 2>&1 | Out-Null
                Start-Sleep -Milliseconds 800
                & adb start-server 2>&1 | Out-Null
                Start-Sleep -Milliseconds 800
                & adb connect $serial 2>&1 | Out-Null } }
    )

    foreach ($step in $steps) {
        Warn ("device is not ready - trying: " + $step.Name)
        try { & $step.Run } catch { }
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if ((Get-AdbState $serial) -eq "device") {
                Ok ("device ready after: " + $step.Name)
                return $true
            }
        }
    }

    # Last resort: a full emulator restart is the only thing left.
    $state = Get-AdbState $serial
    Bad "device still '$state' after every recovery step."
    Write-Host ""
    Write-Host "   Do this once, then re-run the script:" -ForegroundColor Yellow
    Write-Host "     1. In BlueStacks: close the emulator completely (not minimise)" -ForegroundColor White
    Write-Host "     2. adb kill-server" -ForegroundColor White
    Write-Host "     3. Start BlueStacks, wait for the home screen" -ForegroundColor White
    Write-Host "     4. adb connect $serial" -ForegroundColor White
    Write-Host "     5. adb devices   # must say 'device', not 'offline'" -ForegroundColor White
    Write-Host ""
    Write-Host "   The APK is already built and valid:" -ForegroundColor Yellow
    Write-Host "     $apk" -ForegroundColor White
    Write-Host "   Install it yourself once the device is back:" -ForegroundColor Yellow
    Write-Host "     adb -s $serial install -r `"$apk`"" -ForegroundColor White
    return $false
}

# ---------------------------------------------------------------------------
# 0. sanity
# ---------------------------------------------------------------------------
Step 0 "Checking project layout"
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-Location).Path }
if (-not (Test-Path $ProjectRoot)) {
    # Fall back to the current directory if it looks like the Android project.
    if (Test-Path (Join-Path (Get-Location) "gradlew.bat")) {
        $ProjectRoot = (Get-Location).Path
        Warn "using current directory as project root: $ProjectRoot"
    } else {
        Bad "Project not found: $ProjectRoot"
        Bad "Pass it explicitly:  -ProjectRoot C:\path\to\FFMODROOT"
        exit 1
    }
}

$AppDir  = Join-Path $ProjectRoot "app"
$JavaDir = Join-Path $AppDir "src\main\java\com\ffmodroot"
$JniLibs = Join-Path $AppDir "src\main\jniLibs\arm64-v8a"
$Gradlew = Join-Path $ProjectRoot "gradlew.bat"

foreach ($p in @($AppDir, $JavaDir, $Gradlew)) {
    if (Test-Path $p) { Ok $p } else { Bad "missing: $p"; $script:failed = $true }
}
if ($script:failed) { exit 1 }

# ---------------------------------------------------------------------------
# 1. remove the four duplicate Java classes
# ---------------------------------------------------------------------------
Step 1 "Removing duplicate generated Java classes"
$dupes = @("MainActivity.java", "ModBridge.java", "Dumper.java", "Injector.java")
$backup = Join-Path $ProjectRoot "_removed_java_backup"
if (-not (Test-Path $backup)) { New-Item -ItemType Directory -Force -Path $backup | Out-Null }

foreach ($f in $dupes) {
    $path = Join-Path $JavaDir $f
    if (Test-Path $path) {
        Copy-Item $path (Join-Path $backup $f) -Force
        Remove-Item $path -Force
        Ok "deleted $f (backup in _removed_java_backup)"
    } else {
        Ok "$f already absent"
    }
}

# ---------------------------------------------------------------------------
# 2. strip a UTF-8 BOM from EVERY java/kotlin source (harmless if none)
# ---------------------------------------------------------------------------
Step 2 "Stripping UTF-8 BOM from every .java / .kt source"
$fixed = 0
Get-ChildItem -Path (Join-Path $AppDir "src") -Recurse -Include *.java, *.kt -File | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $body = New-Object byte[] ($bytes.Length - 3)
        [Array]::Copy($bytes, 3, $body, 0, $body.Length)
        # WriteAllBytes with a BOM-less encoder result: just write the raw bytes.
        [System.IO.File]::WriteAllBytes($_.FullName, $body)
        Ok "BOM removed: $($_.Name)"
        $fixed++
    }
}
if ($fixed -eq 0) { Ok "no BOM found in any source file" }

# ---------------------------------------------------------------------------
# 3. show which native methods the Kotlin side actually declares
# ---------------------------------------------------------------------------
Step 3 "Native declarations found in the Kotlin sources"
$kt = Get-ChildItem -Path $JavaDir -Filter *.kt -File -ErrorAction SilentlyContinue
foreach ($f in $kt) {
    Write-Host "   --- $($f.Name) ---" -ForegroundColor DarkGray
    Select-String -Path $f.FullName -Pattern "external fun|System\.loadLibrary|class |object " |
        ForEach-Object { Write-Host ("   {0,4}: {1}" -f $_.LineNumber, $_.Line.Trim()) }
}

# ---------------------------------------------------------------------------
# 4. verify the native libraries that will be packaged
# ---------------------------------------------------------------------------
Step 4 "Native libraries to be packaged"
if (Test-Path $JniLibs) {
    Get-ChildItem $JniLibs -Filter *.so | ForEach-Object {
        Ok ("{0}  ({1:N0} bytes)" -f $_.Name, $_.Length)
    }
    $core = Join-Path $JniLibs "libant_aincrad.so"
    if (-not (Test-Path $core)) {
        Bad "libant_aincrad.so missing from $JniLibs - the app would crash on System.loadLibrary"
        $script:failed = $true
    }
} else {
    Bad "jniLibs folder missing: $JniLibs"
    $script:failed = $true
}
if ($script:failed) { exit 1 }

# ---------------------------------------------------------------------------
# 4b. overlay permission must be DECLARED in the manifest, not just appops'd
# ---------------------------------------------------------------------------
# Proves itself in the failure message:
#     Security exception: Package com.ffmodroot has not requested permission
#     android.permission.SYSTEM_ALERT_WINDOW
# That happens when add_floating_menu.ps1 patched the source manifest AFTER the
# APK was built, so the installed APK never declared it. An AppOp of "allow"
# cannot compensate: Settings.canDrawOverlays() still returns false and
# addView(TYPE_APPLICATION_OVERLAY) throws.
Step "4b" "Checking the overlay permission in AndroidManifest.xml"
$manifest = Join-Path $AppDir "src\main\AndroidManifest.xml"
if (-not (Test-Path $manifest)) {
    Warn "manifest not found at $manifest - skipping"
} else {
    $overlayService = Join-Path $JavaDir "OverlayMenuService.kt"
    $raw = [System.IO.File]::ReadAllText($manifest)
    $declared = $raw -match 'SYSTEM_ALERT_WINDOW'

    if ($declared) {
        Ok "SYSTEM_ALERT_WINDOW is declared"
    } elseif (Test-Path $overlayService) {
        Warn "OverlayMenuService.kt exists but the manifest does not declare SYSTEM_ALERT_WINDOW"
        Warn "adding it now (this is why 'pm grant' said 'has not requested permission')"
        try {
            $NS = "http://schemas.android.com/apk/res/android"
            [xml]$doc = Get-Content -Raw $manifest
            $root = $doc.DocumentElement
            $el = $doc.CreateElement("uses-permission")
            $el.SetAttribute("name", $NS, "android.permission.SYSTEM_ALERT_WINDOW")
            [void]$root.PrependChild($el)
            $xset = New-Object System.Xml.XmlWriterSettings
            $xset.Indent = $true
            $xset.IndentChars = "    "
            $xset.Encoding = New-Object System.Text.UTF8Encoding($false)
            $xw = [System.Xml.XmlWriter]::Create($manifest, $xset)
            try { $doc.Save($xw) } finally { $xw.Close() }
            Ok "SYSTEM_ALERT_WINDOW added to the manifest"
        } catch {
            Bad "could not patch the manifest: $($_.Exception.Message)"
            $script:failed = $true
        }
    } else {
        Ok "no overlay in this project - permission not needed"
    }
}
if ($script:failed) { exit 1 }

# ---------------------------------------------------------------------------
# 5. clean build - hard stop on failure
# ---------------------------------------------------------------------------
Step 5 "Building the APK (clean, no stale artefacts)"
Push-Location $ProjectRoot
$prevEap = $ErrorActionPreference
# Gradle writes errors to stderr; with Stop, PowerShell would raise a
# terminating NativeCommandError before we can inspect $LASTEXITCODE.
$ErrorActionPreference = "Continue"
try {
    & .\gradlew.bat clean 2>&1 | Out-Host
    & .\gradlew.bat assembleDebug 2>&1 | Out-Host
    $buildExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
    Pop-Location
}

if ($buildExit -ne 0) {
    Bad "assembleDebug FAILED (exit $buildExit)."
    Write-Host ""
    Write-Host "   Nothing was installed - the old APK would just crash again." -ForegroundColor Yellow
    Write-Host "   Re-run with the full log to see the first error:" -ForegroundColor Yellow
    Write-Host "       .\gradlew.bat assembleDebug --stacktrace" -ForegroundColor White
    exit $buildExit
}
Ok "build succeeded"

$apk = Join-Path $AppDir "build\outputs\apk\debug\app-debug.apk"
if (-not (Test-Path $apk)) { Bad "APK not found: $apk"; exit 1 }
$apkInfo = Get-Item $apk
Ok ("APK {0} - {1:N0} bytes - {2}" -f $apkInfo.Name, $apkInfo.Length, $apkInfo.LastWriteTime)

# ---------------------------------------------------------------------------
# 5b. prove the NEW .so is actually inside the APK
# ---------------------------------------------------------------------------
# Total APK size is not a reliable indicator: the native libs are deflated, so a
# bigger .so can produce a near-identical archive. Read the zip directory and
# report the real uncompressed entry size instead.
Step "5b" "Verifying the native library inside the APK"
$oldShippedSize = 15232   # the stale binary we are replacing
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $abiEntries = $zip.Entries | Where-Object { $_.FullName -match '^lib/[^/]+/.*\.so$' }
        if (-not $abiEntries) {
            Bad "APK contains no lib/**/*.so at all - System.loadLibrary will fail"
            $script:apkNativeOk = $false
        } else {
            foreach ($e in ($abiEntries | Sort-Object FullName)) {
                Write-Host ("   {0,-46} {1,12:N0} bytes (stored {2:N0})" -f $e.FullName, $e.Length, $e.CompressedLength)
            }
            $core = $abiEntries | Where-Object { $_.FullName -like "*libant_aincrad.so" }
            if (-not $core) {
                Bad "libant_aincrad.so is missing from the APK"
                $script:apkNativeOk = $false
            } elseif ($core.Length -eq $oldShippedSize) {
                Bad ("libant_aincrad.so in the APK is {0:N0} bytes - that is the OLD binary" -f $core.Length)
                Bad "the rebuild in build_native.ps1 did not reach jniLibs; re-run it, then this script"
                $script:apkNativeOk = $false
            } elseif ($core.Length -lt 8000) {
                Bad ("libant_aincrad.so in the APK is only {0:N0} bytes - truncated or stripped badly" -f $core.Length)
                $script:apkNativeOk = $false
            } else {
                Ok ("libant_aincrad.so packaged at {0:N0} bytes (old binary was {1:N0})" -f $core.Length, $oldShippedSize)
                $script:apkNativeOk = $true
            }
            $shadow = $abiEntries | Where-Object { $_.FullName -like "*libshadowhook.so" }
            if ($shadow) { Ok ("libshadowhook.so packaged at {0:N0} bytes" -f $shadow.Length) }
            else { Bad "libshadowhook.so missing - ant_aincrad depends on it and will not load"; $script:apkNativeOk = $false }
        }
    } finally {
        $zip.Dispose()
    }
} catch {
    Warn "could not inspect the APK ($($_.Exception.Message)); continuing"
    $script:apkNativeOk = $true
}

if (-not $script:apkNativeOk) {
    Bad "Refusing to install a broken APK."
    exit 1
}

if ($BuildOnly) { Write-Host ""; Ok "BuildOnly requested - stopping here."; exit 0 }

# ---------------------------------------------------------------------------
# 6. install on BlueStacks
# ---------------------------------------------------------------------------
Step 6 "Deploying to $Serial"
$prevEap2 = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
if (-not (Wait-AdbDevice $Serial)) { exit 1 }

& adb -s $Serial shell am force-stop $Package 2>&1 | Out-Null
& adb -s $Serial uninstall $Package 2>&1 | Out-Null

$installOk = $false
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $installOut = (& adb -s $Serial install -r $apk 2>&1) -join "`n"
    $installOut | Out-Host
    if ($installOut -match "Success") { $installOk = $true; break }

    if ($installOut -match "offline") {
        Warn "device went offline mid-install (attempt $attempt) - recovering"
        if (-not (Wait-AdbDevice $Serial)) { exit 1 }
    } elseif ($installOut -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match") {
        Warn "signature mismatch - doing a clean uninstall first"
        & adb -s $Serial uninstall $Package 2>&1 | Out-Host
        if (-not (Wait-AdbDevice $Serial)) { exit 1 }
    } else {
        break
    }
}

if (-not $installOk) {
    Bad "adb install failed - the APK is built and valid:"
    Write-Host "     $apk" -ForegroundColor White
    Write-Host "   Retry manually once the device is responsive:" -ForegroundColor Yellow
    Write-Host "     adb -s $Serial install -r `"$apk`"" -ForegroundColor White
    exit 1
}
Ok "installed"

# ---------------------------------------------------------------------------
# 6b. re-apply the overlay AppOp
# ---------------------------------------------------------------------------
# This script uninstalls the package before installing, which RESETS its AppOps.
# So the grant has to be repeated after every install - otherwise the menu
# silently never appears even though the manifest declares the permission.
Step "6b" "Re-applying the SYSTEM_ALERT_WINDOW AppOp"
$rawManifest2 = ""
if (Test-Path $manifest) { $rawManifest2 = [System.IO.File]::ReadAllText($manifest) }

if ($rawManifest2 -match "SYSTEM_ALERT_WINDOW") {
    $opBefore = ((& adb -s $Serial shell appops get $Package SYSTEM_ALERT_WINDOW 2>&1) -join " ").Trim()
    Write-Host "   appops before -> $opBefore"

    if ($opBefore -notmatch "allow") {
        & adb -s $Serial shell appops set $Package SYSTEM_ALERT_WINDOW allow 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
    }
    $opAfter = ((& adb -s $Serial shell appops get $Package SYSTEM_ALERT_WINDOW 2>&1) -join " ").Trim()
    Write-Host "   appops after  -> $opAfter"
    if ($opAfter -match "allow") {
        Ok "overlay AppOp is allow"
    } else {
        Warn "AppOp is '$opAfter' - the menu will not appear. Rooted fallback:"
        Write-Host "     adb -s $Serial shell su -c 'appops set $Package SYSTEM_ALERT_WINDOW allow'" -ForegroundColor White
    }
} else {
    Warn "manifest does not declare SYSTEM_ALERT_WINDOW - skipping (run add_floating_menu.ps1)"
}

# ---------------------------------------------------------------------------
# 7. launch and capture the REAL runtime state
# ---------------------------------------------------------------------------
Step 7 "Launching and capturing logcat"
& adb -s $Serial logcat -c 2>&1 | Out-Null
& adb -s $Serial shell am start -n "$Package/.MainActivity" 2>&1 | Out-Host
Start-Sleep -Seconds 6

Write-Host ""
Write-Host "   --- crash buffer ---" -ForegroundColor DarkGray
& adb -s $Serial logcat -b crash -d -t 80 2>&1 | Out-Host

Write-Host ""
Write-Host "   --- app log ---" -ForegroundColor DarkGray
$appLog = & adb -s $Serial logcat -d -t 300 2>&1 |
    Select-String -Pattern "ANT-Aincrad|ANT_Aincrad|ffmodroot|AndroidRuntime|UnsatisfiedLink|FATAL"
$appLog | ForEach-Object { $_.Line }

Write-Host ""
# ModBridge is a Kotlin `object`, so System.loadLibrary() only runs the first
# time the UI touches it. A freshly launched app sitting on its first screen
# therefore legitimately shows no native log at all.
$text = ($appLog | Out-String)
if ($text -match "ANT-Aincrad loaded passively") {
    Ok "native module loaded and running (launcher mode)"
} elseif ($text -match "UnsatisfiedLinkError|dlopen failed") {
    Bad "the .so failed to load - see the error above"
} elseif ($text -match "libil2cpp.so not found") {
    Ok "module initialised but no game in this process - expected; run deploy_ff.ps1"
} else {
    Warn "no native log yet. ModBridge is a Kotlin object, so the library loads only"
    Warn "the first time a toggle is touched. Open ANT AINCRAD, flip a switch, then run:"
    Write-Host "      adb -s $Serial logcat -d | Select-String 'ANT-Aincrad'" -ForegroundColor White
}

Write-Host ""
Write-Host "If you see 'libil2cpp.so not found' that is EXPECTED in the launcher" -ForegroundColor Yellow
Write-Host "process. It means the toggles have nothing to steer - run deploy_ff.ps1" -ForegroundColor Yellow
Write-Host "to load the module inside Free Fire instead." -ForegroundColor Yellow
} finally {
    $ErrorActionPreference = $prevEap2
}
