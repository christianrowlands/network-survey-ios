#!/usr/bin/env bash
# Refreshes the bundled IEEE MAC address registries in
# NetworkSurvey/Screens/Tools/Resources/oui.tsv from
# https://standards-oui.ieee.org: MA-L (oui.csv, 24-bit prefixes), MA-M
# (mam.csv, 28-bit) and MA-S (oui36.csv, 36-bit), the same registries the
# NS Tower Service serves to the Android app.
# The CSVs are reduced to one "PREFIX<TAB>Organization" line per assignment,
# sorted, so the app can look up a manufacturer without a network request.
#
# Usage: scripts/update-oui.sh [--from <dir>]
#   --from <dir>  read the CSVs from a local directory (for example the tower
#                 service's oui/data) and download only the missing ones.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/NetworkSurvey/Screens/Tools/Resources/oui.tsv"
BASE="https://standards-oui.ieee.org"
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
for entry in oui/oui.csv oui28/mam.csv oui36/oui36.csv; do
  name="$(basename "$entry")"
  if [ -n "$FROM" ] && [ -f "$FROM/$name" ]; then
    cp "$FROM/$name" "$WORK/$name"
  else
    # IEEE refuses requests without a browser-like user agent.
    curl -sfL -A "Mozilla/5.0" -o "$WORK/$name" "$BASE/$entry"
  fi
done

/usr/bin/env python3 -I - "$WORK" "$WORK/oui.tsv" <<'PY'
import csv, re, sys

work, out = sys.argv[1], sys.argv[2]
expected = {"oui.csv": ("MA-L", 6), "mam.csv": ("MA-M", 7), "oui36.csv": ("MA-S", 9)}
rows = {}
for name, (registry, width) in expected.items():
    with open(f"{work}/{name}", newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader)
        if header[:3] != ["Registry", "Assignment", "Organization Name"]:
            sys.exit(f"{name}: unexpected header {header}")
        count = 0
        for row in reader:
            if len(row) < 3 or row[0] != registry:
                continue
            prefix = row[1].strip().upper()
            # The repository's text check bans em dashes; a hyphen reads the same.
            org = re.sub(r"\s+", " ", row[2].replace("\u2014", "-")).strip()
            if len(prefix) != width or not re.fullmatch(r"[0-9A-F]+", prefix) or not org:
                continue
            rows[prefix] = org
            count += 1
        if count < 1000:
            sys.exit(f"{name}: only {count} assignments, refusing to write")
with open(out, "w", encoding="utf-8", newline="\n") as f:
    for prefix in sorted(rows):
        f.write(f"{prefix}\t{rows[prefix]}\n")
PY

mkdir -p "$(dirname "$DEST")"
cp "$WORK/oui.tsv" "$DEST"
echo "MA-L: $(grep -cE '^[0-9A-F]{6}	' "$DEST")," \
  "MA-M: $(grep -cE '^[0-9A-F]{7}	' "$DEST")," \
  "MA-S: $(grep -cE '^[0-9A-F]{9}	' "$DEST")"
