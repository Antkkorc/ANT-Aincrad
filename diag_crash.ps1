<#
  diag_crash.ps1
  ==============
  Catches the crash you get when you tap "Free Fire" / "Free Fire Max" and
  prints BOTH the stack trace AND the source lines that caused it.

  Why a script instead of "send me the log": the crash is in code inside
  AndroidStudioProjects\FFMODROOT, which is not in the repo. A bare logcat dump
  tells me where, but not what the code does. This does both in one paste.

  Usage
  -----
      powershell -ExecutionPolicy Bypass -File .\diag_crash.ps1

  Then, while it counts down, tap the Free Fire option in the app. It records
  whatever happens, including a crash.

  Options
  -------
      -Watch 30          seconds to wait for you to reproduce the crash
      -ProjectRoot PATH  where AndroidManifest.xml / src live
      -Serial            default 127.0.0.1:5555 (never picks another device)
      -OutFile PATH      also write the report to a file
#>

[CmdletBinding()]
param(
    # Empty on purpose: $PSScriptRoot is unreliable as a param default under
    # `powershell -File` and used to cause "Path ... empty string" failures.
    [string] $ProjectRoot = "",
    [string] $Serial      = "127.0.0.1:5555",
    [string] $Package     = "com.ffmodroot",
    [int]    $Watch       = 30,
    [string] $OutFile     = ""
)

$ErrorActionPreference = "Continue"

function Step($t)   { Write-Host ""; Write-Host "== $t " -ForegroundColor Cyan; Write-Host ("-" * 70) -ForegroundColor DarkGray }
function Ok($m)     { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m)   { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)    { Write-Host "   [FAIL] $m" -ForegroundColor Red }
function Note($m)   { Write-Host "   $m" -ForegroundColor Gray }

$script:report = New-Object System.Collections.Generic.List[string]
function Capture($text) {
    Write-Host $text
    [void]$script:report.Add($text)
}

# ---------------------------------------------------------------------------
# 0. locate the project
# ---------------------------------------------------------------------------
Step "0. Locating the project"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $candidates = @(
        "C:\Users\anton\AndroidStudioProjects\FFMODROOT",
        (Split-Path -Parent $MyInvocation.MyCommand.Path),
        (Get-Location).Path
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c "app\src\main\AndroidManifest.xml"))) {
            $ProjectRoot = $c
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path (Join-Path $ProjectRoot "app\src\main\AndroidManifest.xml"))) {
    Bad "could not find AndroidManifest.xml. Pass it explicitly:"
    Note "-ProjectRoot C:\Users\anton\AndroidStudioProjects\FFMODROOT"
    exit 1
}
Ok "project: $ProjectRoot"

$SrcRoot = Join-Path $ProjectRoot "app\src\main\java"
if (-not (Test-Path $SrcRoot)) { $SrcRoot = Join-Path $ProjectRoot "app\src\main\kotlin" }

# ---------------------------------------------------------------------------
# 1. adb
# ---------------------------------------------------------------------------
Step "1. Waiting for $Serial"

function Get-AdbState([string] $serial) {
    $out = (& adb -s $serial get-state 2>&1) -join " "
    if ($out -match "device")       { return "device" }
    if ($out -match "offline")      { return "offline" }
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
        Warn ("device not ready - trying: " + $step.Name)
        try { & $step.Run } catch { }
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if ((Get-AdbState $serial) -eq "device") { Ok ("ready after: " + $step.Name); return $true }
        }
    }
    Bad "device still '$(Get-AdbState $serial)'."
    return $false
}

if (-not (Wait-AdbDevice $Serial)) { exit 1 }
Ok "device is online"

$installed = ((& adb -s $Serial shell pm list packages $Package 2>&1) -join " ")
if ($installed -notmatch [regex]::Escape($Package)) {
    Bad "$Package is not installed - install the APK first"
    exit 1
}

# ---------------------------------------------------------------------------
# 2. clear the crash buffer and launch
# ---------------------------------------------------------------------------
Step "2. Clearing logcat and launching"
& adb -s $Serial logcat -c 2>&1 | Out-Null
& adb -s $Serial shell am force-stop $Package 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$startOut = (& adb -s $Serial shell am start -n "$Package/.MainActivity" 2>&1) -join "`n"
Note $startOut

if ($startOut -match "Error|does not exist|Unable to find") {
    Warn "MainActivity launch failed - dumping the launcher activity instead"
    $act = ((& adb -s $Serial shell cmd package resolve-activity --brief $Package 2>&1) -join " ").Trim()
    Note "resolved: $act"
    if ($act -match "/") { & adb -s $Serial shell am start -n $act 2>&1 | Out-Null }
}

# ---------------------------------------------------------------------------
# 3. interactive catch window
# ---------------------------------------------------------------------------
Step "3. Reproduce the crash NOW"
Write-Host ""
Write-Host "   +-------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "   |  TAP THE 'FREE FIRE' / 'FREE FIRE MAX' OPTION IN THE APP.   |" -ForegroundColor Yellow
Write-Host "   +-------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host ""
Note ("recording for $Watch seconds ...")

