<#
  add_floating_menu.ps1
  =====================
  Adds the in-game floating menu, gated behind an INJECT BYPASS step, with
  Silent Aim as the first feature.

  Why this is needed
  ------------------
  Nothing in the project ever drew anything over Free Fire:

    * libant_aincrad.so contains no UI code at all - 0 matches for
      imgui / egl / overlay / window / menu / button / motion, and it does not
      link libEGL or libGLESv2.
    * The APK contains MainActivity, MainActivityKt, ModBridge, RootInjector,
      Screen and ui/theme - no Service class, so no window could be added.

  What this script adds
  ---------------------
    1. OverlayMenuService.kt - a foreground Service showing a draggable overlay.
       Before injection it shows one button: INJECT BYPASS. After that it reveals
       the feature list (Silent Aim now, more later) and a live status line.
    2. OverlayAutoStart.kt   - ContentProvider that starts the service on launch,
       so MainActivity.kt never has to be edited.
    3. Injector.kt           - Kotlin object matching the JNI symbols the library
       already exports (Java_com_ffmodroot_Injector_initHooks / getIl2cppBase).
       Kotlin, not Java: a .java here would collide with the .kt files and
       reproduce the duplicate-class build failure we already fixed.
    4. ModBridge.kt          - appends the two new externals
       (setSilentAimEnabled / isSilentAimActive) if they are missing. Everything
       else in that file is left byte-for-byte alone.
    5. AndroidManifest.xml   - SYSTEM_ALERT_WINDOW + foreground-service bits,
       the <service> and the <provider>.

  Important
  ---------
  The menu gate does not do the real injection. Hooks only install inside the
  Free Fire process, which is what deploy_ff.ps1 does (root, Zygote
  wrap.<package>). The status line tells you which state you are in.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1
      powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1 -Grant
      powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1 -ProjectRoot "D:\x\FFMODROOT"
#>

[CmdletBinding()]
param(
    [string] $ProjectRoot = "C:\Users\anton\AndroidStudioProjects\FFMODROOT",
    [string] $Serial      = "127.0.0.1:5555",
    [string] $Package     = "com.ffmodroot",
    [switch] $Grant,
    [switch] $Remove
)

$ErrorActionPreference = "Stop"

