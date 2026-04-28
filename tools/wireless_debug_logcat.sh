#!/usr/bin/env bash
set -euo pipefail

ADB_BIN="${ADB_BIN:-$HOME/Android/Sdk/platform-tools/adb}"
DEVICE_SERIAL="${1:-adb-5d52ca3f0505-GKifDP._adb-tls-connect._tcp}"
APP_ID="${APP_ID:-com.example.panel}"
ACTIVITY="${ACTIVITY:-com.example.panel.MainActivity}"

if [[ ! -x "$ADB_BIN" ]]; then
  echo "adb not found: $ADB_BIN" >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter is not in PATH" >&2
  exit 1
fi

echo "==> Waiting for device: $DEVICE_SERIAL"
"$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device

echo "==> Clearing previous logcat buffer"
"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -c

echo "==> Installing debug APK"
flutter install -d "$DEVICE_SERIAL"

echo "==> Launching $APP_ID/$ACTIVITY"
"$ADB_BIN" -s "$DEVICE_SERIAL" shell am start \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  -n "$APP_ID/$ACTIVITY" >/dev/null

echo "==> Waiting for app process"
PID=""
for _ in {1..30}; do
  PID="$("$ADB_BIN" -s "$DEVICE_SERIAL" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')"
  if [[ -n "$PID" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$PID" ]]; then
  echo "Failed to find PID for $APP_ID on $DEVICE_SERIAL" >&2
  exit 1
fi

echo "==> Streaming logcat for PID $PID"
echo "    Press Ctrl+C to stop"
echo

"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -d -v time --pid="$PID"
exec "$ADB_BIN" -s "$DEVICE_SERIAL" logcat -v time --pid="$PID"
