#!/bin/bash
# Write the Sparkle appcast — the manifest every installed copy of Ketto
# polls at the SUFeedURL baked into its Info.plist.
#
#   VERSION=1.2.3 TAG=v1.2.3 PREVIOUS_TAG=v1.2.2 \
#   REPO=boat-builder/ketto ASSET_NAME=Ketto-1.2.3.zip \
#   SIGNATURE_ATTRIBUTES='sparkle:edSignature="…" length="…"' \
#   Scripts/make-appcast.sh release-assets/appcast.xml
#
# SIGNATURE_ATTRIBUTES is the output of Sparkle's sign_update verbatim: it
# already reads as the two enclosure attributes Sparkle wants, so it is pasted
# straight into the tag rather than re-parsed.
#
# The feed carries exactly one item, the newest release — same shape as doklin's
# latest.json. Sparkle only ever needs the best available update, and the file is
# republished on each release under the same releases/latest/download/ URL.
#
# The enclosure points at the immutable per-tag asset URL, never at
# releases/latest/download/. A signature covers specific bytes; a URL whose
# contents change out from under it would start failing verification the moment
# the next release lands.
set -euo pipefail

output="${1:-}"
if [ -z "$output" ]; then
    echo "usage: Scripts/make-appcast.sh <output path>" >&2
    exit 2
fi
: "${VERSION:?VERSION is not set}"
: "${TAG:?TAG is not set}"
: "${REPO:?REPO is not set (owner/name)}"
: "${ASSET_NAME:?ASSET_NAME is not set}"
: "${SIGNATURE_ATTRIBUTES:?SIGNATURE_ATTRIBUTES is not set}"
minimum_system_version="${MINIMUM_SYSTEM_VERSION:-14.0}"

case "$SIGNATURE_ATTRIBUTES" in
    *edSignature=*) ;;
    *) echo "SIGNATURE_ATTRIBUTES does not look like sign_update output: $SIGNATURE_ATTRIBUTES" >&2; exit 1 ;;
esac

# Release notes: the commit subjects since the previous tag, as an HTML list.
# They go inside CDATA, so the only sequence that has to be neutralised is the
# CDATA terminator itself.
notes_range="$TAG"
if [ -n "${PREVIOUS_TAG:-}" ] && git rev-parse -q --verify "refs/tags/$PREVIOUS_TAG" >/dev/null 2>&1; then
    notes_range="$PREVIOUS_TAG..$TAG"
fi
subjects="$(git log --no-merges --pretty=format:'%s' "$notes_range" 2>/dev/null || true)"
notes=""
if [ -n "$subjects" ]; then
    notes="$(printf '%s\n' "$subjects" | head -n 20 \
        | sed -e 's/]]>/]]\&gt;/g' -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
              -e 's|^|<li>|' -e 's|$|</li>|' \
        | tr -d '\n')"
fi
if [ -z "$notes" ]; then
    notes="<li>Maintenance release.</li>"
fi

mkdir -p "$(dirname "$output")"
cat > "$output" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ketto</title>
    <link>https://github.com/$REPO/releases/latest/download/appcast.xml</link>
    <description>Updates for Ketto, a macOS screen recorder.</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum_system_version</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <description><![CDATA[<h3>Ketto $VERSION</h3><ul>$notes</ul>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$ASSET_NAME" type="application/octet-stream" $SIGNATURE_ATTRIBUTES />
    </item>
  </channel>
</rss>
XML

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$output"
fi
echo "Wrote $output"
