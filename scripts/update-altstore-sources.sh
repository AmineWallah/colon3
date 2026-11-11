#!/usr/bin/env bash
# Rebuilds both AltStore / SideStore sources into a Pages site folder: altstore.json (stable
# releases) and altstore-beta.json (pre-releases too). See scripts/make-altstore-source.py.
#
#   scripts/update-altstore-sources.sh <pages base URL> <site folder>
#
# Needs gh (GH_TOKEN) and GITHUB_REPOSITORY. Each source starts from its live copy, so a failed
# update keeps the old one instead of none, and so releases a source already lists aren't
# downloaded again (that would add to the releases' download counters on every deploy). The
# beta source also reuses what the stable one, built just before it, knows.
set -u

base="${1%/}"
site="$2"
work="${RUNNER_TEMP:-$(mktemp -d)}"

gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" > "$work/releases.json" || true

for channel in stable beta; do
  name=altstore.json
  if [ "$channel" = beta ]; then name=altstore-beta.json; fi
  curl -fsSL "$base/$name" -o "$site/$name" || rm -f "$site/$name"
  if python3 scripts/make-altstore-source.py --channel "$channel" \
      --releases "$work/releases.json" --base-url "$base" --ipa-dir "$work/ipas" \
      --previous "$site/$name" --previous "$site/altstore.json" --out "$work/$name"; then
    cp "$work/$name" "$site/$name"
  else
    echo "::warning::$name not updated; keeping the previous one."
  fi
done
exit 0
