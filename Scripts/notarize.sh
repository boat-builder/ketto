#!/bin/bash
# Submit one artifact to Apple's notary service, wait for the verdict, and fail
# loudly with the reason when it is not "Accepted".
#
#   Scripts/notarize.sh path/to/Recordito.zip
#   Scripts/notarize.sh path/to/Recordito-1.2.3.dmg
#
# Needs APPLE_ID, APPLE_PASSWORD (an app-specific password) and APPLE_TEAM_ID in
# the environment — the same three the release workflow passes. A bare
# `notarytool submit --wait` prints "Invalid" and nothing else; the whole point
# of this wrapper is to pull the submission log out, which is the only place
# Apple says *which* nested binary was unsigned or which entitlement it objected
# to.
#
# Only .zip, .dmg and .pkg can be submitted — an .app has to be zipped first
# (ditto -c -k --keepParent), and the ticket is then stapled onto the .app, not
# onto the zip.
set -euo pipefail

artifact="${1:-}"
if [ -z "$artifact" ] || [ ! -e "$artifact" ]; then
    echo "usage: Scripts/notarize.sh <path to .zip, .dmg or .pkg>" >&2
    exit 2
fi
: "${APPLE_ID:?APPLE_ID is not set}"
: "${APPLE_PASSWORD:?APPLE_PASSWORD is not set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}"

echo "Notarizing $artifact …"
result="$(xcrun notarytool submit "$artifact" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait \
    --output-format json)"
echo "$result"

status="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
submission="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"

if [ "$status" != "Accepted" ]; then
    echo "::error::notarization returned '$status' for $artifact"
    if [ -n "$submission" ]; then
        echo "--- notarization log ---"
        xcrun notarytool log "$submission" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" || true
    fi
    exit 1
fi

echo "Notarization accepted ($submission)"
