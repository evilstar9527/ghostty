"""
Generate a Sparkle appcast for Ghostty++ GitHub releases.

Expected files in the current directory:
    - sign_update.txt: output from Sparkle's sign_update for the DMG

Required environment variables:
    - GHOSTTY_VERSION: version number in X.Y.Z format
    - GHOSTTY_BUILD: monotonically increasing build number
    - GHOSTTY_COMMIT: short commit hash
    - GHOSTTY_COMMIT_LONG: full commit hash
    - GITHUB_REPOSITORY: owner/repo

Optional environment variables:
    - GHOSTTY_RELEASE_TAG: defaults to ghostty-plus-plus-v${GHOSTTY_VERSION}
    - GHOSTTY_DMG_NAME: defaults to Ghostty++-v${GHOSTTY_VERSION}.dmg
"""

import os
import shlex
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import quote

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


def parse_sign_update(path):
    with open(path, "r", encoding="utf-8") as f:
        parts = shlex.split(f.read().strip())

    attrs = {}
    for part in parts:
        key, value = part.split("=", 1)
        attrs[key] = value
    return attrs


def sparkle(name):
    return f"{{{SPARKLE_NS}}}{name}"


now = datetime.now(timezone.utc)
version = env("GHOSTTY_VERSION")
build = env("GHOSTTY_BUILD")
commit = env("GHOSTTY_COMMIT")
commit_long = env("GHOSTTY_COMMIT_LONG")
repo = env("GITHUB_REPOSITORY")
tag = os.environ.get("GHOSTTY_RELEASE_TAG", f"ghostty-plus-plus-v{version}")
dmg_name = os.environ.get("GHOSTTY_DMG_NAME", f"Ghostty++-v{version}.dmg")

release_url = f"https://github.com/{repo}/releases/tag/{tag}"
dmg_url = f"https://github.com/{repo}/releases/download/{tag}/{quote(dmg_name)}"

ET.register_namespace("sparkle", SPARKLE_NS)

rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Ghostty++ Updates"
ET.SubElement(channel, "link").text = f"https://github.com/{repo}/releases"
ET.SubElement(channel, "description").text = "Ghostty++ release updates"
ET.SubElement(channel, "language").text = "en"

item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Ghostty++ v{version}"
ET.SubElement(item, sparkle("releaseNotesLink")).text = release_url
ET.SubElement(item, sparkle("fullReleaseNotesLink")).text = release_url
ET.SubElement(item, "pubDate").text = now.strftime("%a, %d %b %Y %H:%M:%S %z")
ET.SubElement(item, "description").text = f"""
<h1>Ghostty++ v{version}</h1>
<p>
This release was built from commit <code><a href="https://github.com/{repo}/commit/{commit_long}">{commit}</a></code>
on {now.strftime('%Y-%m-%d')}.
</p>
<p>
You can view release notes and download files from the
<a href="{release_url}">GitHub release page</a>.
</p>
"""

enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", dmg_url)
enclosure.set(sparkle("version"), build)
enclosure.set(sparkle("shortVersionString"), version)
enclosure.set("type", "application/octet-stream")
for key, value in parse_sign_update("sign_update.txt").items():
    if key == "sparkle:edSignature":
        enclosure.set(sparkle("edSignature"), value)
    else:
        enclosure.set(key, value)

ET.SubElement(item, sparkle("minimumSystemVersion")).text = "13.0"

tree = ET.ElementTree(rss)
tree.write("appcast.xml", xml_declaration=True, encoding="utf-8")
