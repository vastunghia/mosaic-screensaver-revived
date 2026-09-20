#!/bin/bash
# Bundle signing, with a stable identity.
#
# Why ad-hoc signing is not enough: `codesign --sign -` produces a signature
# anchored only to the cdhash, which changes on every rebuild. TCC therefore
# treats each build as an application it has never seen, and the Photos library
# grant has to be given again every time (spike 3, § 5). With an Apple
# Development certificate the designated requirement is anchored to the bundle
# identifier and the certificate's CN, neither of which changes between builds.
#
# Usage:
#     source "$(dirname "$0")/../../scripts/sign.sh"
#     sign_bundle "$APP"
#
# For the control experiment — and only for that — ad-hoc can be forced:
#     MOSAIC_CODESIGN_IDENTITY=- ./build.sh

# Returns the identity to use, in this order:
#   1. $MOSAIC_CODESIGN_IDENTITY, if set
#   2. the first "Apple Development:" identity in the keychain
#   3. ad-hoc, with a loud warning
resolve_identity() {
    if [ -n "${MOSAIC_CODESIGN_IDENTITY:-}" ]; then
        echo "$MOSAIC_CODESIGN_IDENTITY"
        return
    fi

    local found
    found="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -1)"

    if [ -n "$found" ]; then
        echo "$found"
    else
        echo "-"
    fi
}

sign_bundle() {
    local bundle="$1"
    local identity
    identity="$(resolve_identity)"

    if [ "$identity" = "-" ]; then
        echo "==> AD-HOC signature for $(basename "$bundle")" >&2
        echo "    WARNING: the cdhash will change on every build and TCC will revoke" >&2
        echo "    the Photos grant. Fine only for deliberate experiments." >&2
    else
        echo "==> signing $(basename "$bundle") with: $identity" >&2
    fi

    codesign --force --sign "$identity" --timestamp=none "$bundle"
}

# Prints who a signed bundle belongs to, so build scripts can show whether they
# got what they asked for.
show_signature() {
    codesign -dv "$1" 2>&1 | grep -E '^(Identifier|Authority|Signature)' || true
}
