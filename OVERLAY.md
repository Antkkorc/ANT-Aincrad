# The floating menu

## Why it did not exist

Nothing in this project ever drew anything over Free Fire. Evidence:

```
$ strings -a libant_aincrad.so | grep -iE "imgui|egl|overlay|window|menu|button|motion"
(no output - 0 matches)

$ strings -a libant_aincrad.so | grep -E "^lib.*\.so$"
libc.so libm.so libshadowhook.so liblog.so libandroid.so libc++_shared.so libdl.so
```

No `libEGL`, no `libGLESv2`, no ImGui, no widget code. The library hooks two
things (`SetAimRotation`, `sendto`/`send`) and writes flags to
`/data/local/tmp/ant_aincrad.cfg`.

And the APK's dex contains exactly:

```
MainActivity, MainActivityKt, ComposableSingletons, ModBridge, RootInjector, Screen, ui.theme.*
```

No `*Service`, so no window could ever be added. The toggles you were tapping
are the launcher's Compose screens, which live *inside* the app.

(Aincrad Client's menu is a separate ImGui renderer injected into the game with
an `eglSwapBuffers` hook. That is a different piece of software.)

## What `add_floating_menu.ps1` adds

| file | role |
|---|---|
| `OverlayMenuService.kt` | foreground Service that adds a `TYPE_APPLICATION_OVERLAY` window. **Gated:** it shows one `INJECT BYPASS` button first; pressing it enables the bypasses, calls `Injector.initHooks()`, then reveals the feature list (Silent Aim). Draggable title, collapse chevron (body only), live status, Close |
| `OverlayAutoStart.kt` | `ContentProvider` that starts the service when the app process comes up, so `MainActivity.kt` does not have to be edited |
| `Injector.kt` | Kotlin `object` matching the JNI symbols the library already exports (`initHooks`, `getIl2cppBase`). Kotlin, not Java — a `.java` here reproduces the duplicate-class failure |
| `ModBridge.kt` | only appends `setSilentAimEnabled` / `isSilentAimActive` if missing; the rest of the file is untouched |
| `AndroidManifest.xml` | `SYSTEM_ALERT_WINDOW`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `POST_NOTIFICATIONS`, plus the `<service>` and `<provider>` |

The switches call the **same** `ModBridge.setXxxEnabled()` functions the Compose
UI calls, so the native module writes the same config file and the in-game copy
picks it up within 500 ms.

## Overlay permission

Android refuses to draw over another app without `SYSTEM_ALERT_WINDOW`. On a
rooted BlueStacks the dependable route is one adb command:

```powershell
adb -s 127.0.0.1:5555 shell appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow
adb -s 127.0.0.1:5555 shell appops get com.ffmodroot SYSTEM_ALERT_WINDOW
```

Expect `SYSTEM_ALERT_WINDOW: allow`. Fallbacks, in order:

1. `adb -s 127.0.0.1:5555 shell su -c 'appops set com.ffmodroot SYSTEM_ALERT_WINDOW allow'`
2. In the emulator: Settings → Apps → ANT AINCRAD → *Display over other apps* → allow
3. `add_floating_menu.ps1 -Grant` does step 1 and reports the resulting state

## How to tell it is working

```
adb -s 127.0.0.1:5555 logcat -s ANT-Aincrad-Overlay
```

| line | meaning |
|---|---|
| `OverlayAutoStart: overlayAllowed=true` | permission fine, service about to start |
| `menu displayed` | the window is on screen |
| `overlayAllowed=false` + the `appops` hint | permission missing — run the adb command |

## Honest limits

* This is an **app window above the game**, not a renderer inside it. Some games
  draw in a surface that hides overlays; Free Fire normally does not.
* It cannot show in-game values (enemy positions, HP) — the module exposes no
  such data across processes yet. Toggles and status only.
* A true in-game ImGui menu means vendoring ImGui, hooking `eglSwapBuffers`, and
  feeding it touch events from the game process. That is a separate project; ask
  if you want it and I will scope it.
* Toggling a switch is only half the job — the hooks still have to be loaded
  inside Free Fire with `deploy_ff.ps1`.

## The inject gate

The menu deliberately behaves like an Aincrad-style client: **features are locked
until you press INJECT BYPASS.**

What that button really does:

1. switches both bypass flags on (lobby + game),
2. calls `Injector.initHooks()` in this process,
3. reports the truth.

In the launcher process `libil2cpp.so` is never mapped, so step 3 says *hooks NOT
installed* in red and names `deploy_ff.ps1`. The feature list unlocks anyway so
you can see and set Silent Aim — but the status line keeps telling you the hooks
are not live until they actually are. It will not pretend.

The gate state persists in `SharedPreferences`, so a second launch goes straight
to the feature list.

## Adding features later

`showMenu()` builds the list with:

```kotlin
addToggle(features, "Silent aim", "silent_aim") { on -> ModBridge.setSilentAimEnabled(on) }
```

One line per feature. The native side needs a matching
`Java_com_ffmodroot_ModBridge_setXxxEnabled` export in `jni/core.cpp` plus an
`external fun` in `ModBridge.kt`; `build_native.ps1` will refuse to finish if the
symbol is missing.

## If the app crashes after adding the overlay

Three failure modes were possible and are now handled defensively:

**1. ABI mismatch (most likely on BlueStacks).** BlueStacks runs an **x86_64**
process (`Unexpected CPU variant for X86 using defaults: x86_64`), while the APK
ships `arm64-v8a` only. `System.loadLibrary("ant_aincrad")` then throws
`UnsatisfiedLinkError`, which becomes `ExceptionInInitializerError` on every
later reference.

The overlay used to call `ModBridge` every second from a Service, so it hit this
at startup. Now `nativeLibPresent()` checks
`applicationInfo.nativeLibraryDir/libant_aincrad.so` **before** any `ModBridge`
access, and the status line says so:

```
no arm64 native library for this ABI
(this emulator reports x86_64)
toggles saved, hooks unavailable
```

`Injector` loads with `runCatching`, so referencing it can never throw either.
The toggles still work and are still written to the config file — only the hooks
are unavailable.

**2. A throwing ContentProvider.** `OverlayAutoStart.onCreate()` runs before any
Activity exists; an exception there is indistinguishable from "the app crashes on
launch". The whole body is wrapped in try/catch and logs instead.

**3. `android.widget.Switch`.** It resolves `switchStyle` /
`colorControlActivated` from the theme, and a Service is inflated with the
*application* theme. A Compose-only theme can leave those undefined and throw
`Resources.NotFoundException` while building the view. Replaced with a plain
`Button` showing `ON` / `OFF`.

### Instant revert

```powershell
powershell -ExecutionPolicy Bypass -File .\add_floating_menu.ps1 -Remove
powershell -ExecutionPolicy Bypass -File .\fix_ffmodroot.ps1
```

`-Remove` deletes `OverlayMenuService.kt`, `OverlayAutoStart.kt`, `Injector.kt`,
strips the two silent-aim externals out of `ModBridge.kt`, and removes the
service, provider and permissions from the manifest — putting the project back to
the last known-good app.

### Getting the actual crash

```powershell
adb -s 127.0.0.1:5555 logcat -b crash -d -t 40
```

The first `Caused by:` line is the only thing needed to fix it.
