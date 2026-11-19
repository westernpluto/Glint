#!/usr/bin/env bash
# Captures simulator screenshots of the main screens for design review.
# Usage: scripts/screenshots.sh <path-to-Glint.app> <output-dir>
set -uo pipefail
APP="$1"; OUT="$2"
BUNDLE="com.glint.Glint"
mkdir -p "$OUT"

xcrun simctl list devicetypes > "$OUT/devicetypes.txt"
xcrun simctl list runtimes > "$OUT/runtimes.txt"
xcrun simctl help > "$OUT/simctl-help.txt" 2>&1 || true
xcrun simctl io help > "$OUT/simctl-io-help.txt" 2>&1 || true

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')
echo "Runtime: $RUNTIME"
[ -n "$RUNTIME" ] || { echo "No iOS simulator runtime"; exit 0; }

# Device types: every iPhone Duo variant, plus the newest regular iPhone.
xcrun simctl list devicetypes -j | python3 -c '
import json, sys
ts = [t for t in json.load(sys.stdin)["devicetypes"] if t.get("productFamily") == "iPhone"]
duo = [t for t in ts if "duo" in t["name"].lower()]
for t in duo: print("duo|" + t["identifier"])
pro = [t for t in ts if "duo" not in t["name"].lower() and "Pro" in t["name"] and "Max" not in t["name"]]
if pro: print("iphone|" + pro[-1]["identifier"])
' > "$OUT/targets.txt"
cat "$OUT/targets.txt"

SCENES="home watch nowplaying music search mini library"

capture() {
  local tag="$1" dtype="$2"
  local udid
  udid=$(xcrun simctl create "glint-$tag" "$dtype" "$RUNTIME") || { echo "create failed for $dtype"; return; }
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP"
  for scene in $SCENES; do
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$BUNDLE" -GlintScene "$scene" -GlintQuery "4k nature" >/dev/null
    sleep 16
    xcrun simctl io "$udid" screenshot "$OUT/$tag-$scene.png" >/dev/null 2>&1 || echo "screenshot failed: $tag $scene"
    # Duo has two displays; try capturing every display the simulator exposes.
    for d in internal external; do
      xcrun simctl io "$udid" screenshot --display="$d" "$OUT/$tag-$scene-$d.png" >/dev/null 2>&1 || true
    done
  done
  # Dark appearance of the most important screens.
  xcrun simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
  for scene in home watch; do
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$BUNDLE" -GlintScene "$scene" >/dev/null
    sleep 14
    xcrun simctl io "$udid" screenshot "$OUT/$tag-$scene-dark.png" >/dev/null 2>&1 || true
  done
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}

n=0
while IFS='|' read -r kind ident; do
  [ -n "$ident" ] || continue
  n=$((n + 1))
  capture "$kind$n" "$ident"
done < "$OUT/targets.txt"

ls -la "$OUT"