for ($left = $Watch; $left -gt 0; $left--) {
    Write-Host ("`r   [{0,3}s] waiting for you to tap ...   " -f $left) -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host "`r   capture window closed.                        "

# ---------------------------------------------------------------------------
# 4. the crash
# ---------------------------------------------------------------------------
Step "4. Crash buffer"
$crash = (& adb -s $Serial logcat -b crash -d -t 300 2>&1) -join "`n"
if ([string]::IsNullOrWhiteSpace($crash)) {
    Ok "crash buffer is EMPTY - nothing native died"
} else {
    Capture $crash
}

Step "5. Full log (app + runtime)"
$log = (& adb -s $Serial logcat -d -t 900 2>&1) -join "`n"
$interesting = $log -split "`n" | Where-Object {
    $_ -match "AndroidRuntime|FATAL EXCEPTION|Caused by:|UnsatisfiedLink|ExceptionInInitialize|ActivityNotFound|SecurityException|IllegalState|NullPointer|ANT-Aincrad|ffmodroot|BadToken"
}
if ($interesting) {
    $interesting | ForEach-Object { Capture $_ }
} else {
    Warn "no matching runtime lines - the app may not have crashed at all"
    Note "the last 30 log lines are printed instead:"
    ($log -split "`n" | Select-Object -Last 30) | ForEach-Object { Capture $_ }
}

# ---------------------------------------------------------------------------
# 6. which source files appear in the stack
# ---------------------------------------------------------------------------
Step "6. Source behind the stack frames"

$frames = @()
if ($crash) {
    $frames = ($crash -split "`n") |
        Where-Object { $_ -match "at\s+com\.ffmodroot\." } |
        ForEach-Object { $_.Trim() } |
        Select-Object -Unique
}

if (-not $frames) {
    Warn "no com.ffmodroot frames in the crash buffer"
    Note "if the crash buffer was empty, the app did not die - tell me what you saw instead"
} else {
    $classes = $frames | ForEach-Object {
        if ($_ -match "at\s+com\.ffmodroot\.([A-Za-z0-9_$]+)\.") { $matches[1] }
    } | Select-Object -Unique

    foreach ($cls in $classes) {
        $name = $cls -replace '\$.*$', ''
        $file = Get-ChildItem -Path $SrcRoot -Recurse -Filter "$name.kt" -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if (-not $file) {
            Warn "$name.kt not found under $SrcRoot"
            continue
        }
        Capture ""
        Capture "----- $($file.FullName) -----"
        $lines = Get-Content -LiteralPath $file.FullName
        $total = $lines.Count
        $hitLines = @()
        foreach ($f in $frames) {
            if ($f -match "\($([regex]::Escape($name))\.kt:(\d+)\)") { $hitLines += [int]$matches[1] }
        }
        if ($hitLines.Count -eq 0) {
            Capture "(whole file, $total lines)"
            for ($i = 1; $i -le $total; $i++) { Capture ("{0,4}: {1}" -f $i, $lines[$i-1]) }
        } else {
            foreach ($h in ($hitLines | Select-Object -Unique)) {
                $from = [Math]::Max(1, $h - 12)
                $to   = [Math]::Min($total, $h + 6)
                Capture "(lines $from-$to of $total, >>> marks the crash line)"
                for ($i = $from; $i -le $to; $i++) {
                    $mark = if ($i -eq $h) { ">>>" } else { "   " }
                    Capture ("{0}{1,4}: {2}" -f $mark, $i, $lines[$i-1])
                }
                Capture ""
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. risk scan for the usual suspects on this device
# ---------------------------------------------------------------------------
Step "7. Risky patterns in your source"

$patterns = @(
    @{ Tag = "loadLibrary (ABI crash: x86_64 vs arm64)"; Re = "System\.loadLibrary" },
    @{ Tag = "ModBridge call (native object init)";      Re = "ModBridge\." },
    @{ Tag = "startActivity (ActivityNotFound)";         Re = "startActivity" },
    @{ Tag = "launch intent for a game package";         Re = "getLaunchIntentForPackage|freefireth|freefiremax" },
    @{ Tag = "shell / root exec (SecurityException)";    Re = "Runtime\.getRuntime|ProcessBuilder|\bsu\b" }
)

$ktFiles = @(Get-ChildItem -Path $SrcRoot -Recurse -Filter *.kt -ErrorAction SilentlyContinue)

if ($ktFiles.Count -eq 0) {
    Warn "no .kt files under $SrcRoot"
} else {
    Note "$($ktFiles.Count) Kotlin files under $SrcRoot"
    $findings = 0
    foreach ($p in $patterns) {
        $hits = $ktFiles | Select-String -Pattern $p.Re -ErrorAction SilentlyContinue
        if (-not $hits) { continue }
        Capture ""
        Capture ("### " + $p.Tag)
        foreach ($h in $hits) {
            $findings++
            $ln = $h.LineNumber
            $ctx = @()
            $all = Get-Content -LiteralPath $h.Path
            for ($k = [Math]::Max(1, $ln - 3); $k -lt $ln; $k++) { $ctx += $all[$k-1] }
            $guarded = ($ctx -join "`n") -match "try\s*\{|runCatching|catch\s*\("
            $flag = if ($guarded) { "guarded  " } else { "UNGUARDED" }
            Capture ("{0} {1}:{2}" -f $flag, (Split-Path -Leaf $h.Path), $ln)
            Capture ("           " + $h.Line.Trim())
        }
    }
    if ($findings -eq 0) { Ok "no risky patterns found" }
}

# ---------------------------------------------------------------------------
# 8. save
# ---------------------------------------------------------------------------
Step "8. Report"
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path (Get-Location).Path "crash_report.txt"
}
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($OutFile, $script:report, $utf8)
    Ok "written to $OutFile"
    Write-Host ""
    Write-Host "   Send me that file, or just paste sections 4, 6 and 7." -ForegroundColor Yellow
} catch {
    Warn "could not write $OutFile - copy the output above instead"
}

Write-Host ""
Write-Host "   To get back to a known-good app right now:" -ForegroundColor Yellow
Write-Host "     powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1 -Remove" -ForegroundColor White
Write-Host "     powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1" -ForegroundColor White
Write-Host ""
