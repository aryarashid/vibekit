#!/usr/bin/env python3
"""Writes the Sparkle appcast for one release.

The appcast is attached to every GitHub release, and the app reads it from
releases/latest/download/appcast.xml, so it only needs the newest item. Sparkle
compares sparkle:version (CFBundleVersion) to decide what is newer.

  scripts/make-appcast.py --version 1.4.0 --build 42 --url https://.../Vibe-Kit-1.4.0.zip \
      --length 123456 --signature BASE64 --notes build/release-notes.md --output build/appcast.xml
"""
import argparse
import email.utils
import sys
from xml.sax.saxutils import escape, quoteattr


def cdata(text: str) -> str:
    # "]]>" would end the section early; split it across two sections.
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def build(args: argparse.Namespace, notes: str) -> str:
    date = email.utils.formatdate(usegmt=True)
    description = ""
    if notes.strip():
        description = f'\n      <description sparkle:format="markdown">{cdata(notes.strip())}</description>'
    full_notes = ""
    if args.release_page:
        full_notes = f"\n      <sparkle:fullReleaseNotesLink>{escape(args.release_page)}</sparkle:fullReleaseNotesLink>"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{escape(args.title)}</title>
    <link>{escape(args.link)}</link>
    <language>en</language>
    <item>
      <title>{escape(args.title)} {escape(args.version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(args.min_os)}</sparkle:minimumSystemVersion>{description}{full_notes}
      <enclosure url={quoteattr(args.url)} length="{args.length}" type="application/octet-stream" sparkle:edSignature={quoteattr(args.signature)}/>
    </item>
  </channel>
</rss>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, like 1.4.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion, a whole number")
    parser.add_argument("--url", required=True, help="Download URL of the update zip")
    parser.add_argument("--length", required=True, type=int, help="Size of the zip in bytes")
    parser.add_argument("--signature", required=True, help="EdDSA signature from sign_update -p")
    parser.add_argument("--min-os", default="14.0")
    parser.add_argument("--notes", help="Markdown release notes file")
    parser.add_argument("--release-page", help="Web page with the full release history")
    parser.add_argument("--title", default="Vibe Kit")
    parser.add_argument("--link", default="https://github.com/aryarashid/vibekit")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if not args.build.isdigit():
        parser.error("--build must be a whole number, since Sparkle compares it")
    if not args.url.startswith("https://"):
        parser.error("--url must be https")
    if args.length <= 0:
        parser.error("--length must be positive")

    notes = ""
    if args.notes:
        with open(args.notes, encoding="utf-8") as f:
            notes = f.read()
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(build(args, notes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
