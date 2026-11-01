<#
  add_floating_menu.ps1
  =====================
  Adds the missing in-game floating menu to FFMODROOT.

  Why this is needed
  ------------------
  Nothing in the project ever drew anything over Free Fire:

    * libant_aincrad.so contains no UI code at all - 0 matches for
      imgui / egl / overlay / window / menu / button / motion, and it does not
      link libEGL or libGLESv2. It only hooks SetAimRotation and sendto/send.
    * The APK contains MainActivity, MainActivityKt, ModBridge, RootInjector,
      Screen and ui/theme - no Service class, so no window could be added.

  What this script adds
  ---------------------
    1. OverlayMenuService.kt  - a foreground Service that puts a draggable
       window on top of everything (TYPE_APPLICATION_OVERLAY) with switches for
       Aim / Antiban / Lobby bypass / Game bypass. The switches call the same
       ModBridge functions the Compose UI calls, so the native module picks them
       up (it polls /data/local/tmp/ant_aincrad.cfg every 500 ms).
    2. OverlayAutoStart.kt    - a tiny ContentProvider that starts the service
       when the app process comes up, so nothing has to be called from
       MainActivity.kt (which we must not rewrite blind).
    3. AndroidManifest.xml    - SYSTEM_ALERT_WINDOW + foreground-service
       permissions, the <service> and the <provider>.

  Overlay permission
  ------------------
  Android will not let an app draw over another app without SYSTEM_ALERT_WINDOW.
  On a rooted BlueStacks the reliable way is one adb command, which this script
  can run for you with -Grant:

      adb shell appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow

  Usage:
      powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1
      powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1 -Grant
      powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1 -ProjectRoot "D:\other\FFMODROOT" -Serial 127.0.0.1:5555
#>

[CmdletBinding()]
param(
    [string] $ProjectRoot = "C:\Users\anton\AndroidStudioProjects\FFMODROOT",
    [string] $Serial      = "127.0.0.1:5555",
    [string] $Package     = "com.ffmodroot",
    [switch] $Grant
)

$ErrorActionPreference = "Stop"

function Step($n, $t) { Write-Host ""; Write-Host "== [$n] $t " -ForegroundColor Cyan; Write-Host ("-" * 70) -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
Step 0 "Locating the Android project"
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-Location).Path }
if (-not (Test-Path $ProjectRoot)) {
    if (Test-Path (Join-Path (Get-Location) "gradlew.bat")) { $ProjectRoot = (Get-Location).Path }
    else { Bad "Project not found: $ProjectRoot"; exit 1 }
}

$AppDir   = Join-Path $ProjectRoot "app"
$SrcDir   = Join-Path $AppDir "src\main\java\com\ffmodroot"
$Manifest = Join-Path $AppDir "src\main\AndroidManifest.xml"

foreach ($p in @($AppDir, $SrcDir, $Manifest)) {
    if (Test-Path $p) { Ok $p } else { Bad "missing: $p"; exit 1 }
}

$compileSdk = 0
$gradleApp = Join-Path $AppDir "build.gradle.kts"
if (-not (Test-Path $gradleApp)) { $gradleApp = Join-Path $AppDir "build.gradle" }
if (Test-Path $gradleApp) {
    $g = Get-Content -Raw $gradleApp
    if ($g -match 'compileSdk\s*=?\s*(\d+)') { $compileSdk = [int]$Matches[1] }
    if ($compileSdk -gt 0) { Ok "compileSdk = $compileSdk" }
}

# ---------------------------------------------------------------------------
# 1. OverlayMenuService.kt
# ---------------------------------------------------------------------------
Step 1 "Writing OverlayMenuService.kt"

$serviceKt = @'
package com.ffmodroot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView

/**
 * Draggable menu drawn over Free Fire.
 *
 * The switches call the same ModBridge entry points the Compose UI uses, and
 * libant_aincrad.so mirrors them to /data/local/tmp/ant_aincrad.cfg, which the
 * copy of the module running inside the game re-reads every 500 ms.
 */
class OverlayMenuService : Service() {

