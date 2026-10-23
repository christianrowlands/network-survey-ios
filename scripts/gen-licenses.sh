#!/usr/bin/env bash
# Generates NetworkSurvey/Screens/Settings/Resources/third-party-licenses.json
# (committed): name, version, license and full license and notice text of
# every Swift package the app resolves, plus the vendored NS Messaging protos
# and the source note for the bundled Bluetooth SIG assigned numbers, for the
# Open-source licenses screen.
#
# Usage: scripts/gen-licenses.sh [--check] [--checkouts <dir>]
#   --check            change nothing; fail if the JSON is stale.
#   --checkouts <dir>  package checkouts to read licenses from (for example
#                      <DerivedData>/SourcePackages/checkouts). By default the
#                      SurveyCore package is resolved and its checkouts used.
#
# Needs git and python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
CHECKOUTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --checkouts) CHECKOUTS="${2:?--checkouts needs a directory}"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$CHECKOUTS" ]; then
  swift package resolve --package-path "$ROOT/Packages/SurveyCore" >/dev/null
  CHECKOUTS="$ROOT/Packages/SurveyCore/.build/checkouts"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
mkdir -p "$OUT"
python3 -I - "$ROOT" "$CHECKOUTS" "$OUT" <<'PY'
import glob, json, os, subprocess, sys

root, checkouts, out = sys.argv[1:4]

# Swift packages, from the committed Package.resolved files of the local packages.
pins = {}
for path in sorted(glob.glob(os.path.join(root, "Packages", "*", "Package.resolved"))):
    for pin in json.load(open(path))["pins"]:
        pins[pin["identity"]] = pin
names = {
    "grdb.swift": "GRDB.swift", "grpc-swift-2": "gRPC Swift 2", "grpc-swift-nio-transport": "gRPC Swift NIO Transport",
    "grpc-swift-protobuf": "gRPC Swift Protobuf", "mqtt-nio": "MQTT NIO", "swift-algorithms": "Swift Algorithms",
    "swift-asn1": "Swift ASN.1", "swift-async-algorithms": "Swift Async Algorithms", "swift-atomics": "Swift Atomics",
    "swift-certificates": "Swift Certificates", "swift-collections": "Swift Collections", "swift-crypto": "Swift Crypto",
    "swift-http-structured-headers": "Swift HTTP Structured Headers", "swift-http-types": "Swift HTTP Types",
    "swift-log": "SwiftLog", "swift-nio": "SwiftNIO", "swift-nio-extras": "SwiftNIO Extras",
    "swift-nio-http2": "SwiftNIO HTTP/2", "swift-nio-ssl": "SwiftNIO SSL",
    "swift-nio-transport-services": "SwiftNIO Transport Services", "swift-numerics": "Swift Numerics",
    "swift-protobuf": "SwiftProtobuf", "swift-service-lifecycle": "Swift Service Lifecycle", "swift-system": "Swift System",
}

# License files of vendored code compiled into the app, beyond the top-level ones.
nested = {"swift-nio": ["Sources/CNIOLLHTTP/LICENSE"]}

def spdx(text):
    if "Apache License" in text and "Version 2.0" in text:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT"
    if "Redistribution and use in source and binary forms" in text and "Neither the name" in text:
        return "BSD-3-Clause"
    sys.exit("unknown license text")

def read_text(directory, prefixes):
    parts = []
    for entry in sorted(os.listdir(directory)):
        if any(entry.upper().startswith(p) for p in prefixes) and os.path.isfile(os.path.join(directory, entry)):
            parts.append(open(os.path.join(directory, entry), encoding="utf-8").read().strip())
    return parts

entries = []
problems = []
for identity, pin in sorted(pins.items()):
    location = pin["location"]
    folder = os.path.join(checkouts, location.rstrip("/").split("/")[-1].removesuffix(".git"))
    if not os.path.isdir(folder):
        problems.append(f"missing checkout for {identity} in {checkouts}")
        continue
    head = subprocess.run(["git", "-C", folder, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head and head != pin["state"]["revision"]:
        problems.append(f"{identity}: checkout is at {head[:12]}, Package.resolved pins {pin['state']['revision'][:12]}")
    licenses = read_text(folder, ("LICENSE", "COPYING"))
    notices = read_text(folder, ("NOTICE",))
    for relative in nested.get(identity, []):
        with open(os.path.join(folder, relative), encoding="utf-8") as f:
            notices.append(f"{relative}:\n\n" + f.read().strip())
    if not licenses:
        problems.append(f"{identity}: no license file")
        continue
    entries.append({
        "name": names.get(identity, identity), "version": pin["state"].get("version", pin["state"]["revision"][:12]),
        "license": spdx(licenses[0]), "url": location.removesuffix(".git"),
        "text": "\n\n".join(licenses + notices),
    })
if problems:
    sys.exit("\n".join(problems))

ns_license = open(os.path.join(root, "proto", "ns-messaging", "LICENSE"), encoding="utf-8").read().strip()
entries.append({
    "name": "NS Messaging API protos", "version": "2.6.0", "license": spdx(ns_license), "url": None,
    "text": ns_license,
})
# The Bluetooth SIG assigned numbers carry no license; record their source
# and the SIG's own notice, as the Android app's assets README does.
resources = os.path.join(root, "NetworkSurvey", "Screens", "Details", "Resources")
with open(os.path.join(resources, "member_uuids.yaml"), encoding="utf-8") as f:
    sig_notice = "\n".join(line[2:] if line.startswith("# ") else line.lstrip("#")
                           for line in f.read().splitlines() if line.startswith("#"))
entries.append({
    "name": "Bluetooth SIG Assigned Numbers", "version": "company, member and service UUID lists",
    "license": "Source", "url": "https://bitbucket.org/bluetooth-SIG/public",
    "text": "The Bluetooth company identifiers and member service UUIDs are the Bluetooth SIG Assigned Numbers, "
            "from https://bitbucket.org/bluetooth-SIG/public (assigned_numbers/company_identifiers/"
            "company_identifiers.yaml, assigned_numbers/uuids/member_uuids.yaml and assigned_numbers/uuids/"
            "service_uuids.yaml). The company and member lists are the same files the Network Survey Android "
            "app ships. Refresh them with scripts/update-bluetooth-numbers.sh.\n\n"
            + sig_notice.strip(),
})
entries.sort(key=lambda e: e["name"].lower())
# This app's own license and NOTICE, shown first on the screen.
with open(os.path.join(root, "LICENSE"), encoding="utf-8") as f:
    app_license = f.read().strip()
with open(os.path.join(root, "NOTICE"), encoding="utf-8") as f:
    app_notice = f.read().strip()
entries.insert(0, {
    "name": "Network Survey", "version": "This app", "license": spdx(app_license), "url": None, "app": True,
    "text": app_notice + "\n\n" + app_license,
})
with open(os.path.join(out, "third-party-licenses.json"), "w", encoding="utf-8") as f:
    json.dump(entries, f, indent=1, ensure_ascii=False, sort_keys=True)
    f.write("\n")
PY

LICENSES="$ROOT/NetworkSurvey/Screens/Settings/Resources/third-party-licenses.json"
if [ "$CHECK" = 1 ]; then
  cmp -s "$OUT/third-party-licenses.json" "$LICENSES" \
    || { echo "third-party-licenses.json is stale: run scripts/gen-licenses.sh" >&2; exit 1; }
  echo "third-party-licenses.json is up to date"
else
  mkdir -p "$(dirname "$LICENSES")"
  cp "$OUT/third-party-licenses.json" "$LICENSES"
  echo "wrote $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$LICENSES") license entries"
fi
