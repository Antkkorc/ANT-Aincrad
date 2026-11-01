# ANT-Aincrad — what was actually broken

Written after disassembling `libs/arm64-v8a/libant_aincrad.so` and auditing the
`FFMODROOT` project tree. Everything below is evidence, not guesswork.

---

## 1. The build error was not really a BOM problem

`javac` reported `illegal character: '\ufeff'` on four files:

```
Dumper.java  Injector.java  MainActivity.java  ModBridge.java
```

Those four files should never have existed. `Get-ChildItem -Recurse` on the app
shows Android Studio already has:

```
app\src\main\java\com\ffmodroot\MainActivity.kt     22 844 bytes
app\src\main\java\com\ffmodroot\ModBridge.kt           611 bytes
app\src\main\java\com\ffmodroot\RootInjector.kt      4 036 bytes
```

Each `.java` declared the **same fully-qualified class** as the `.kt` file next
to it. So even after removing the BOM, javac would have failed with
`duplicate class: com.ffmodroot.MainActivity`.

Worse, `ModBridge.java` declared `public native int nativeInit();` — that symbol
**does not exist** in the shipped library (see §2). Calling it is an immediate
`UnsatisfiedLinkError` at startup.

**Fix applied:** the four `.java` files are deleted (`fix_ffmodroot.ps1`
step 1). Nothing is generated any more.

The BOM appeared in the first place because Windows PowerShell 5.1's
`[System.Text.Encoding]::UTF8` *does* emit a BOM. The BOM-less form is:

```powershell
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $content, $enc)
```

---

## 2. The library you ship was never the library in this repo

`nm -D` / `readelf -sW` on `libs/arm64-v8a/libant_aincrad.so` (15 232 bytes):

```
Java_com_ffmodroot_ModBridge_isModLoaded
Java_com_ffmodroot_ModBridge_setAimEnabled
Java_com_ffmodroot_ModBridge_setAntibanEnabled
Java_com_ffmodroot_ModBridge_setLobbyBypassEnabled
Java_com_ffmodroot_ModBridge_setGameBypassEnabled
Java_com_ffmodroot_ModBridge_isLobbyBypassActive
Java_com_ffmodroot_ModBridge_isGameBypassActive
Java_com_ffmodroot_Dumper_getBase
Java_com_ffmodroot_Dumper_dumpOffsets
Java_com_ffmodroot_Injector_initHooks
Java_com_ffmodroot_Injector_getIl2cppBase
_Z16ant_aincrad_initv            <- ant_aincrad_init()
```

No `nativeInit`. The previous `jni/core.cpp` in this repo exported
`Java_com_ffmodroot_ModBridge_nativeInit` instead — a different, incompatible
contract.

`jni/core.cpp` also **could not compile**: the dump helper contained a literal

```
#define DUMPOFF(name, rva) \\\
```

i.e. a backslash-backslash-backslash and the letter `n`, instead of a line
continuation. Together with `dumper.cpp` / `injector.cpp` still being listed in
`Android.mk` while their code had been merged into `core.cpp`, the native build
produced duplicate `Java_com_ffmodroot_Dumper_*` and
`Java_com_ffmodroot_Injector_*` symbols and failed to link.

**Fix applied:** `core.cpp` rewritten as a faithful reconstruction of the real
binary (same JNI surface, same behaviour), `dumper.cpp` / `injector.cpp`
removed, `Android.mk` builds `core.cpp` only.

---

## 3. `offsets.h` did not match the shipped library

The shipped `.so` hard-codes its own table. Recovered from the aim thread's
disassembly (`0x16b8`–`0x1848`):

| what | RVA | previously claimed |
|---|---|---|
| CurrentMatch | `0x25C277C` | `0x15E6540` |
| GetPlayerByIdx | `0x12B1600` | `0x15E7440` |
| get_CurHP | `0xAA1A74` | `0x1207CBC` |
| IsLocalPlayer | `0xAACEC8` | `0x15E6B40` |
| IsFiring | `0xAC77A8` | `0x11A1844` |
| get_IsSighting | `0xAF8410` | `0x11A18E0` |
| IsLocalTeammate | `0xAAF4E8` | `0x11BFEA4` |
| get_IsDieing | `0xAB4ABC` | `0x11A11E8` |
| IsVisible | `0xAAEB6C` | `0x11B1254` |
| IsCrouching | `0xAAE66C` | `0x11C315C` |
| get_IsSkyDiving | `0xAAEA48` | `0x11A13CC` |
| get_IsSkyDashing | `0xAAE264` | `0x11B0D5C` |
| Transform_get_position | `0x2908DF8` | `0x61B5E1C` |
| SetAimRotation | `0x11AD820` | `0x11AD820` ✅ |

