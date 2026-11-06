#!/usr/bin/env python3
"""Generate appcast.xml for Sparkle from the DMGs in dist/.

Why not Sparkle's own generate_appcast?
  It rewrites *every* enclosure URL with one --download-url-prefix, so a feed
  covering several releases cannot point each version at its own GitHub release
  tag. This script signs each archive with sign_update and emits one item per
  DMG, with the tag-correct URL.

Layout produced:
  enclosure  https://github.com/<repo>/releases/download/v<version>/<file>.dmg

Only archives whose embedded app already carries SUPublicEDKey are eligible:
an app without the public key cannot verify signatures, so listing it would
publish an update nobody can install.

Usage:
  python3 Tools/make_appcast.py [--dist dist] [-o appcast.xml]
"""

import argparse
import os
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "stevenjx/InfiniCal"
SPARKLE_TOOLS = os.environ.get(
    "SPARKLE_TOOLS", os.path.expanduser("~/.infinical-sparkle-tools"))


def run(*args):
    return subprocess.run([str(a) for a in args], check=True,
                          capture_output=True, text=True).stdout


def dmg_info(path):
    """Mount read-only, read the app's Info.plist, unmount."""
    mount = tempfile.mkdtemp(prefix="appcast-mnt-")
    run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, path)
    try:
        app = os.path.join(mount, "InfiniCal.app", "Contents", "Info.plist")
        with open(app, "rb") as handle:
            info = plistlib.load(handle)
        return {
            "short": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "min_os": info.get("LSMinimumSystemVersion", "12.0"),
            "public_key": info.get("SUPublicEDKey"),
        }
    finally:
        subprocess.run(["hdiutil", "detach", mount], check=False,
                       capture_output=True)


def sign(path):
    """Ask Sparkle's sign_update for the EdDSA signature of this archive."""
    tool = os.path.join(SPARKLE_TOOLS, "sign_update")
    if not os.access(tool, os.X_OK):
        sys.exit("missing " + tool)
    out = run(tool, path)
    sig = re.search(r'sparkle:edSignature="([^"]+)"', out)
    length = re.search(r'length="(\d+)"', out)
    if not sig or not length:
        sys.exit("sign_update gave no signature for " + path)
    return sig.group(1), int(length.group(1))


def version_key(text):
    return tuple(int(p) for p in text.split("."))


def build(dist, output):
    entries, skipped = [], []
    for name in sorted(os.listdir(dist)):
        if not name.lower().endswith(".dmg"):
            continue
        path = os.path.join(dist, name)
        info = dmg_info(path)
        if not info["public_key"]:
            skipped.append((name, "no SUPublicEDKey"))
            continue
        sig, length = sign(path)
        entries.append({
            "path": path, "name": name, "sig": sig, "length": length, **info,
        })

    if not entries:
        sys.exit("no eligible DMG in " + dist)

    # The feed is rebuilt from dist/, so a DMG that was deleted locally drops
    # out of it — and a feed that forgets a version cannot offer it to anyone.
    # Say so loudly instead of silently publishing a shorter feed.
    if os.path.exists(output):
        with open(output, encoding="utf-8") as handle:
            existing = handle.read().count("<item>")
        if existing > len(entries):
            print("WARNING  %s lists %d versions but %s only has %d DMG(s); "
                  "the new feed will drop %d. Restore those DMGs (or merge the "
                  "old items back) before publishing."
                  % (os.path.basename(output), existing, os.path.basename(dist),
                     len(entries), existing - len(entries)), file=sys.stderr)

    entries.sort(key=lambda e: version_key(e["short"]), reverse=True)

    lines = ['<?xml version="1.0" standalone="yes"?>',
             '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">',
             '    <channel>',
             '        <title>InfiniCal</title>',
             '        <link>https://github.com/%s/releases</link>' % REPO,
             '        <description>InfiniCal 更新</description>',
             '        <language>zh-CN</language>']
    for e in entries:
        url = ("https://github.com/%s/releases/download/v%s/%s"
               % (REPO, e["short"], e["name"]))
        lines += ['        <item>',
                  '            <title>%s</title>' % e["short"],
                  '            <sparkle:version>%s</sparkle:version>' % e["build"],
                  '            <sparkle:shortVersionString>%s</sparkle:shortVersionString>' % e["short"],
                  '            <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>' % e["min_os"],
                  '            <enclosure url="%s"' % url,
                  '                       length="%d"' % e["length"],
                  '                       type="application/octet-stream"',
                  '                       sparkle:edSignature="%s"/>' % e["sig"],
                  '        </item>']
    lines += ['    </channel>', '</rss>', '']

    with open(output, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))

    for e in entries:
        print("SIGNED   %-24s build %-4s %s" % (e["name"], e["build"], e["short"]))
    for name, reason in skipped:
        print("SKIPPED  %-24s %s" % (name, reason))
    print("==> wrote", output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", default=os.path.join(ROOT, "dist"))
    parser.add_argument("-o", "--output", default=os.path.join(ROOT, "appcast.xml"))
    args = parser.parse_args()
    build(args.dist, args.output)
