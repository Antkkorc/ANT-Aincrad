#!/system/bin/sh
TARGET_DIR=$1
MODE=$2
if [ -z "$TARGET_DIR" ] || [ -z "$MODE" ]; then
    echo "Usage: $0 </system|/vendor|/product> <ro|rw>"
    exit 1
fi
echo "[+] Attempting to remount $TARGET_DIR as $MODE..."
su -c "mount -o remount,$MODE $TARGET_DIR" 2>/dev/null || {
    PID=$(pidof com.dts.freefireth)
    if [ -n "$PID" ]; then
        nsenter -t "$PID" -m -- mount -o remount,$MODE "$TARGET_DIR" 2>/dev/null
    else
        nsenter -t 1 -m -- mount -o remount,$MODE "$TARGET_DIR"
    fi
}
CURRENT_STATE=$(mount | grep "on $TARGET_DIR" | head -n 1)
echo "[+] Mount status for $TARGET_DIR: $CURRENT_STATE"