Only `SetAimRotation` matched. `offsets.h` has been replaced with the recovered
table (`namespace FFV`).

---

## 4. Why the bypass hooks said `FAIL`

The very first thing `ant_aincrad_init()` does after `shadowhook_init`:

```
shadowhook_hook_sym_name("libil2cpp.so", "sendto", hooked, &orig)
shadowhook_hook_sym_name("libil2cpp.so", "send",   hooked, &orig)
```

`sendto` and `send` live in **libc**, not in libil2cpp. Both lookups return
`NULL`, which is what produced:

```
11-01 21:05:04.534  ANT_Aincrad_Core: bypass: sendto=FAIL send=FAIL
```

(Note the binary *does* contain the string `libc.so` at `0xf1c`; the code path
uses it, but the two hooks above are still issued against the wrong module in
this build.)

**Fix applied:** `core.cpp` resolves the real addresses with `dlsym` and hooks
`shadowhook_hook_sym_addr()`, which cannot fail on a missing module name.

---

## 5. The actual reason "features turn on but nothing happens"

This is the important one, and no Java/Kotlin change could ever fix it.

`init_thread()` does this and nothing else until it succeeds:

```c
handle = NULL;
while (!handle && retries < 120) {
    handle = dlopen("libil2cpp.so", RTLD_NOLOAD);   /* /proc/self/maps scan */
    if (!handle) { usleep(500000); retries++; }
}
if (!handle) { LOGE("libil2cpp.so not found"); return NULL; }
```

`com.ffmodroot` is a Compose **launcher UI**. `libil2cpp.so` is a Unity runtime
that only exists inside Free Fire's process. So in the launcher:

* `libil2cpp.so` is never found,
* `SetAimRotation` is never hooked,
* `isModLoaded()` stays `false`,
* and the Compose toggles call `setAimEnabled(true)` on globals that **no code
  in that process reads**.

That is the whole symptom: switches move, game does nothing.

### The fix: run the module inside the game process

`deploy_ff.ps1` preloads it through Zygote's `wrap.<package>` mechanism:

```
setprop wrap.com.dts.freefireth \
  "LD_PRELOAD=/data/local/tmp/libant_aincrad.so LD_LIBRARY_PATH=/data/local/tmp ANT_AINCRAD_AUTOINIT=1"
```

`core.cpp` gained an `__attribute__((constructor))` that calls
`ant_aincrad_init()` when that env var is present, so no ptrace injector is
needed.

Toggle state is shared through `/data/local/tmp/ant_aincrad.cfg`
(`aim=1`, `antiban=0`, …). The UI writes it, the in-game copy polls it.

### Verified once, on device

```
ANT-Aincrad initialising...
bypass: sendto=OK send=OK
libil2cpp.so located / base=0x…
SetAimRotation RVA=0x11ad820
aim hook live
```

Only then does the aim hook (reconstructed at `0x1a24`–`0x20c8`: 59-player scan,
teammate/dead/visible/hp filters, nearest-target selection, quaternion slerp
with smoothing ≈ 3 ticks) ever execute.

---

## Files in this repo now

| file | purpose |
|---|---|
| `jni/core.cpp` | compiles; matches the shipped JNI surface; constructor-driven; dlsym-based bypass hooks; reconstructed aimbot |
| `jni/offsets.h` | offsets recovered from the binary (`namespace FFV`) |
| `jni/Android.mk` | single module, single source, links `-lm` |
| `jni/Application.mk` | arm64-v8a, c++_shared, android-24 |
| `fix_ffmodroot.ps1` | deletes the duplicate `.java` files, strips BOMs, clean build, hard-stops on failure, installs, dumps the real crash buffer |
| `build_native.ps1` | optional `ndk-build` + copy into the app |
| `deploy_ff.ps1` | preloads the module into Free Fire, verifies it, tails the log |
| `create_java_wrappers.ps1` | **removed** — it was generating the duplicate classes |
| `build_and_launch.ps1` | **removed** — superseded by the two scripts above |

---

## 6. Building the module with a modern NDK

`ndk-build` aborts on this project with NDK 30:

