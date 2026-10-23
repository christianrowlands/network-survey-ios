#!/usr/bin/env bash
# Prints an xcodebuild destination ("id=<udid>") for an available iPhone
# simulator on the newest installed iOS runtime, so commands work whatever
# simulators this Xcode created. CI uses it too.
#
# Usage: xcodebuild test ... -destination "$(scripts/sim-destination.sh)"
set -euo pipefail

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
# Newest iOS runtime first, e.g. com.apple.CoreSimulator.SimRuntime.iOS-27-0
ios = [(tuple(int(n) for n in r.split(".iOS-")[1].split("-")), r) for r in devices if ".iOS-" in r]
for _, runtime in sorted(ios, reverse=True):
    for d in devices[runtime]:
        if d["name"].startswith("iPhone"):
            print(d["udid"]); sys.exit()
')
if [ -z "$udid" ]; then
    echo "sim-destination: no iPhone simulator found; add one in Xcode (Window > Devices and Simulators)" >&2
    exit 1
fi
echo "id=$udid"
