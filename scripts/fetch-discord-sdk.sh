#!/usr/bin/env bash
# Puts Discord's Social SDK (discord_partner_sdk.xcframework) in Vendor/ for CI.
#
# The SDK can't be in this public repository, so it's kept as a release asset in a private
# repository: DISCORD_SDK_REPO (owner/name, a repository variable) read with DISCORD_SDK_TOKEN
# (a secret: a fine-grained token with read access to that repository's contents). The asset is
# the zip downloaded from the Discord Developer Portal. Exits 0 without doing anything when
# either is missing, so forks and pull requests still build (without Discord).
set -euo pipefail

if [ -z "${DISCORD_SDK_REPO:-}" ] || [ -z "${DISCORD_SDK_TOKEN:-}" ]; then
  echo "Discord SDK: DISCORD_SDK_REPO or DISCORD_SDK_TOKEN not set, building without Discord."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The newest release's first .zip asset (or DISCORD_SDK_TAG, if set).
GH_TOKEN="$DISCORD_SDK_TOKEN" gh release download ${DISCORD_SDK_TAG:+"$DISCORD_SDK_TAG"} \
  --repo "$DISCORD_SDK_REPO" --pattern '*.zip' --dir "$work"
zip="$(find "$work" -maxdepth 1 -name '*.zip' | head -1)"
if [ -z "$zip" ]; then
  echo "::error::No .zip asset in the latest release of $DISCORD_SDK_REPO"
  exit 1
fi
unzip -q "$zip" -d "$work/sdk"

framework="$(find "$work/sdk" -type d -name 'discord_partner_sdk.xcframework' | head -1)"
if [ -z "$framework" ]; then
  echo "::error::discord_partner_sdk.xcframework isn't in $(basename "$zip"). Contents:"
  find "$work/sdk" -maxdepth 4 | head -50
  exit 1
fi

rm -rf Vendor/discord_partner_sdk.xcframework
mkdir -p Vendor
cp -R "$framework" Vendor/
echo "Discord SDK: $(basename "$zip") → Vendor/discord_partner_sdk.xcframework"
