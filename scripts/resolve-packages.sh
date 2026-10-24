#!/usr/bin/env bash
# Resolves the app's Swift packages into a directory, for CI. On a fresh runner
# xcodebuild sometimes starts two resolutions at once, and they race in the
# shared SwiftPM repository cache ("cannot change to
# .../org.swift.swiftpm/repositories/..."). This resolves once, without that
# cache, and retries. Later xcodebuild calls pass the same directory as
# -clonedSourcePackagesDirPath together with -disableAutomaticPackageResolution,
# so they never resolve again.
#
# Usage: scripts/resolve-packages.sh <directory>
# Run after xcodegen generate.
set -uo pipefail

dir="${1:?usage: scripts/resolve-packages.sh <directory>}"
cd "$(dirname "$0")/.." || exit 2

for attempt in 1 2 3; do
    if xcodebuild -resolvePackageDependencies \
        -project NetworkSurvey.xcodeproj \
        -scheme NetworkSurvey \
        -clonedSourcePackagesDirPath "$dir" \
        -disablePackageRepositoryCache; then
        exit 0
    fi
    echo "resolve-packages: attempt $attempt failed" >&2
    rm -rf "$dir"
done
exit 1
