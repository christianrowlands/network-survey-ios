#!/usr/bin/env bash
# Refreshes the bundled Bluetooth SIG assigned numbers in
# NetworkSurvey/Screens/Details/Resources from
# https://bitbucket.org/bluetooth-SIG/public (assigned_numbers/):
#   company_identifiers.yaml and member_uuids.yaml (the same files the
#   Network Survey Android app ships), and service_uuids.yaml (GATT service
#   names for the Bluetooth detail screen).
# The files are committed as downloaded; the app parses them at runtime.
#
# Usage: scripts/update-bluetooth-numbers.sh [--from <dir>]
#   --from <dir>  copy the files found in a local directory (for example the
#                 Android app's assets) and download only the missing ones.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/NetworkSurvey/Screens/Details/Resources"
BASE="https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers"
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:?--from needs a directory}"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for entry in company_identifiers/company_identifiers.yaml uuids/member_uuids.yaml uuids/service_uuids.yaml; do
  name="$(basename "$entry")"
  if [ -n "$FROM" ] && [ -f "$FROM/$name" ]; then
    cp "$FROM/$name" "$WORK/$name"
  else
    curl -sfL -o "$WORK/$name" "$BASE/$entry"
  fi
done

# Refuse anything that does not look like the expected lists.
grep -q '^company_identifiers:' "$WORK/company_identifiers.yaml" || { echo "company_identifiers.yaml: unexpected content" >&2; exit 1; }
for name in member_uuids.yaml service_uuids.yaml; do
  grep -q '^uuids:' "$WORK/$name" || { echo "$name: unexpected content" >&2; exit 1; }
done

mkdir -p "$DEST"
cp "$WORK/company_identifiers.yaml" "$WORK/member_uuids.yaml" "$WORK/service_uuids.yaml" "$DEST/"
echo "company IDs: $(grep -c 'value: 0x' "$DEST/company_identifiers.yaml")," \
  "member UUIDs: $(grep -c 'uuid: 0x' "$DEST/member_uuids.yaml")," \
  "service UUIDs: $(grep -c 'uuid: 0x' "$DEST/service_uuids.yaml")"
