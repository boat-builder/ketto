#!/bin/bash
# One-time setup for in-app updates: create the EdDSA key pair Sparkle uses to prove an
# update really came from you.
#
#   ./Scripts/generate-sparkle-keys.sh
#
# macOS only — generate_keys stores the private key in your login Keychain.
#
# What comes out:
#   * a PUBLIC key, which goes into Recordito/Info.plist under SUPublicEDKey and is
#     committed. Every installed copy verifies downloads against it.
#   * a PRIVATE key, exported to a file so it can be pasted into the repository secret
#     SPARKLE_PRIVATE_KEY, which is what the release workflow signs each update with.
#
# Run this ONCE for the project. Regenerating the key later orphans every copy already in
# the wild: they would keep verifying against the old public key and refuse every update
# built with the new private one, leaving their only way forward a manual re-download.
# Keep the Keychain entry — and a backup of the exported file somewhere safe.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script needs macOS: Sparkle's generate_keys stores the private key in the login Keychain." >&2
    exit 1
fi

resolved="Recordito.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
sparkle_version="$(/usr/bin/python3 -c 'import json,sys; print(next((p["state"]["version"] for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "sparkle"), ""))' "$resolved")"
if [ -z "$sparkle_version" ]; then
    echo "Could not read the pinned Sparkle version out of $resolved" >&2
    exit 1
fi

# The same tools the release workflow signs with, and the same version the app links
# against, so a key generated here is definitely one sign_update can use.
tools="$(mktemp -d)"
trap 'rm -rf "$tools"' EXIT
echo "Fetching the Sparkle $sparkle_version tools…"
curl -fsSL -o "$tools/sparkle.zip" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-for-Swift-Package-Manager.zip"
unzip -q -o "$tools/sparkle.zip" -d "$tools/sparkle"

echo
"$tools/sparkle/bin/generate_keys"

public_key="$("$tools/sparkle/bin/generate_keys" -p)"

private_key_file="$PWD/sparkle_private_key.txt"
"$tools/sparkle/bin/generate_keys" -x "$private_key_file" >/dev/null
chmod 600 "$private_key_file"

cat <<EOF

────────────────────────────────────────────────────────────────────────────
Two things to do with this, and then you are done forever.

1. Commit the public key. In Recordito/Info.plist, replace the SUPublicEDKey
   placeholder with:

       $public_key

2. Add the private key as a repository secret named SPARKLE_PRIVATE_KEY:

       gh secret set SPARKLE_PRIVATE_KEY < "$private_key_file"

   …or paste the contents at
   https://github.com/boat-builder/recordito/settings/secrets/actions

Then delete the exported copy — the Keychain still has it:

       rm "$private_key_file"

The exported file is ignored by git (see .gitignore), but it is still a private
key sitting in the working tree. Do not leave it there.
────────────────────────────────────────────────────────────────────────────
EOF
