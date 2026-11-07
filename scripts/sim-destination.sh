#!/usr/bin/env bash
# Prints an xcodebuild destination ("id=<udid>") for an available regular
# iPhone simulator on the newest installed iOS runtime that has one, so
# commands work whatever simulators this Xcode created. The iPhone Duo is
# skipped: its sidebar tab bar is not the layout most people use. CI uses it
# too. Warns when that runtime is older than the Xcode SDK, since newer iOS
# versions change how system UI (dialogs, sheets, toolbars) is laid out.
#
# Usage: xcodebuild test ... -destination "$(scripts/sim-destination.sh)"
set -euo pipefail

read -r udid version < <(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
# Newest iOS runtime first, e.g. com.apple.CoreSimulator.SimRuntime.iOS-27-0.
# Only the numbers are the version: a runtime name can go on after them, as in
# iOS-27-1-iPhone19.
ios = []
for runtime in devices:
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)", runtime)
    if match:
        ios.append((tuple(int(n) for n in match.group(1).split("-")), runtime))
for version, runtime in sorted(ios, reverse=True):
    for d in devices[runtime]:
        if d["name"].startswith("iPhone") and "Duo" not in d["name"]:
            print(d["udid"], ".".join(str(n) for n in version)); sys.exit()
') || true
if [ -z "$udid" ]; then
    echo "sim-destination: no regular iPhone simulator found; add one in Xcode (Window > Devices and Simulators)" >&2
    exit 1
fi
sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
if [ "${version%%.*}" -lt "${sdk%%.*}" ]; then
    echo "sim-destination: newest iOS simulator is $version but the SDK is $sdk; install the current runtime with: xcodebuild -downloadPlatform iOS" >&2
fi
echo "id=$udid"
