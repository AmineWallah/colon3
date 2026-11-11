#!/usr/bin/env python3
"""Builds an AltStore / SideStore source for colon3's GitHub releases.

Users add https://<user>.github.io/colon3/altstore.json in AltStore or SideStore (Sources › +)
and get every stable release, with updates showing up in the store. CI regenerates it on every
Pages deploy, from the releases list:

    gh api "repos/OWNER/REPO/releases?per_page=100" > releases.json
    scripts/make-altstore-source.py --releases releases.json --base-url https://… --out site/altstore.json

--channel beta builds the second source, altstore-beta.json, for people who want pre-releases:
it lists pre-releases and stable releases together, newest first, so the newest build of
either kind is the one the store offers. Betas of one version all carry that version's number
(1.4.0 beta 1 and beta 5 are both "1.4.0", told apart by build number), so only the newest
build of each version is listed.

Each release's unsigned IPA is read for its exact version, build number and usage
descriptions: AltStore refuses an install when the source's version or permissions don't match
the IPA. Downloads count towards the release's download number, so releases already in the
previous source (--previous, the live altstore.json) are reused instead of downloaded again:
CI downloads each release once.
"""

import argparse
import json
import os
import plistlib
import re
import sys
import tempfile
import urllib.request
import zipfile

ASSET = re.compile(r"^colon3-.+-unsigned\.ipa$")
MAX_VERSIONS = 5


def read_ipa(path):
    """The app's Info.plist plus the usage descriptions of the app and its extensions."""
    app_info = None
    privacy = {}
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            parts = name.split("/")
            if parts[-1] != "Info.plist" or parts[0] != "Payload" or not parts[1].endswith(".app"):
                continue
            is_app = len(parts) == 3
            is_extension = len(parts) == 5 and parts[2] == "PlugIns" and parts[3].endswith(".appex")
            if not (is_app or is_extension):
                continue
            info = plistlib.loads(archive.read(name))
            if is_app:
                app_info = info
            for key, value in info.items():
                if key.endswith("UsageDescription") and isinstance(value, str):
                    privacy.setdefault(key, value)
    if app_info is None:
        raise ValueError(f"no Payload/*.app/Info.plist in {path}")
    return app_info, privacy


def download(url, directory):
    target = os.path.join(directory, url.rsplit("/", 1)[-1])
    if not os.path.exists(target):
        request = urllib.request.Request(url, headers={"User-Agent": "colon3-ci"})
        with urllib.request.urlopen(request, timeout=300) as response, open(target, "wb") as handle:
            while chunk := response.read(1 << 20):
                handle.write(chunk)
    return target