function Step($n, $t) { Write-Host ""; Write-Host "== [$n] $t " -ForegroundColor Cyan; Write-Host ("-" * 70) -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-Kt([string] $path, [string] $body) {
    [System.IO.File]::WriteAllText($path, $body, $Utf8NoBom)
}

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
$ModBridgeKt = Join-Path $SrcDir "ModBridge.kt"

foreach ($p in @($AppDir, $SrcDir, $Manifest)) {
    if (Test-Path $p) { Ok $p } else { Bad "missing: $p"; exit 1 }
}
if (-not (Test-Path $ModBridgeKt)) { Bad "ModBridge.kt not found at $ModBridgeKt"; exit 1 }
Ok $ModBridgeKt

$compileSdk = 0
$gradleApp = Join-Path $AppDir "build.gradle.kts"
if (-not (Test-Path $gradleApp)) { $gradleApp = Join-Path $AppDir "build.gradle" }
if (Test-Path $gradleApp) {
    $g = Get-Content -Raw $gradleApp
    if ($g -match 'compileSdk\s*=?\s*(\d+)') { $compileSdk = [int]$Matches[1] }
    if ($compileSdk -gt 0) { Ok "compileSdk = $compileSdk" }
}

# ---------------------------------------------------------------------------
# -Remove: put the project back the way it was, then stop.
# ---------------------------------------------------------------------------
if ($Remove) {
    Step "R" "Removing the overlay"

    foreach ($f in @("OverlayMenuService.kt", "OverlayAutoStart.kt", "Injector.kt")) {
        $p = Join-Path $SrcDir $f
        if (Test-Path $p) { Remove-Item $p -Force; Ok "deleted $f" } else { Ok "$f already absent" }
    }

    $mb = [System.IO.File]::ReadAllText($ModBridgeKt)
    $before = $mb
    foreach ($decl in @(
            '(?m)^\s*external\s+fun\s+setSilentAimEnabled\s*\([^)]*\)\s*\r?\n',
            '(?m)^\s*external\s+fun\s+isSilentAimActive\s*\([^)]*\)\s*:\s*Boolean\s*\r?\n'
        )) {
        $mb = $mb -replace $decl, ''
    }
    if ($mb -ne $before) {
        [System.IO.File]::WriteAllText($ModBridgeKt, $mb, $Utf8NoBom)
        Ok "removed the two silent-aim externals from ModBridge.kt"
    } else {
        Ok "ModBridge.kt unchanged"
    }

    [xml]$doc = Get-Content -Raw $Manifest
    $NS = "http://schemas.android.com/apk/res/android"
    $root = $doc.DocumentElement
    $app = $root.SelectSingleNode("application")

    foreach ($xpath in @(
            "service[@*[local-name()='name']='.OverlayMenuService']",
            "provider[@*[local-name()='name']='.OverlayAutoStart']"
        )) {
        $node = $app.SelectSingleNode($xpath)
        if ($node) { [void]$app.RemoveChild($node); Ok "removed $xpath" }
    }

    foreach ($n in @($root.SelectNodes("uses-permission"))) {
        $v = $n.GetAttribute("name", $NS)
        if ($v -eq "android.permission.SYSTEM_ALERT_WINDOW" -or
            $v -eq "android.permission.FOREGROUND_SERVICE_SPECIAL_USE") {
            [void]$root.RemoveChild($n)
            Ok "removed permission $v"
        }
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = "    "
    $settings.Encoding = $Utf8NoBom
    $w = [System.Xml.XmlWriter]::Create($Manifest, $settings)
    try { $doc.Save($w) } finally { $w.Close() }
    Ok "manifest restored"

    Write-Host ""
    Ok "Overlay removed. Rebuild to get back to the last working app:"
    Write-Host "      powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1" -ForegroundColor White
    exit 0
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
import android.widget.TextView
import java.io.File

/**
 * Draggable in-game menu.
 *
 * Flow: INJECT BYPASS first, features after - matching how Aincrad-style clients
 * behave. The gate is honest about its own state: it unlocks the feature list,
 * but the status line stays red until the hooks are actually installed inside
 * Free Fire (deploy_ff.ps1 does that; nothing here can).
 */
class OverlayMenuService : Service() {

    companion object {
        const val TAG = "ANT-Aincrad-Overlay"
        private const val CHANNEL_ID = "ant_aincrad_overlay"
        private const val NOTIF_ID = 4242
        private const val PREFS = "ant_aincrad_overlay"
        private const val K_INJECTED = "injected"

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

    /**
     * True only when the native library for THIS device's ABI is actually in
     * the APK. BlueStacks reports x86_64; the project ships arm64-v8a only, so
     * System.loadLibrary() would throw UnsatisfiedLinkError and take the whole
     * app down. Never call ModBridge unless this returns true.
     */
    private fun nativeLibPresent(): Boolean {
        return try {
            val dir = applicationInfo?.nativeLibraryDir ?: return false
            File(dir, "libant_aincrad.so").exists()
        } catch (t: Throwable) {
            Log.w(TAG, "nativeLibPresent check failed: " + t)
            false
        }
    }

    private lateinit var wm: WindowManager
    private lateinit var lp: WindowManager.LayoutParams
    private lateinit var prefs: SharedPreferences
    private var rootView: LinearLayout? = null
    private var gatePanel: LinearLayout? = null
    private var featurePanel: LinearLayout? = null
    private var injectBtn: Button? = null
    private var statusView: TextView? = null
    private val ui = Handler(Looper.getMainLooper())

    private val ticker = object : Runnable {
        override fun run() {
            // Any throw on the main thread kills the process. The status line is
            // cosmetic, so it must never be able to take the app down - and it
            // must keep ticking even if one refresh fails.
            try {
                refreshStatus()
            } catch (t: Throwable) {
                Log.w(TAG, "refreshStatus failed: " + t)
            } finally {
                ui.postDelayed(this, 1000L)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        startForegroundNotice()

        // Do NOT stopSelf() when the permission is missing. The user usually
        // grants it *after* launching the app (and on BlueStacks the Settings
        // switch is greyed out, so they have to do it over adb), so wait for it
        // instead of dying and requiring another launch.
        if (!canDrawOverlays()) {
            Log.e(TAG, "SYSTEM_ALERT_WINDOW not granted yet - waiting for it")
            Log.e(TAG, "grant with: adb shell appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow")
            ui.post(permissionWatcher)
            return
        }

        try {
            showMenu()
        } catch (t: Throwable) {
            Log.e(TAG, "showMenu failed: " + t)
        }

        ui.postDelayed(ticker, 1000L)
    }

    private fun canDrawOverlays(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
    }

    /**
     * Re-checks the overlay permission every 1.5 s until it is granted, then
     * shows the menu. Lets the user grant it from adb (or Settings) while the
     * app is already running - no relaunch needed.
     */
    private val permissionWatcher = object : Runnable {
        override fun run() {
            var granted = false
            try {
                granted = canDrawOverlays()
            } catch (t: Throwable) {
                Log.w(TAG, "canDrawOverlays failed: " + t)
            }

            if (granted) {
                Log.i(TAG, "overlay permission granted - showing menu")
                try {
                    showMenu()
                } catch (t: Throwable) {
                    Log.e(TAG, "showMenu failed: " + t)
                }
                ui.postDelayed(ticker, 1000L)
                return
            }
            ui.postDelayed(this, 1500L)
        }
    }

    override fun onDestroy() {
        ui.removeCallbacksAndMessages(null)
        val r = rootView
        if (r != null) {
            try {
                wm.removeView(r)
            } catch (t: Throwable) {
                Log.e(TAG, "removeView failed: " + t)
            }
        }
        rootView = null
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

        // Header: drag handle + collapse. Collapsing hides only the body, so the
        // menu can never become unrecoverable.
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

        // ---- gate: INJECT BYPASS -------------------------------------------
        val gate = LinearLayout(this)
        gate.orientation = LinearLayout.VERTICAL

        val hint = TextView(this)
        hint.text = "Not injected. Press inject to enable the bypasses and unlock features."
        hint.setTextColor(Color.parseColor("#9A9A9E"))
        hint.textSize = 11f
        hint.setPadding(0, 0, 0, (dm.density * 8f).toInt())
        gate.addView(hint)

        val btn = Button(this)
        btn.text = "INJECT BYPASS"
        btn.textSize = 13f
        btn.setOnClickListener { doInject() }
        gate.addView(btn, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        injectBtn = btn

        body.addView(gate)
        gatePanel = gate

        // ---- features -------------------------------------------------------
        val features = LinearLayout(this)
        features.orientation = LinearLayout.VERTICAL
        features.visibility = View.GONE

        val banner = TextView(this)
        banner.text = "INJECTED"
        banner.setTextColor(Color.parseColor("#34C759"))
        banner.textSize = 11f
        banner.setTypeface(Typeface.DEFAULT_BOLD)
        banner.setPadding(0, 0, 0, (dm.density * 6f).toInt())
        features.addView(banner)

        addToggle(features, "Silent aim", "silent_aim") { on -> ModBridge.setSilentAimEnabled(on) }

        body.addView(features)
        featurePanel = features

        // ---- status ---------------------------------------------------------
        val st = TextView(this)
        st.setTextColor(Color.parseColor("#8A8A8E"))
        st.textSize = 11f
        st.setPadding(0, (dm.density * 8f).toInt(), 0, (dm.density * 4f).toInt())
        st.text = "…"
        body.addView(st)
        statusView = st

        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        val close = Button(this)
        close.text = "Close"
        close.textSize = 11f
        close.setOnClickListener { stopSelf() }
        row.addView(close, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        body.addView(row)

        // Restore the gate state from the last session.
        applyInjected(prefs.getBoolean(K_INJECTED, false), announce = false)

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
                        val r = rootView
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
        rootView = box
        refreshStatus()
        Log.i(TAG, "menu displayed")
    }

    /**
     * What "inject" does here, precisely:
     *   1. switches both bypass flags on (they are what the hooks act on),
     *   2. asks the library to install hooks in THIS process via Injector,
     *   3. reports honestly whether that worked.
     *
     * In the launcher process libil2cpp.so does not exist, so step 3 will say
     * "not hooked" and point at deploy_ff.ps1. That is not a failure of this
     * screen - it is the truth about where the hooks have to live.
     */
    private fun doInject() {
        val btn = injectBtn ?: return

        // No point driving the native layer when its ABI is not in the APK -
        // this is the case that used to crash the app on BlueStacks.
        if (!nativeLibPresent()) {
            prefs.edit().putBoolean(K_INJECTED, true).apply()
            applyInjected(true, announce = true)
            Log.w(TAG, "inject: native library absent for this ABI - unlocking UI only")
            ui.post {
                statusView?.setTextColor(Color.parseColor("#FF9F0A"))
                statusView?.text = "hooks unavailable on this ABI\nrun Free Fire in an arm64 image, or ship x86_64 libs"
            }
            return
        }

        btn.isEnabled = false
        btn.text = "INJECTING..."

        Thread {
            var loaded = false
            var base = "0x0"
            try {
                loaded = ModBridge.isModLoaded()
            } catch (t: Throwable) {
                Log.e(TAG, "isModLoaded failed: " + t)
            }

            try {
                ModBridge.setLobbyBypassEnabled(true)
                ModBridge.setGameBypassEnabled(true)
            } catch (t: Throwable) {
                Log.e(TAG, "enabling bypasses failed: " + t)
            }

            if (!loaded) {
                try {
                    if (Injector.loaded) {
                        Injector.initHooks()
                        base = try { Injector.getIl2cppBase() } catch (t: Throwable) { "0x0" }
                        loaded = ModBridge.isModLoaded()
                    } else {
                        Log.w(TAG, "Injector object could not load the native library")
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "initHooks failed: " + t)
                }
            }

            Log.i(TAG, "inject result: loaded=" + loaded + " il2cpp=" + base)

            prefs.edit().putBoolean(K_INJECTED, true).apply()
            ui.post { applyInjected(true, announce = true) }
        }.start()
    }

    private fun applyInjected(injected: Boolean, announce: Boolean) {
        val g = gatePanel
        val f = featurePanel
        if (g != null) g.visibility = if (injected) View.GONE else View.VISIBLE
        if (f != null) f.visibility = if (injected) View.VISIBLE else View.GONE
        val btn = injectBtn
        if (btn != null) {
            btn.isEnabled = true
            btn.text = "INJECT BYPASS"
        }
        if (announce) Log.i(TAG, "features unlocked")
        refreshStatus()
    }

    /**
     * A plain Button, not android.widget.Switch.
     *
     * Switch resolves switchStyle / colorControlActivated from the theme, and a
     * Service context is inflated with the *application* theme - a Compose-only
     * theme can leave those undefined, which throws Resources.NotFoundException
     * while building the view and takes the process down before the menu is
     * ever seen. Button + a text label has no such dependency.
     */
    private fun addToggle(parent: LinearLayout, label: String, key: String, apply: (Boolean) -> Unit) {
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL

        val tv = TextView(this)
        tv.text = label
        tv.setTextColor(Color.parseColor("#EDEDED"))
        tv.textSize = 13f

        val btn = Button(this)
        btn.textSize = 11f
        btn.minWidth = 0
        btn.minimumWidth = 0

        var on = prefs.getBoolean(key, false)
        fun render() {
            btn.text = if (on) "ON" else "OFF"
            btn.setTextColor(Color.parseColor(if (on) "#34C759" else "#8A8A8E"))
        }
        render()

        btn.setOnClickListener {
            on = !on
            render()
            prefs.edit().putBoolean(key, on).apply()
            try {
                apply(on)
            } catch (t: Throwable) {
                Log.e(TAG, "applying " + label + " failed: " + t)
            }
            refreshStatus()
        }

        row.addView(tv, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(btn)
        parent.addView(row)
    }

    private fun refreshStatus() {
        val t = statusView ?: return

        // Guard before touching ModBridge: on a mismatched ABI the very first
        // static reference throws and can kill the process.
        if (!nativeLibPresent()) {
            t.setTextColor(Color.parseColor("#FF9F0A"))
            t.text = "no arm64 native library for this ABI\n(this emulator reports " +
                android.os.Build.SUPPORTED_ABIS.firstOrNull() + ")\ntoggles saved, hooks unavailable"
            return
        }

        var loaded = false
        var silent = false
        try {
            loaded = ModBridge.isModLoaded()
            silent = ModBridge.isSilentAimActive()
        } catch (th: Throwable) {
            t.setTextColor(Color.parseColor("#FF9F0A"))
            t.text = "native library failed to load: " + th.javaClass.simpleName
            return
        }
        if (!loaded) {
            t.setTextColor(Color.parseColor("#FF453A"))
            t.text = "hooks NOT installed\nrun deploy_ff.ps1 (root) to load the module inside Free Fire"
        } else {
            t.setTextColor(Color.parseColor("#34C759"))
            t.text = if (silent) "hooks live - silent aim firing" else "hooks live - silent aim idle"
        }
    }
}
'@

Write-Kt (Join-Path $SrcDir "OverlayMenuService.kt") $serviceKt
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
 * Starts OverlayMenuService when the app process comes up, so MainActivity.kt
 * needs no edits.
 *
 * Does nothing when SYSTEM_ALERT_WINDOW has not been granted. Grant it once:
 *
 *     adb shell appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow
 */
class OverlayAutoStart : ContentProvider() {

    override fun onCreate(): Boolean {
        // A ContentProvider that throws here crashes the app before any Activity
        // exists, which looks exactly like "the app started crashing again".
        try {
            val ctx = context ?: return true

            val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                Settings.canDrawOverlays(ctx)

            Log.i(OverlayMenuService.TAG, "OverlayAutoStart: overlayAllowed=" + allowed)

            if (!allowed) {
                Log.w(OverlayMenuService.TAG, "grant it with: adb shell appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow")
                return true
            }

            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    OverlayMenuService.start(ctx)
                } catch (t: Throwable) {
                    Log.e(OverlayMenuService.TAG, "service start failed: " + t)
                }
            }, 1500L)
        } catch (t: Throwable) {
            Log.e(OverlayMenuService.TAG, "OverlayAutoStart.onCreate failed: " + t)
        }
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

Write-Kt (Join-Path $SrcDir "OverlayAutoStart.kt") $autoKt
Ok (Join-Path $SrcDir "OverlayAutoStart.kt")

# ---------------------------------------------------------------------------
# 3. Injector.kt
# ---------------------------------------------------------------------------
Step 3 "Writing Injector.kt"

$injectorKt = @'
package com.ffmodroot

/**
 * Matches the JNI symbols libant_aincrad.so already exports:
 *
 *     Java_com_ffmodroot_Injector_initHooks
 *     Java_com_ffmodroot_Injector_getIl2cppBase
 *
 * Kotlin on purpose - a Dumper.java / Injector.java here is exactly what broke
 * the build before (duplicate class + BOM).
 *
 * In the launcher process libil2cpp.so is never mapped, so initHooks() returns
 * false and logs "libil2cpp.so not found". That is expected; the real injection
 * happens in the game process via deploy_ff.ps1.
 */
object Injector {

    @Volatile
    var loaded: Boolean = false
        private set

    init {
        // runCatching matters: a bare System.loadLibrary() on a device whose ABI
        // is not in the APK (BlueStacks is x86_64, this project is arm64-v8a)
        // throws UnsatisfiedLinkError, which becomes ExceptionInInitializerError
        // on every later reference and can take the process down.
        loaded = runCatching { System.loadLibrary("ant_aincrad") }
            .onFailure { android.util.Log.w("ANT-Aincrad-Overlay", "ant_aincrad not loadable: " + it) }
            .isSuccess
    }

    external fun initHooks(): Boolean
    external fun getIl2cppBase(): String
}
'@

Write-Kt (Join-Path $SrcDir "Injector.kt") $injectorKt
Ok (Join-Path $SrcDir "Injector.kt")

# ---------------------------------------------------------------------------
# 4. append the new externals to ModBridge.kt
# ---------------------------------------------------------------------------
Step 4 "Adding silent-aim externals to ModBridge.kt"

$mb = [System.IO.File]::ReadAllText($ModBridgeKt)
$changed = $false

foreach ($pair in @(
        @("setSilentAimEnabled", "    external fun setSilentAimEnabled(enabled: Boolean)"),
        @("isSilentAimActive",   "    external fun isSilentAimActive(): Boolean")
    )) {
    $name = $pair[0]
    $decl = $pair[1]
    if ($mb -match ("external\s+fun\s+" + [regex]::Escape($name) + "\s*\(")) {
        Ok "$name already declared"
        continue
    }
    $mb = $mb -replace '(?m)^(\s*external\s+fun\s+isGameBypassActive\s*\([^)]*\)\s*:\s*Boolean\s*)$',
                       ("`$1`r`n" + $decl)
    $changed = $true
    Ok "added $name"
}

if ($changed) {
    if ($mb -notmatch 'external\s+fun\s+setSilentAimEnabled\s*\(' -or
        $mb -notmatch 'external\s+fun\s+isSilentAimActive\s*\(') {
        Bad "could not insert both externals - ModBridge.kt shape is not what I expected"
        Bad "open $ModBridgeKt and add these two lines by hand, inside the object:"
        Write-Host "      external fun setSilentAimEnabled(enabled: Boolean)" -ForegroundColor White
        Write-Host "      external fun isSilentAimActive(): Boolean" -ForegroundColor White
        exit 1
    }
    [System.IO.File]::WriteAllText($ModBridgeKt, $mb, $Utf8NoBom)
    Ok "ModBridge.kt updated (UTF-8, no BOM)"
} else {
    Ok "ModBridge.kt already complete"
}

# ---------------------------------------------------------------------------
# 5. AndroidManifest.xml
# ---------------------------------------------------------------------------
Step 5 "Patching AndroidManifest.xml"

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
        Warn "compileSdk < 34 - omitting foregroundServiceType"
    }
    [void]$appNode.AppendChild($svc)
    Ok "added <service .OverlayMenuService>"
} else {
    Ok "<service .OverlayMenuService> already present"
}

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
$settings.Encoding = $Utf8NoBom
$writer = [System.Xml.XmlWriter]::Create($Manifest, $settings)
try { $doc.Save($writer) } finally { $writer.Close() }
Ok "manifest saved (UTF-8, no BOM)"

# ---------------------------------------------------------------------------
# 6. overlay permission
# ---------------------------------------------------------------------------
if ($Grant) {
    Step 6 "Granting SYSTEM_ALERT_WINDOW over adb"

    # The Settings switch is greyed out on BlueStacks, so the adb appop is the
    # ONLY way in. It also has to work when the device dropped offline.
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
        Write-Host "   Close BlueStacks fully, run 'adb kill-server', reopen it, then re-run this script." -ForegroundColor Yellow
        return $false
    }

    function Read-AppOp {
        $out = (& adb -s $Serial shell appops get $Package SYSTEM_ALERT_WINDOW 2>&1) -join " "
        if ($out -match "allow")   { return "allow" }
        if ($out -match "deny")    { return "deny" }
        if ($out -match "ignore")  { return "ignore" }
        if ($out -match "default") { return "default" }
        return "unknown: $out"
    }

    if (-not (Wait-AdbDevice $Serial)) { exit 1 }

    # Is the package even installed? appops on a missing package silently no-ops.
    $installed = ((& adb -s $Serial shell pm list packages $Package 2>&1) -join " ")
    if ($installed -notmatch [regex]::Escape($Package)) {
        Bad "$Package is not installed on this device"
        Bad "install the APK first: powershell -ExecutionPolicy Bypass -File .\\fix_ffmodroot.ps1"
        exit 1
    }
    Ok "$Package is installed"

    $before = Read-AppOp
    Write-Host "   appops before -> $before"

    # Attempt 1: plain appops as the shell user.
    & adb -s $Serial shell appops set $Package SYSTEM_ALERT_WINDOW allow 2>&1 | Out-Host
    Start-Sleep -Milliseconds 600
    $after = Read-AppOp
    Write-Host "   appops after  -> $after"

    # Attempt 2: rooted. Some BlueStacks images only accept it as uid 0.
    if ($after -notmatch "allow") {
        Warn "plain appops did not take - trying as root"
        & adb -s $Serial shell su -c "appops set $Package SYSTEM_ALERT_WINDOW allow" 2>&1 | Out-Host
        Start-Sleep -Milliseconds 600
        $after = Read-AppOp
        Write-Host "   appops after root -> $after"
    }

    if ($after -match "allow") {
        Ok "overlay permission granted"
        Write-Host ""
        Write-Host "   The greyed-out Settings switch is cosmetic - it reads the same AppOp" -ForegroundColor Yellow
        Write-Host "   this command just wrote. The menu will appear within ~1.5 s if the app" -ForegroundColor Yellow
        Write-Host "   is running, without relaunching." -ForegroundColor Yellow
    } else {
        Bad "could not set the AppOp (state: $after)"
        Write-Host "   Manual attempts, in order:" -ForegroundColor Yellow
        Write-Host "     adb -s $Serial shell appops set --uid $Package SYSTEM_ALERT_WINDOW allow" -ForegroundColor White
        Write-Host "     adb -s $Serial shell pm grant $Package android.permission.SYSTEM_ALERT_WINDOW" -ForegroundColor White
        Write-Host "     adb -s $Serial shell am start -a android.settings.action.MANAGE_OVERLAY_PERMISSION -d package:$Package" -ForegroundColor White
        exit 1
    }
} else {
    Step 6 "Overlay permission"
    Warn "not granted yet - run once:"
    Write-Host "      adb -s $Serial shell appops set $Package SYSTEM_ALERT_WINDOW allow" -ForegroundColor White
}

Write-Host ""
Ok "Files written. Rebuild and reinstall:"
Write-Host "      powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1" -ForegroundColor White
Write-Host ""
Write-Host "You also need to rebuild the native module first, because silent aim is new" -ForegroundColor Yellow
Write-Host "native code:" -ForegroundColor Yellow
Write-Host "      powershell -ExecutionPolicy Bypass -File .\build_native.ps1" -ForegroundColor White
