#!/usr/bin/env bash
# Captures iPhone Duo simulator screenshots of the main screens on both displays.
# Usage: scripts/screenshots.sh <path-to-Glint.app> <output-dir>
set -uo pipefail
APP="$1"; OUT="$2"
BUNDLE="com.glint.Glint"
mkdir -p "$OUT"
LOG="$OUT/log.txt"
# macOS has no `timeout`; perl's alarm gives every simulator call a hard limit.
t() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
note() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

t 60 xcrun simctl list devicetypes > "$OUT/devicetypes.txt" 2>&1 || true
t 60 xcrun simctl list runtimes > "$OUT/runtimes.txt" 2>&1 || true

DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-Duo}"
# Newest runtimes first (device-specific ones included); use the first that accepts the device.
RUNTIMES=$(t 60 xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rs.sort(key=lambda r: ([int(x) for x in r["version"].split(".")], len(r["identifier"])), reverse=True)
print("\n".join(r["identifier"] for r in rs))')

UDID=""
for rt in $RUNTIMES; do
  UDID=$(t 60 xcrun simctl create "glint-duo" "$DEVICE_TYPE" "$rt" 2>>"$LOG") && { note "created on $rt"; break; }
  note "runtime $rt rejected $DEVICE_TYPE"
  UDID=""
done
[ -n "$UDID" ] || { note "could not create $DEVICE_TYPE"; exit 0; }

t 120 xcrun simctl boot "$UDID" || note "boot returned an error"
t 300 xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || note "bootstatus timed out"
t 30 xcrun simctl io "$UDID" enumerate > "$OUT/enumerate.txt" 2>&1 || true
t 30 xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
t 30 xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
t 120 xcrun simctl install "$UDID" "$APP" || { note "install failed"; exit 0; }

shoot() {  # name
  local any=0
  for d in 1 2; do
    if t 30 xcrun simctl io "$UDID" screenshot --display="$d" "$OUT/$1-d$d.png" >/dev/null 2>>"$LOG"; then any=1; fi
  done
  if [ "$any" = 0 ]; then t 30 xcrun simctl io "$UDID" screenshot "$OUT/$1.png" >/dev/null 2>>"$LOG" || true; fi
  note "shot $1"
}

power() {  # display on|off
  t 30 xcrun simctl io "$UDID" screenConfig --display="$1" power "$2" >>"$LOG" 2>&1 || note "power $1 $2 failed"
}

for scene in home watch nowplaying music search mini; do
  t 20 xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  t 60 xcrun simctl launch "$UDID" "$BUNDLE" -GlintScene "$scene" -GlintQuery "4k nature" >/dev/null || note "launch failed: $scene"
  sleep 16
  shoot "$scene-A"
  # Simulate folding/unfolding: swap which display is powered, then restore.
  power 1 off; power 2 on; sleep 6; shoot "$scene-B"
  power 2 off; power 1 on; sleep 6; shoot "$scene-C"
  power 2 on
done

t 30 xcrun simctl ui "$UDID" appearance dark >/dev/null 2>&1 || true
t 20 xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
t 60 xcrun simctl launch "$UDID" "$BUNDLE" -GlintScene home >/dev/null || true
sleep 14
shoot "home-dark"

t 30 xcrun simctl io "$UDID" enumerate > "$OUT/enumerate-end.txt" 2>&1 || true
t 60 xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
t 60 xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
ls -la "$OUT"