def clean_notes(body):
    """Release notes as AltStore shows them: plain text, no Markdown emphasis or headings."""
    text = (body or "").replace("\r\n", "\n")
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"^#+\s*", "", text, flags=re.MULTILINE)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return text.strip() or "Bug fixes and improvements."


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--releases", required=True, help="JSON from the GitHub releases API")
    parser.add_argument("--base-url", required=True, help="Pages URL the source and icon are served from")
    parser.add_argument("--repo-url", default="https://github.com/AmineWallah/colon3")
    parser.add_argument("--ipa-dir", help="where to keep downloaded IPAs (default: a temp folder)")
    parser.add_argument("--previous", action="append", default=[],
                        help="a current source file, to reuse what it already read from the IPAs "
                             "(repeat for several; the first one that knows a release wins)")
    parser.add_argument("--channel", choices=["stable", "beta"], default="stable",
                        help="stable: releases only; beta: pre-releases too (a separate source)")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    beta = args.channel == "beta"

    with open(args.releases) as handle:
        releases = json.load(handle)
    base = args.base_url.rstrip("/")
    ipa_dir = args.ipa_dir or tempfile.mkdtemp()
    os.makedirs(ipa_dir, exist_ok=True)

    listed = [r for r in releases if not r.get("draft") and (beta or not r.get("prerelease"))]
    listed.sort(key=lambda r: r.get("published_at") or "", reverse=True)

    def notes(release):
        text = clean_notes(release.get("body"))
        # A pre-release's version number doesn't say which beta it is; its title does.
        if release.get("prerelease") and release.get("name"):
            text = f"{release['name']}\n\n{text}"
        return text

    # What the previous sources already read from each IPA, by download URL: the version entry,
    # plus that source's permissions and bundle ID (which describe its newest release).
    known = {}
    for previous in args.previous:
        if not os.path.exists(previous):
            continue
        try:
            with open(previous) as handle:
                previous_app = json.load(handle)["apps"][0]
            previous_privacy = previous_app.get("appPermissions", {}).get("privacy")
            if previous_privacy is None:
                continue
            for index, entry in enumerate(previous_app.get("versions", [])):
                # Only the newest entry's permissions are known for sure.
                known.setdefault(entry["downloadURL"],
                                 (entry, previous_privacy if index == 0 else None,
                                  previous_app.get("bundleIdentifier")))
        except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
            print(f"warning: ignoring the previous source {previous}: {error}", file=sys.stderr)

    versions = []
    privacy = {}
    bundle_id = "com.aminewallah.colon3"
    seen_versions = set()
    for release in listed:
        asset = next((a for a in release.get("assets", []) if ASSET.match(a.get("name", ""))), None)
        if asset is None:
            continue
        reused, reused_privacy, reused_bundle_id = known.get(asset["browser_download_url"], (None, None, None))
        # The newest release sets the source's permissions, so it's only reused from a source
        # where it was the newest too; otherwise its IPA is read again.
        if reused and (versions or reused_privacy is not None):
            if reused["version"] in seen_versions:
                continue
            seen_versions.add(reused["version"])
            if not versions:
                privacy = reused_privacy
                bundle_id = reused_bundle_id or bundle_id
            version = dict(reused)
            # Notes can be edited on GitHub after the fact.
            version["localizedDescription"] = notes(release)
            versions.append(version)
            if len(versions) == MAX_VERSIONS:
                break
            continue
        # An older build of a version that's already listed (an earlier beta): not needed, and
        # not worth a download. The tag says which version it is: v1.4.0-beta.3 is 1.4.0.
        tagged = (release.get("tag_name") or "").lstrip("v").split("-")[0]
        if tagged in seen_versions:
            continue
        try:
            path = download(asset["browser_download_url"], ipa_dir)
            info, release_privacy = read_ipa(path)
        except Exception as error:  # A broken old release shouldn't stop the source.
            print(f"warning: skipping {release.get('tag_name')}: {error}", file=sys.stderr)
            continue
        if info["CFBundleShortVersionString"] in seen_versions:
            continue
        seen_versions.add(info["CFBundleShortVersionString"])
        if not versions:
            # Permissions and identity come from the newest release.
            privacy = release_privacy
            bundle_id = info.get("CFBundleIdentifier", bundle_id)
        version = {
            "version": info["CFBundleShortVersionString"],
            "buildVersion": str(info["CFBundleVersion"]),
            "date": release.get("published_at") or release.get("created_at"),
            "localizedDescription": notes(release),
            "downloadURL": asset["browser_download_url"],
            "size": asset["size"],
        }
        if info.get("MinimumOSVersion"):
            version["minOSVersion"] = info["MinimumOSVersion"]
        versions.append(version)
        if len(versions) == MAX_VERSIONS:
            break

    if not versions:
        sys.exit(f"error: no {args.channel} release with a colon3-*-unsigned.ipa asset")

    latest = versions[0]
    app = {
        "name": "colon3 (Beta)" if beta else "colon3",
        "bundleIdentifier": bundle_id,
        "developerName": "AmineWallah",
        "subtitle": "Soulseek client and music player",
        "localizedDescription": (
            "A native Soulseek client and music player. Search the Soulseek network, download "
            "straight to your phone and play from your own library: Apple Music-style player "
            "with synced lyrics, EQ and bit-perfect output, playlists and imports from Spotify, "
            "Apple Music and YouTube Music, autoplay, Last.fm, Discord, Siri and Google Drive backups."
        ),
        "iconURL": f"{base}/icon.png",
        "tintColor": "FF2D55",
        "category": "entertainment",
        "versions": versions,
        # The IPA is unsigned, so it carries no entitlements; the store signs it with its own.
        "appPermissions": {"entitlements": [], "privacy": privacy},
        # Older SideStore / AltStore versions read these instead of `versions`.
        "version": latest["version"],
        "versionDate": latest["date"],
        "versionDescription": latest["localizedDescription"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
    }
    source = {
        "name": "colon3 Beta" if beta else "colon3",
        "identifier": "com.aminewallah.colon3.source.beta" if beta else "com.aminewallah.colon3.source",
        "subtitle": "Soulseek client and music player for iOS",
        "description": (
            "Pre-releases of colon3 as they come out, and the stable releases too. Betas can be "
            "rough; the stable source is the one without -beta in its address."
            if beta else "Stable releases of colon3, straight from GitHub."
        ),
        "iconURL": f"{base}/icon.png",
        "website": args.repo_url,
        "tintColor": "FF2D55",
        "apps": [app],
        "news": [],
    }
    with open(args.out, "w") as handle:
        json.dump(source, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"AltStore source ({args.channel}): {len(versions)} version(s), latest {latest['version']} ({latest['buildVersion']})")


if __name__ == "__main__":
    main()
