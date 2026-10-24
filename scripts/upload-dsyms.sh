#!/usr/bin/env bash
# Xcode build phase of the app target: uploads the dSYMs of a Release build to
# Sentry, so crash reports show function names and lines. Does nothing unless
# sentry-cli is installed and SENTRY_ORG and SENTRY_PROJECT are set in
# Config/Local.xcconfig, so builds from source and CI never upload. sentry-cli
# authenticates with SENTRY_AUTH_TOKEN or the token `sentry-cli login` saved.
# A failed upload is a warning, not a build failure.
set -uo pipefail

[ "${CONFIGURATION:-}" = "Release" ] || exit 0
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
if ! command -v sentry-cli >/dev/null || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
  echo "Sentry dSYM upload skipped: needs sentry-cli, SENTRY_ORG and SENTRY_PROJECT"
  exit 0
fi
if ! sentry-cli debug-files upload "$DWARF_DSYM_FOLDER_PATH"; then
  echo "warning: uploading dSYMs to Sentry failed, so crash reports from this build may not be symbolicated"
fi
