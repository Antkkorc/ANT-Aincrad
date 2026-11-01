# PowerShell Script to Create Java Wrapper Classes for ANT-Aincrad
# Target Directory: C:\Users\anton\AndroidStudioProjects\FFMODROOT\app\src\main\java\com\ffmodroot\
# Usage: Run this script in the FFMODROOT project root or adjust $BASE_PATH

$BASE_PATH = "C:\Users\anton\AndroidStudioProjects\FFMODROOT\app\src\main\java\com\ffmodroot"
if (!(Test-Path $BASE_PATH)) {
    New-Item -ItemType Directory -Force -Path $BASE_PATH | Out-Null
    Write-Host "Created directory: $BASE_PATH"
}

# 1. ModBridge.java
$modBridgeContent = @"
package com.ffmodroot;

public class ModBridge {
    static {
        System.loadLibrary("ant_aincrad");
        System.loadLibrary("shadowhook");
    }

    public native int nativeInit();

    // Callbacks from JNI (core.cpp)
    public void isModLoaded(boolean loaded) {
        android.util.Log.i("FFMODROOT", "Java Callback: isModLoaded = " + loaded);
        // Trigger UI or feature logic here
    }

    public void onHookTriggered() {
        android.util.Log.i("FFMODROOT", "Java Callback: onHookTriggered!");
        // Trigger aim/bypass features here
    }
}
"@
$modBridgePath = Join-Path $BASE_PATH "ModBridge.java"
$modBridgeContent | Set-Content -Path $modBridgePath -Encoding UTF8
Write-Host "Created: $modBridgePath"

# 2. Dumper.java
$dumperContent = @"
package com.ffmodroot;

public class Dumper {
    static {
        System.loadLibrary("ant_aincrad");
    }

    public native String getBase();
    public native String dumpOffsets();
}
"@
$dumperPath = Join-Path $BASE_PATH "Dumper.java"
$dumperContent | Set-Content -Path $dumperPath -Encoding UTF8
Write-Host "Created: $dumperPath"

# 3. Injector.java
$injectorContent = @"
package com.ffmodroot;

public class Injector {
    static {
        System.loadLibrary("ant_aincrad");
    }

    public native boolean initHooks();
    public native String getIl2cppBase();
}
"@
$injectorPath = Join-Path $BASE_PATH "Injector.java"
$injectorContent | Set-Content -Path $injectorPath -Encoding UTF8
Write-Host "Created: $injectorPath"

# 4. MainActivity.java
$mainActivityContent = @"
package com.ffmodroot;

import android.os.Bundle;
import android.app.Activity;
import android.util.Log;

public class MainActivity extends Activity {
    private ModBridge modBridge;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Set content view or hide (Grey screen fix: ensure layout exists or handle background)
        // setContentView(R.layout.activity_main); 
        
        Log.i("ANT-Aincrad", "ANT-Aincrad initialising...");
        
        modBridge = new ModBridge();
        int result = modBridge.nativeInit();
        
        if (result == 0) {
            Log.i("ANT-Aincrad", "Native Init Started Successfully");
        } else {
            Log.e("ANT-Aincrad", "Native Init Failed with code: " + result);
        }
        
        // Keep app alive or finish based on logic
        // finish(); 
    }
}
"@
$mainActivityPath = Join-Path $BASE_PATH "MainActivity.java"
$mainActivityContent | Set-Content -Path $mainActivityPath -Encoding UTF8
Write-Host "Created: $mainActivityPath"

Write-Host "All Java wrapper classes created successfully. Proceed to build with Gradle."
