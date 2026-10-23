#!/usr/bin/env bash
# Syncs the board protocol from the firmware repo, where proto/ns_board.proto
# is the source of truth, and regenerates the Swift code in
# Packages/BoardProtocol. The copy and the generated code are committed.
#
# Usage: scripts/sync-proto.sh [--check] [firmware-repo]
#   firmware-repo  defaults to ../network-survey-esp32 next to this repo.
#   --check        change nothing; fail if the proto copy, the test fixtures
#                  or the generated Swift are stale. Without the firmware repo
#                  it only checks the generated Swift against the local copy.
#
# Needs protoc on PATH (brew install protobuf). protoc-gen-swift is built from
# the SwiftProtobuf version pinned in Packages/BoardProtocol/Package.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
FW=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) FW="$arg" ;;
  esac
done
FW="${FW:-$ROOT/../network-survey-esp32}"

PKG="$ROOT/Packages/BoardProtocol"
PROTO="$ROOT/proto/ns_board.proto"
GENERATED="$PKG/Sources/BoardProtocol/Generated/ns_board.pb.swift"
FIXTURES="$PKG/Tests/BoardProtocolTests/Fixtures"
FW_PROTO="$FW/proto/ns_board.proto"
FW_FIXTURES="$FW/test/fixtures/proto"
# Notification bytes from the firmware's framing code, decoded by BoardKit tests.
FRAMING="$ROOT/Packages/BoardKit/Tests/BoardKitTests/Fixtures/framing"
FW_FRAMING="$FW/test/fixtures/framing"

command -v protoc >/dev/null || { echo "protoc not found (brew install protobuf)" >&2; exit 1; }

HAVE_FW=0
[ -f "$FW_PROTO" ] && HAVE_FW=1
if [ $HAVE_FW -eq 0 ] && [ $CHECK -eq 0 ]; then
  echo "firmware repo not found at $FW (pass its path as an argument)" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift build --package-path "$PKG" --product protoc-gen-swift >/dev/null
PLUGIN="$(swift build --package-path "$PKG" --show-bin-path)/protoc-gen-swift"

# generate <proto-file> <out-dir>
generate() {
  protoc \
    --plugin=protoc-gen-swift="$PLUGIN" \
    -I "$(dirname "$1")" \
    --swift_opt=Visibility=Public \
    --swift_out="$2" \
    "$(basename "$1")"
}

if [ $CHECK -eq 1 ]; then
  STALE=0
  if [ $HAVE_FW -eq 1 ]; then
    if ! cmp -s "$FW_PROTO" "$PROTO"; then
      echo "stale: proto/ns_board.proto differs from the firmware repo" >&2
      STALE=1
    fi
    if ! diff -rq "$FW_FIXTURES" "$FIXTURES" >/dev/null 2>&1; then
      echo "stale: test fixtures differ from the firmware repo" >&2
      STALE=1
    fi
    if ! diff -rq -x README.md "$FW_FRAMING" "$FRAMING" >/dev/null 2>&1; then
      echo "stale: framing fixtures differ from the firmware repo" >&2
      STALE=1
    fi
  else
    echo "note: firmware repo not found at $FW, checking generated code only" >&2
  fi
  generate "$PROTO" "$TMP"
  if ! cmp -s "$TMP/ns_board.pb.swift" "$GENERATED"; then
    echo "stale: ns_board.pb.swift does not match proto/ns_board.proto" >&2
    STALE=1
  fi
  if [ $STALE -eq 0 ]; then
    echo "sync-proto: up to date"
  else
    echo "run scripts/sync-proto.sh to update" >&2
  fi
  exit $STALE
fi

cp "$FW_PROTO" "$PROTO"
rm -rf "$FIXTURES"
mkdir -p "$FIXTURES"
cp "$FW_FIXTURES"/*.bin "$FIXTURES/"
rm -rf "$FRAMING"
mkdir -p "$FRAMING"
cp "$FW_FRAMING"/*.bin "$FRAMING/"
generate "$PROTO" "$TMP"
mkdir -p "$(dirname "$GENERATED")"
cp "$TMP/ns_board.pb.swift" "$GENERATED"
echo "Synced proto/ns_board.proto, $(ls "$FIXTURES" | wc -l | tr -d ' ') proto fixtures, $(ls "$FRAMING" | wc -l | tr -d ' ') framing fixtures, and Generated/ns_board.pb.swift"