    companion object {
        const val TAG = "ANT-Aincrad-Overlay"
        private const val CHANNEL_ID = "ant_aincrad_overlay"
        private const val NOTIF_ID = 4242
        private const val PREFS = "ant_aincrad_overlay"

        fun start(ctx: Context) {
            val i = Intent(ctx, OverlayMenuService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(i)
                } else {
                    @Suppress("DEPRECATION")
                    ctx.startService(i)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "start failed: " + t)
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.stopService(Intent(ctx, OverlayMenuService::class.java))
            } catch (t: Throwable) {
                Log.e(TAG, "stop failed: " + t)
            }
        }
    }

    private lateinit var wm: WindowManager
    private lateinit var lp: WindowManager.LayoutParams
    private lateinit var prefs: SharedPreferences
    private var root: LinearLayout? = null
    private var status: TextView? = null
    private val ui = Handler(Looper.getMainLooper())

    private val ticker = object : Runnable {
        override fun run() {
            refreshStatus()
            ui.postDelayed(this, 1000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        startForegroundNotice()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            Log.e(TAG, "SYSTEM_ALERT_WINDOW not granted - menu not shown")
            stopSelf()
            return
        }

        try {
            showMenu()
        } catch (t: Throwable) {
            Log.e(TAG, "showMenu failed: " + t)
        }

        ui.postDelayed(ticker, 1000L)
    }

    override fun onDestroy() {
        ui.removeCallbacksAndMessages(null)
        val r = root
        if (r != null) {
            try {
                wm.removeView(r)
            } catch (t: Throwable) {
                Log.e(TAG, "removeView failed: " + t)
            }
        }
        root = null
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "ANT Aincrad menu", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return b.setContentTitle("ANT Aincrad")
            .setContentText("In-game menu running")
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setOngoing(true)
            .build()
    }

    private fun startForegroundNotice() {
        try {
            startForeground(NOTIF_ID, buildNotification())
        } catch (t: Throwable) {
            Log.e(TAG, "startForeground failed: " + t)
        }
    }

    @Suppress("DEPRECATION")
    private fun showMenu() {
        val dm = resources.displayMetrics
        val pad = (dm.density * 12f).toInt()

        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(pad, pad, pad, pad)
        box.background = GradientDrawable().apply {
            cornerRadius = dm.density * 14f
            setColor(Color.parseColor("#E6111114"))
            setStroke((dm.density * 1.5f).toInt(), Color.parseColor("#66FF3B30"))
        }

        // Header row: title (drag handle) + collapse chevron.
        // Collapsing only hides the body, so the title stays grabbable and the
        // menu is always recoverable - never hide the root view.
        val headerRow = LinearLayout(this)
        headerRow.orientation = LinearLayout.HORIZONTAL
        headerRow.gravity = Gravity.CENTER_VERTICAL

        val title = TextView(this)
        title.text = "ANT AINCRAD"
        title.setTextColor(Color.parseColor("#FF3B30"))
        title.textSize = 15f
        title.setTypeface(Typeface.DEFAULT_BOLD)
        title.setPadding(0, 0, (dm.density * 6f).toInt(), 0)
        headerRow.addView(title, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

        val body = LinearLayout(this)
        body.orientation = LinearLayout.VERTICAL

        val chevron = Button(this)
        chevron.text = "\u25BE"
        chevron.textSize = 12f
        chevron.minWidth = 0
        chevron.minimumWidth = 0
        chevron.setPadding((dm.density * 8f).toInt(), 0, (dm.density * 8f).toInt(), 0)
        chevron.setOnClickListener {
            val nowVisible = body.visibility != View.VISIBLE
            body.visibility = if (nowVisible) View.VISIBLE else View.GONE
            chevron.text = if (nowVisible) "\u25BE" else "\u25B8"
        }
        headerRow.addView(chevron)

        box.addView(headerRow)
        box.addView(body)

        addToggle(body, "Aim assist")  { on -> ModBridge.setAimEnabled(on) }
        addToggle(body, "Antiban")     { on -> ModBridge.setAntibanEnabled(on) }
        addToggle(body, "Lobby bypass"){ on -> ModBridge.setLobbyBypassEnabled(on) }
        addToggle(body, "Game bypass") { on -> ModBridge.setGameBypassEnabled(on) }

        val st = TextView(this)
        st.setTextColor(Color.parseColor("#8A8A8E"))
        st.textSize = 11f
        st.setPadding(0, (dm.density * 8f).toInt(), 0, (dm.density * 4f).toInt())
        st.text = "mod=idle"
        body.addView(st)
        status = st

        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL

        val close = Button(this)
        close.text = "Close"
        close.textSize = 11f
        close.setOnClickListener { stopSelf() }

        row.addView(close, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        body.addView(row)

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_PHONE
        }

        lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP or Gravity.START
        lp.x = (dm.density * 20f).toInt()
        lp.y = (dm.density * 120f).toInt()

        title.setOnTouchListener(object : View.OnTouchListener {
            private var startX = 0
            private var startY = 0
            private var downX = 0f
            private var downY = 0f

            override fun onTouch(v: View?, e: MotionEvent?): Boolean {
                if (e == null) return false
                when (e.action) {
                    MotionEvent.ACTION_DOWN -> {
                        startX = lp.x
                        startY = lp.y
                        downX = e.rawX
                        downY = e.rawY
                        return true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        lp.x = startX + (e.rawX - downX).toInt()
                        lp.y = startY + (e.rawY - downY).toInt()
                        val r = root
                        if (r != null) {
                            try {
                                wm.updateViewLayout(r, lp)
                            } catch (t: Throwable) {
                                Log.e(TAG, "drag failed: " + t)
                            }
                        }
                        return true
                    }
                }
                return false
            }
        })

        wm.addView(box, lp)
        root = box
        refreshStatus()
        Log.i(TAG, "menu displayed")
    }

    private fun addToggle(parent: LinearLayout, label: String, apply: (Boolean) -> Unit) {
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL

        val tv = TextView(this)
        tv.text = label
        tv.setTextColor(Color.parseColor("#EDEDED"))
        tv.textSize = 13f

        val key = "sw_" + label.lowercase().replace(" ", "_")
        val sw = Switch(this)
        sw.isChecked = prefs.getBoolean(key, false)
        sw.setOnCheckedChangeListener { _, checked ->
            prefs.edit().putBoolean(key, checked).apply()
            try {
                apply(checked)
            } catch (t: Throwable) {
                Log.e(TAG, "applying $label failed: " + t)
            }
            refreshStatus()
        }

        row.addView(tv, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(sw)
        parent.addView(row)
    }

    private fun refreshStatus() {
        val t = status ?: return
        var loaded = false
        var lobby = false
        var game = false
        try {
            loaded = ModBridge.isModLoaded()
            lobby = ModBridge.isLobbyBypassActive()
            game = ModBridge.isGameBypassActive()
        } catch (th: Throwable) {
            t.text = "native library not loaded"
            return
        }
        val l = if (loaded) "loaded" else "idle"
        val lo = if (lobby) "OK" else "-"
        val ga = if (game) "OK" else "-"
        t.text = "mod=" + l + "   lobby=" + lo + "   game=" + ga
    }
}
'@

[System.IO.File]::WriteAllText((Join-Path $SrcDir "OverlayMenuService.kt"), $serviceKt, (New-Object System.Text.UTF8Encoding($false)))
Ok (Join-Path $SrcDir "OverlayMenuService.kt")

# ---------------------------------------------------------------------------
# 2. OverlayAutoStart.kt
# ---------------------------------------------------------------------------
Step 2 "Writing OverlayAutoStart.kt"

$autoKt = @'
package com.ffmodroot

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log

/**
 * Starts OverlayMenuService as soon as the app process comes up, so nothing has
 * to be added to MainActivity.kt.
 *
 * Deliberately does nothing when SYSTEM_ALERT_WINDOW has not been granted; grant
 * it once with:
 *
 *     adb shell appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow
 */
class OverlayAutoStart : ContentProvider() {

    override fun onCreate(): Boolean {
        val ctx = context ?: return true

        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(ctx)

        Log.i(OverlayMenuService.TAG, "OverlayAutoStart: overlayAllowed=" + allowed)

        if (!allowed) {
            Log.w(OverlayMenuService.TAG, "grant it with: adb shell appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow")
            return true
        }

        Handler(Looper.getMainLooper()).postDelayed({
            OverlayMenuService.start(ctx)
        }, 1500L)

        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
'@

[System.IO.File]::WriteAllText((Join-Path $SrcDir "OverlayAutoStart.kt"), $autoKt, (New-Object System.Text.UTF8Encoding($false)))
Ok (Join-Path $SrcDir "OverlayAutoStart.kt")

# ---------------------------------------------------------------------------
# 3. AndroidManifest.xml
# ---------------------------------------------------------------------------
Step 3 "Patching AndroidManifest.xml"

$NS = "http://schemas.android.com/apk/res/android"
[xml]$doc = Get-Content -Raw $Manifest
$manifestNode = $doc.DocumentElement
if ($manifestNode.LocalName -ne "manifest") { Bad "unexpected root element: $($manifestNode.LocalName)"; exit 1 }

$wanted = @(
    "android.permission.SYSTEM_ALERT_WINDOW",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    "android.permission.POST_NOTIFICATIONS"
)

$existingPerms = @()
foreach ($n in $manifestNode.SelectNodes("uses-permission")) {
    $v = $n.GetAttribute("name", $NS)
    if ($v) { $existingPerms += $v }
}

foreach ($p in $wanted) {
    if ($existingPerms -contains $p) { Ok "permission already present: $p"; continue }
    $el = $doc.CreateElement("uses-permission")
    $el.SetAttribute("name", $NS, $p)
    [void]$manifestNode.PrependChild($el)
    Ok "added permission $p"
}

$appNode = $manifestNode.SelectSingleNode("application")
if (-not $appNode) { Bad "no <application> element in the manifest"; exit 1 }

# --- service ---
$svc = $appNode.SelectSingleNode("service[@*[local-name()='name']='.OverlayMenuService']")
if (-not $svc) {
    $svc = $doc.CreateElement("service")
    $svc.SetAttribute("name", $NS, ".OverlayMenuService")
    $svc.SetAttribute("exported", $NS, "false")
    if ($compileSdk -ge 34) {
        $svc.SetAttribute("foregroundServiceType", $NS, "specialUse")
        $prop = $doc.CreateElement("property")
        $prop.SetAttribute("name", $NS, "android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE")
        $prop.SetAttribute("value", $NS, "in-game overlay menu")
        [void]$svc.AppendChild($prop)
        Ok "service declared with foregroundServiceType=specialUse (compileSdk $compileSdk)"
    } else {
        Warn "compileSdk < 34 - omitting foregroundServiceType (not needed below API 34)"
    }
    [void]$appNode.AppendChild($svc)
    Ok "added <service .OverlayMenuService>"
} else {
    Ok "<service .OverlayMenuService> already present"
}

# --- provider ---
$prov = $appNode.SelectSingleNode("provider[@*[local-name()='name']='.OverlayAutoStart']")
if (-not $prov) {
    $prov = $doc.CreateElement("provider")
    $prov.SetAttribute("name", $NS, ".OverlayAutoStart")
    $prov.SetAttribute("authorities", $NS, "com.ffmodroot.overlayinit")
    $prov.SetAttribute("exported", $NS, "false")
    $prov.SetAttribute("initOrder", $NS, "1000")
    [void]$appNode.AppendChild($prov)
    Ok "added <provider .OverlayAutoStart>"
} else {
    Ok "<provider .OverlayAutoStart> already present"
}

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.IndentChars = "    "
$settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$writer = [System.Xml.XmlWriter]::Create($Manifest, $settings)
try { $doc.Save($writer) } finally { $writer.Close() }
Ok "manifest saved (UTF-8, no BOM)"

# ---------------------------------------------------------------------------
# 4. optional: grant the overlay permission over adb
# ---------------------------------------------------------------------------
if ($Grant) {
    Step 4 "Granting SYSTEM_ALERT_WINDOW over adb"
    $devices = (& adb devices) -join "`n"
    if ($devices -notmatch [regex]::Escape($Serial)) {
        Warn "$Serial not connected - running adb connect"
        & adb connect $Serial | Out-Host
    }
    & adb -s $Serial shell appops set $Package SYSTEM_ALERT_WINDOW allow 2>&1 | Out-Host
    $state = (& adb -s $Serial shell appops get $Package SYSTEM_ALERT_WINDOW) -join " "
    Write-Host "   appops -> $state"
    if ($state -match "allow") { Ok "overlay permission granted" }
    else {
        Bad "grant did not take. Try the rooted fallback:"
        Write-Host "      adb -s $Serial shell su -c 'appops set $Package SYSTEM_ALERT_WINDOW allow'" -ForegroundColor White
    }
} else {
    Step 4 "Overlay permission"
    Warn "Not granted yet. Run this once (rooted BlueStacks):"
    Write-Host "      adb -s $Serial shell appops set $Package SYSTEM_ALERT_WINDOW allow" -ForegroundColor White
    Write-Host "   or re-run this script with -Grant" -ForegroundColor White
}

Write-Host ""
Ok "Files written. Now rebuild and reinstall:"
Write-Host "      powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1" -ForegroundColor White
Write-Host ""
Write-Host "Then open ANT AINCRAD. The menu appears ~1.5 s after the app starts and" -ForegroundColor Yellow
Write-Host "stays on top when Free Fire is in front." -ForegroundColor Yellow
Write-Host "Log tag: ANT-Aincrad-Overlay" -ForegroundColor Yellow
