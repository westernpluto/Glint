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
t 90 xcrun simctl io "$UDID" enumerate > "$OUT/enumerate.txt" 2>&1 || true
t 30 xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
t 30 xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
t 120 xcrun simctl install "$UDID" "$APP" || { note "install failed"; exit 0; }

shot() {  # display name
  t 40 xcrun simctl io "$UDID" screenshot --display="$1" "$OUT/$2.png" >/dev/null 2>>"$LOG" \
    && note "shot $2" || note "screenshot failed: $2"
}

run_scene() {  # scene
  t 20 xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  t 60 xcrun simctl launch "$UDID" "$BUNDLE" -GlintScene "$1" -GlintQuery "4k nature" >/dev/null || note "launch failed: $1"
  sleep 16
}

# Phase 1: the outer display (the default when the simulated device is closed).
for scene in home watch nowplaying music search mini library; do
  run_scene "$scene"
  shot 1 "outer-$scene"
done
t 30 xcrun simctl ui "$UDID" appearance dark >/dev/null 2>&1 || true
run_scene home; shot 1 "outer-home-dark"
run_scene watch; shot 1 "outer-watch-dark"
t 30 xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true

# Phase 2: "open" the device — power the inner display, switch the outer one off.
t 30 xcrun simctl io "$UDID" screenConfig --display=2 power on >>"$LOG" 2>&1 || note "inner power on failed"
t 30 xcrun simctl io "$UDID" screenConfig --display=1 power off >>"$LOG" 2>&1 || note "outer power off failed"
sleep 15
t 90 xcrun simctl io "$UDID" enumerate > "$OUT/enumerate-open.txt" 2>&1 || true
for scene in home watch nowplaying music; do
  run_scene "$scene"
  shot 2 "inner-$scene"
done

t 60 xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
t 60 xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
ls -la "$OUT"
