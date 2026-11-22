#!/bin/sh
# Notarizes a signed BatteryHub disk image with Apple and staples the ticket to it, so Gatekeeper
# opens it without the "Apple could not verify" warning, even offline.
#
#   mac/notarize.sh BatteryHub-1.2.3-macos.dmg
#
# Credentials (one of):
#   NOTARY_PROFILE=name                  a profile saved with `xcrun notarytool store-credentials`
#   NOTARY_KEY=path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=uuid
#                                        an App Store Connect API key (used in CI)
set -eu

dmg="${1:?usage: mac/notarize.sh <signed .dmg>}"
[ -f "$dmg" ] || { echo "notarize: $dmg not found" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
    set -- --keychain-profile "$NOTARY_PROFILE"
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    set -- --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
else
    echo "notarize: set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER" >&2
    exit 1
fi

# The disk image must carry a Developer ID signature; an ad-hoc build cannot be notarized.
if ! codesign -dvv "$dmg" 2>&1 | grep -q "^Authority=Developer ID Application"; then
    echo "notarize: $dmg is not signed with a Developer ID Application certificate" >&2
    exit 1
fi

echo "Submitting $dmg to Apple's notary service (usually 1-5 minutes)..."
result="$(xcrun notarytool submit "$dmg" "$@" --wait --output-format json)" || true
id="$(printf '%s' "$result" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)"
status="$(printf '%s' "$result" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' | head -1)"
echo "Submission ${id:-?}: ${status:-no status}"

if [ "$status" != "Accepted" ]; then
    echo "Notarization failed. Apple's log:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "$@" >&2 || printf '%s\n' "$result" >&2
    exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
# Gatekeeper's verdict for a downloaded disk image: should be "accepted, source=Notarized Developer ID".
spctl -a -t open --context context:primary-signature -vv "$dmg"
echo "Notarized and stapled: $dmg"
