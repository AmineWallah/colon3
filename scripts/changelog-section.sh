#!/usr/bin/env bash
# Prints the CHANGELOG.md section for a version (without its heading), or nothing.
#   scripts/changelog-section.sh 0.4.0
set -euo pipefail
version="${1:?usage: changelog-section.sh X.Y.Z}"
file="$(dirname "$0")/../CHANGELOG.md"
[ -f "$file" ] || exit 0
awk -v v="$version" '
  $0 == "## " v || index($0, "## " v " ") == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$file" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
