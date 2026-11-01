# PowerShell Script to Create Java Wrapper Classes for ANT-Aincrad
# Target Directory: C:\Users\anton\AndroidStudioProjects\FFMODROOT\app\src\main\java\com\ffmodroot\
# Usage: Run this script in the FFMODROOT project root or adjust $BASE_PATH

$BASE_PATH = "C:\Users\anton\AndroidStudioProjects\FFMODROOT\app\src\main\java\com\ffmodroot"
if (!(Test-Path $BASE_PATH)) {
    New-Item -ItemType Directory -Force -Path $BASE_PATH | Out-Null
    Write-Host "Created directory: $BASE_PATH"
}

# Helper to write file without BOM
function Write-FileNoBOM($path, $content) {
    [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::UTF8)
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
Write-FileNoBOM (Join-Path $BASE_PATH "ModBridge.java") $modBridgeContent
Write-Host "Created: ModBridge.java"

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
Write-FileNoBOM (Join-Path $BASE_PATH "Dumper.java") $dumperContent
Write-Host "Created: Dumper.java"

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
Write-FileNoBOM (Join-Path $BASE_PATH "Injector.java") $injectorContent
Write-Host "Created: Injector.java"

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
Write-FileNoBOM (Join-Path $BASE_PATH "MainActivity.java") $mainActivityContent

Write-Host "SUCCESS: Java wrapper classes created in $BASE_PATH (UTF-8, NO BOM)"