```
Android NDK: APP_PLATFORM not set. Defaulting to minimum supported version android-21.
add-application.mk:88: *** Android NDK: Aborting...
```

Nothing in `jni/` had been compiled since. `build_native.ps1` now drives the
NDK's `clang++` directly instead:

```
aarch64-linux-android<api>-clang++ --target=aarch64-linux-android<api> \
    -shared -fPIC -O2 -std=c++17 -fno-exceptions -fno-rtti -nostdlib++ \
    -Ijni core.cpp -Lprebuilt/arm64-v8a -lshadowhook -llog -lm \
    -o libs/arm64-v8a/libant_aincrad.so
```

It picks the API level your NDK actually ships (`24` when available, otherwise
the lowest `>= 21`), so it works on r26, r28 and r30 alike.

`-nostdlib++` is deliberate: `core.cpp` uses only the header-only parts of
`<atomic>`, so no libc++ symbols are emitted (verified with `nm -u`). That keeps
the new module off the older, 9.4 MB `libc++_shared.so` the app currently ships
and avoids an ABI mismatch.

The script then verifies the result with the NDK's `llvm-nm` and fails if any of
the 11 `Java_com_ffmodroot_*` entry points or `_Z16ant_aincrad_initv` is
missing — i.e. it refuses to hand you a `.so` that would crash with
`UnsatisfiedLinkError` again.

---

## 7. Troubleshooting build_native.ps1

```powershell
powershell -ExecutionPolicy Bypass -File .\build_native.ps1
```

| symptom | cause | fix |
|---|---|---|
| `Cannot bind argument to parameter 'Path' because it is an empty string` | `$RepoRoot = $PSScriptRoot` was **empty** in the param default under `powershell -File`, so the first `Join-Path` in the compile step died | fixed: the default is `""` now and the repo is resolved from `$PSScriptRoot`, then `$MyInvocation.MyCommand.Path`, then the current directory — whichever contains `jni\` |
| `ndk-build ... APP_PLATFORM ... Aborting` | legacy `Application.mk` flow, rejected by modern NDKs | fixed: clang is driven directly |
| `no aarch64 clang++ wrapper` / compiler not executable | some NDKs ship an extensionless POSIX shell script beside the `.cmd` wrapper; Windows cannot run it | fixed: `.cmd` is preferred, `.exe` next, extensionless only on non-Windows; plain `clang++.exe` is the fallback |
| symlink/`Out-String` noise, script dies mid-compile | clang writes warnings to **stderr** and `$ErrorActionPreference = "Stop"` turns that into a terminating error | fixed: relaxed to `Continue` around the native calls, exit code checked explicitly |
| `[FAIL] missing symbols: ...` | the `.so` was built from a stale `core.cpp` | re-run `git pull`, then rebuild |

The script refuses to copy a `.so` that is missing any of the 12 entry points, so
a runtime `UnsatisfiedLinkError` cannot slip through again.

---

## 8. Live toggles and the real packet filter

Two gaps that would still have looked like "nothing happens":

**Toggles only applied on restart.** `read_config()` ran once, inside
`ant_aincrad_init()`. Flip a switch in the launcher after the game is already
running and the in-game copy kept the old values until the next launch. There is
now a `config_poll_thread` that re-reads `/data/local/tmp/ant_aincrad.cfg` every
500 ms (guarded by `stat()` mtime, so it only re-reads when the file changed).

**The bypass hooks were pass-through stubs.** They hooked `sendto`/`send`,
latched a flag, and forwarded everything. The shipped binary actually *drops*
matching datagrams. The predicate, recovered from `0x1500`–`0x1648`:

```
dest is AF_INET and len >= 4
payload magic:  buf[0]==0xAA && buf[1]==0x55 && (buf[4]==2 || buf[4]==5)
             || (buf[2] & 0xFC) == 8
lobby:  port - 8000  <= 1999      -> 8000..9999
game:   port - 10000 <= 2000      -> 10000..12000
```

On a match with the corresponding toggle enabled the hook returns `len`
(pretending the datagram left) without calling the real `sendto`, and latches
`isLobbyBypassActive()` / `isGameBypassActive()`. That is what the original
does at `0x1590` / `0x160c`: latch the flag, `mov x0, x2` (return the length),
`ret` — never reaching the trampoline.

Both toggles default to **off**, and `send()` (no destination available) can
only be filtered by the game toggle. Expect up to five
`bypass: dropped ... beacon` lines per process, then silence, so logcat stays
readable.
