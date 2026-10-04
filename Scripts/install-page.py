#!/usr/bin/env python3
"""Builds the iPhone and iPad install page (GitHub Pages) for a release.

Usage: Scripts/install-page.py RELEASE.ipa TAG RELEASE_URL BASE_URL SITE_DIR

Writes SITE_DIR/index.html (from Packaging/ios/index.html), manifest.plist (the
file iOS installs from, and the app checks for updates), the IPA, and the icons.
BASE_URL is where SITE_DIR is served, e.g. https://parasetam0l.github.io/local-desktop.
"""

import html
import plistlib
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "iOS/Assets.xcassets/AppIcon.appiconset"


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


def main():
    if len(sys.argv) != 6:
        fail(__doc__.strip().splitlines()[2])
    ipa, tag, release_url, base_url, site = sys.argv[1:]
    ipa, site, base_url = Path(ipa), Path(site), base_url.rstrip("/")

    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            fail(f"{ipa.name} doesn't contain one app.")
        info = plistlib.loads(archive.read(names[0]))
    version = info["CFBundleShortVersionString"]
    if tag != f"v{version}":
        fail(f"{ipa.name} is version {version}, but the release is {tag}.")

    site.mkdir(parents=True, exist_ok=True)
    shutil.copy(ipa, site / ipa.name)
    shutil.copy(ICONS / "icon_60x60@3x.png", site / "icon.png")
    shutil.copy(ICONS / "icon_1024x1024.png", site / "icon-1024.png")

    manifest = {
        "items": [{
            "assets": [
                {"kind": "software-package", "url": f"{base_url}/{ipa.name}"},
                {"kind": "display-image", "url": f"{base_url}/icon.png"},
                {"kind": "full-size-image", "url": f"{base_url}/icon-1024.png"},
            ],
            "metadata": {
                "bundle-identifier": info["CFBundleIdentifier"],
                "bundle-version": version,
                "kind": "software",
                "title": info.get("CFBundleDisplayName", "LocalDesktop"),
            },
        }],
    }
    manifest_url = f"{base_url}/manifest.plist"
    with open(site / "manifest.plist", "wb") as file:
        plistlib.dump(manifest, file)

    # The app checks this URL for updates; it's fixed in project.yml.
    expected = re.search(r"^\s*LDUpdateManifestURL:\s*(\S+)", (ROOT / "project.yml").read_text(), re.M)
    if not expected or expected.group(1) != manifest_url:
        print(f"::warning::The app checks {expected and expected.group(1)} for updates, "
              f"but the manifest is published at {manifest_url}. Update LDUpdateManifestURL in project.yml.")

    page = (ROOT / "Packaging/ios/index.html").read_text()
    for key, value in {
        "INSTALL_URL": f"itms-services://?action=download-manifest&url={manifest_url}",
        "VERSION": version,
        "RELEASE_URL": release_url,
    }.items():
        page = page.replace("{{" + key + "}}", html.escape(value))
    (site / "index.html").write_text(page)
    print(f"Install page for LocalDesktop {version}: {base_url}/")


if __name__ == "__main__":
    main()
