#!/usr/bin/env bash
# Prints an xcodebuild destination ("id=<udid>") for an available iPhone
# simulator on the newest installed iOS runtime, so commands work whatever
# simulators this Xcode created. CI uses it too. Warns when that runtime is
# older than the Xcode SDK, since newer iOS versions change how system UI
# (dialogs, sheets, toolbars) is laid out.
#
# Usage: xcodebuild test ... -destination "$(scripts/sim-destination.sh)"
set -euo pipefail

read -r udid version < <(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
# Newest iOS runtime first, e.g. com.apple.CoreSimulator.SimRuntime.iOS-27-0
ios = [(tuple(int(n) for n in r.split(".iOS-")[1].split("-")), r) for r in devices if ".iOS-" in r]
for _, runtime in sorted(ios, reverse=True):
    for d in devices[runtime]:
        if d["name"].startswith("iPhone"):
            print(d["udid"], runtime.split(".iOS-")[1].replace("-", ".")); sys.exit()
') || true
if [ -z "$udid" ]; then
    echo "sim-destination: no iPhone simulator found; add one in Xcode (Window > Devices and Simulators)" >&2
    exit 1
fi
sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
if [ "${version%%.*}" -lt "${sdk%%.*}" ]; then
    echo "sim-destination: newest iOS simulator is $version but the SDK is $sdk; install the current runtime with: xcodebuild -downloadPlatform iOS" >&2
fi
echo "id=$udid"
