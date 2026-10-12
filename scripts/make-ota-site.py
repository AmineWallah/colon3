#!/usr/bin/env python3
"""Build a folder that installs a signed IPA over the air from Safari.

The output folder holds the IPA, a manifest.plist and an index.html with an
itms-services:// install link. Serve it over HTTPS at --base-url (iOS refuses
plain HTTP for installs). CI uses it for GitHub Pages; locally it works with a
Cloudflare tunnel:

    python3 scripts/make-ota-site.py colon3-signed.ipa \
        --base-url https://something.trycloudflare.com --out ~/colon3-dist
    cd ~/colon3-dist && python3 -m http.server 8000

Only the files written here end up in the output folder, so nothing else on
disk is served.
"""

import argparse
import datetime
import html
import plistlib
import shutil
import sys
import zipfile
from pathlib import Path


def read_info_plist(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as archive:
        for name in archive.namelist():
            parts = name.split("/")
            # Payload/<App>.app/Info.plist, not plists nested deeper in the bundle
            if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") and parts[2] == "Info.plist":
                return plistlib.loads(archive.read(name))
    sys.exit(f"error: no Payload/*.app/Info.plist inside {ipa}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa", type=Path, help="signed .ipa")
    parser.add_argument("--base-url", required=True, help="HTTPS URL the output folder will be served from")
    parser.add_argument("--out", type=Path, required=True, help="output folder (created; existing files are replaced)")
    parser.add_argument("--commit", default="", help="commit hash to show on the page")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    if not base_url.startswith("https://"):
        sys.exit("error: --base-url must be https:// (iOS won't install over plain HTTP)")
    if not args.ipa.is_file():
        sys.exit(f"error: {args.ipa} not found")

    info = read_info_plist(args.ipa)
    bundle_id = info["CFBundleIdentifier"]
    name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or "App"
    version = info.get("CFBundleShortVersionString", "0")
    build = info.get("CFBundleVersion", "0")

    args.out.mkdir(parents=True, exist_ok=True)
    ipa_name = f"{name}.ipa"
    shutil.copyfile(args.ipa, args.out / ipa_name)

    manifest = {
        "items": [{
            "assets": [{"kind": "software-package", "url": f"{base_url}/{ipa_name}"}],
            "metadata": {
                "bundle-identifier": bundle_id,
                "bundle-version": version,
                "kind": "software",
                "title": name,
            },
        }]
    }
    with open(args.out / "manifest.plist", "wb") as handle:
        plistlib.dump(manifest, handle)

    install_url = f"itms-services://?action=download-manifest&url={base_url}/manifest.plist"
    built = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    commit = html.escape(args.commit[:7])
    size_mb = args.ipa.stat().st_size / 1_000_000

    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Install {html.escape(name)}</title>
<style>
  :root {{ color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --accent: #0a84ff; }}
  @media (prefers-color-scheme: dark) {{ :root {{ --bg: #000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; }} }}
  body {{ margin: 0; background: var(--bg); color: var(--text); font: 17px/1.45 -apple-system, system-ui, sans-serif; }}
  main {{ max-width: 460px; margin: 0 auto; padding: 48px 16px; }}
  .card {{ background: var(--card); border-radius: 18px; padding: 28px 22px; }}
  h1 {{ margin: 0 0 4px; font-size: 32px; }}
  .meta {{ color: var(--muted); font-size: 15px; margin: 0 0 24px; }}
  .install {{ display: block; text-align: center; background: var(--accent); color: #fff; text-decoration: none;
              font-weight: 600; padding: 15px; border-radius: 14px; }}
  ol {{ color: var(--muted); font-size: 15px; padding-left: 20px; margin: 22px 0 0; }}
  code {{ font-size: 13px; }}
</style>
</head>
<body>
<main>
  <div class="card">
    <h1>{html.escape(name)}</h1>
    <p class="meta">Version {html.escape(version)} (build {html.escape(build)}) · {size_mb:.1f} MB<br>
    Built {built}{f" · <code>{commit}</code>" if commit else ""}</p>
    <a class="install" href="{html.escape(install_url)}">Install</a>
    <ol>
      <li>Open this page in Safari; other browsers can't install apps.</li>
      <li>Tap Install, confirm, then watch the home screen.</li>
      <li>First install only: Settings › General › VPN &amp; Device Management › trust the developer.</li>
    </ol>
  </div>
</main>
</body>
</html>
"""
    (args.out / "index.html").write_text(page, encoding="utf-8")
    print(f"{name} {version} ({build}), bundle {bundle_id}")
    print(f"Wrote {args.out}/{{index.html,manifest.plist,{ipa_name}}}")
    print(f"Open {base_url}/ in Safari on the phone")


if __name__ == "__main__":
    main()
