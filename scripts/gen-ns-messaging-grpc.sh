#!/usr/bin/env bash
# Generates the Swift messages and gRPC client and server stubs for the NS
# Messaging gRPC services from proto/ns-messaging into
# Packages/Destinations/Sources/Destinations/GRPC/Generated. The generated code
# is committed. It is derived from the NS Messaging API protos (Apache-2.0,
# see proto/ns-messaging/LICENSE and NOTICE).
#
# Usage: scripts/gen-ns-messaging-grpc.sh [--check] [--sync <proto-dir>]
#   --check          change nothing; fail if the generated Swift is stale.
#   --sync <dir>     first copy the protos from an NS Messaging checkout
#                    (its src/main/proto directory).
#
# Needs protoc on PATH (brew install protobuf). protoc-gen-swift and
# protoc-gen-grpc-swift-2 are built from the versions pinned in
# Packages/Destinations/Package.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
SYNC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --sync) SYNC="${2:?--sync needs a directory}"; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

PKG="$ROOT/Packages/Destinations"
PROTO_DIR="$ROOT/proto/ns-messaging"
OUT="$PKG/Sources/Destinations/GRPC/Generated"
SERVICES=(
  com/craxiom/messaging/grpc/wireless_survey.proto
  com/craxiom/messaging/grpc/device_status_stream.proto
  com/craxiom/messaging/grpc/connection_handshake.proto
)

command -v protoc >/dev/null || { echo "protoc not found (brew install protobuf)" >&2; exit 1; }

if [ -n "$SYNC" ]; then
  # Copy every vendored file again, plus anything the services now import.
  python3 - "$SYNC" "$PROTO_DIR" "${SERVICES[@]}" <<'PY'
import os, re, shutil, sys
src, dst, roots = sys.argv[1], sys.argv[2], sys.argv[3:]
seen = set()
def visit(name):
    if name in seen or name.startswith("google/"):
        return
    seen.add(name)
    path = os.path.join(src, name)
    for imported in re.findall(r'^import "([^"]+)";', open(path).read(), re.M):
        visit(imported)
for root in roots:
    visit(root)
for name in sorted(seen):
    os.makedirs(os.path.dirname(os.path.join(dst, name)), exist_ok=True)
    shutil.copyfile(os.path.join(src, name), os.path.join(dst, name))
print(f"synced {len(seen)} protos")
PY
fi

swift build --package-path "$PKG" --product protoc-gen-swift >/dev/null
swift build --package-path "$PKG" --product protoc-gen-grpc-swift-2 >/dev/null
BIN="$(swift build --package-path "$PKG" --show-bin-path)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$PROTO_DIR"
PROTOS=$(find com -name '*.proto' | sort)
# Messages for every proto, gRPC stubs only for the files with services.
# shellcheck disable=SC2086
protoc \
  --plugin=protoc-gen-swift="$BIN/protoc-gen-swift" \
  -I . \
  --swift_opt=Visibility=Internal,FileNaming=PathToUnderscores \
  --swift_out="$TMP" \
  $PROTOS
protoc \
  --plugin=protoc-gen-grpc-swift="$BIN/protoc-gen-grpc-swift-2" \
  -I . \
  --grpc-swift_opt=Visibility=Internal,FileNaming=PathToUnderscores,Client=true,Server=true \
  --grpc-swift_out="$TMP" \
  "${SERVICES[@]}"

if [ $CHECK -eq 1 ]; then
  if diff -r "$TMP" "$OUT" >/dev/null; then
    echo "gen-ns-messaging-grpc: up to date"
  else
    echo "gen-ns-messaging-grpc: generated code is stale; run scripts/gen-ns-messaging-grpc.sh" >&2
    exit 1
  fi
else
  rm -rf "$OUT"
  mkdir -p "$OUT"
  cp "$TMP"/*.swift "$OUT"/
  echo "gen-ns-messaging-grpc: wrote $(ls "$OUT" | wc -l | tr -d ' ') files to ${OUT#"$ROOT"/}"
fi
