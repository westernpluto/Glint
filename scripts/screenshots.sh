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

shot() {  # display name — one retry, since a busy simulator sometimes misses the first
  for attempt in 1 2; do
    t 40 xcrun simctl io "$UDID" screenshot --display="$1" "$OUT/$2.png" >/dev/null 2>>"$LOG" \
      && { note "shot $2"; return; }
    sleep 5
  done
  note "screenshot failed: $2"
}

install_app() {  # one retry: a freshly booted simulator can still be settling
  for attempt in 1 2; do
    t 180 xcrun simctl install "$UDID" "$APP" && return 0
    note "install attempt $attempt failed"
    sleep 20
  done
  return 1
}

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
install_app || { note "install failed"; exit 0; }


run_scene() {  # scene [orientation]
  t 20 xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  t 60 xcrun simctl launch "$UDID" "$BUNDLE" -GlintScene "$1" -GlintQuery "4k nature" \
    -GlintOrientation "${2:-portrait}" >/dev/null || note "launch failed: $1"
  sleep 16
}

# The iPhone Duo outer display ("primary").
for scene in home watch nowplaying mini library search; do
  run_scene "$scene"
  shot primary "outer-$scene"
done

t 60 xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
t 60 xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
ls -la "$OUT"

# Inner-display stand-in: iPad mini — regular width and close to the Duo inner panel's size.
# (simctl can't move an app to the Duo inner panel without a fold event.)
UDID=""
for IPAD in com.apple.CoreSimulator.SimDeviceType.iPad-mini-A20-Pro com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro; do
  for rt in $RUNTIMES; do
    UDID=$(t 60 xcrun simctl create "glint-ipad" "$IPAD" "$rt" 2>>"$LOG") && { note "$IPAD on $rt"; break 2; }
    UDID=""
  done
done
if true; then
  if [ -n "$UDID" ]; then
    t 120 xcrun simctl boot "$UDID" || true
    t 480 xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || note "iPad bootstatus timed out"
    t 30 xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
    t 30 xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
    if install_app; then
      for scene in home watch nowplaying music; do
        run_scene "$scene" portrait
        # The iPad has one display; no --display needed.
        for attempt in 1 2; do
          t 40 xcrun simctl io "$UDID" screenshot "$OUT/inner-$scene.png" >/dev/null 2>>"$LOG" \
            && { note "shot inner-$scene"; break; }
          sleep 5
        done
      done
    else
      # Without the app, captures would only show the simulator's home screen.
      note "iPad install failed; skipping inner-display captures"
    fi
    t 60 xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    t 60 xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
fi
ls -la "$OUT"
