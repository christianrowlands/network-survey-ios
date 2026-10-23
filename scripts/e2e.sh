#!/usr/bin/env bash
# End-to-end survey test. Starts the local servers from Tools/E2EHarness (a
# mosquitto broker with a counting subscriber, an NS Messaging gRPC server and
# an NS Analytics stub), runs NetworkSurveyTests/EndToEndTests on an iOS
# simulator against them, then stops them. Needs mosquitto (brew install
# mosquitto), Wireshark's tshark and capinfos, and xcodegen.
#
# Usage: scripts/e2e.sh [extra xcodebuild arguments]
#   E2E_DESTINATION   xcodebuild destination (default: scripts/sim-destination.sh)
#   E2E_DERIVED_DATA  derived data folder (default: build/e2e)
set -euo pipefail
cd "$(dirname "$0")/.."

destination="${E2E_DESTINATION:-$(scripts/sim-destination.sh)}"
derived="${E2E_DERIVED_DATA:-build/e2e}"
work="$(mktemp -d)"

swift build --package-path Tools/E2EHarness --quiet
harness="$(swift build --package-path Tools/E2EHarness --show-bin-path)/e2e-harness"
"$harness" --ports-file "$work/ports.json" >"$work/harness.log" 2>&1 &
harness_pid=$!
trap 'kill "$harness_pid" 2>/dev/null || true; wait "$harness_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 100); do
    [ -s "$work/ports.json" ] && break
    kill -0 "$harness_pid" 2>/dev/null || { cat "$work/harness.log"; exit 1; }
    sleep 0.1
done
[ -s "$work/ports.json" ] || { echo "e2e: the harness did not start"; cat "$work/harness.log"; exit 1; }
http_port="$(sed -E 's/.*"httpPort":([0-9]+).*/\1/' "$work/ports.json")"
echo "e2e: harness ports $(cat "$work/ports.json")"

xcodegen generate --use-cache --quiet
mkdir -p "$derived"
status=0
TEST_RUNNER_NS_E2E_HARNESS="127.0.0.1:$http_port" xcodebuild test \
    -project NetworkSurvey.xcodeproj -scheme NetworkSurvey \
    -destination "$destination" -derivedDataPath "$derived" \
    -only-testing:NetworkSurveyTests/EndToEndTests "$@" >"$derived/e2e-test.log" 2>&1 || true
grep -E "E2E|✘|✔|error:|\*\* TEST" "$derived/e2e-test.log" || true
echo "e2e: full log in $derived/e2e-test.log"
grep -q "\*\* TEST SUCCEEDED \*\*" "$derived/e2e-test.log" || status=1
if ! grep -q "E2E summary" "$derived/e2e-test.log"; then
    echo "e2e: the end-to-end test did not run (is NS_E2E_HARNESS reaching the app?)"
    status=1
fi
exit "$status"
