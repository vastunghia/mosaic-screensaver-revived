#!/bin/bash
# The project's definitive identifiers. This is the only place they live.
#
# WARNING: do not change these lightly. TCC ties the Photos library grant to the
# app's bundle identifier, so changing it means starting over with permissions on
# every machine where the app was already authorised. The same goes for the
# Application Support directory name, which is the path contract between the app
# and the saver (M11, spike 2).

# The product is the screen saver, Mosaic; the app is its companion, which
# prepares the photographs and holds the settings (2026-10-15). The names may
# change, the identifiers below may not.
PRODUCT_NAME="Mosaic"
APP_NAME="Mosaic Companion"
APP_BUNDLE_ID="com.vastunghia.Mosaic"
SAVER_NAME="Mosaic"
SAVER_BUNDLE_ID="com.vastunghia.Mosaic.saver"

# Index directory: the app writes there because it is its own home, the saver
# reads from it read-only. See spikes/02-shared-path/README.md.
SUPPORT_DIR_NAME="Mosaic"

# Team of the development signing identity (the certificate's OU).
TEAM_ID="7PW62W8KVP"

# Unified log subsystem. Inside the saver this is the only diagnostic channel
# available: no stdout, no stderr.
LOG_SUBSYSTEM="com.vastunghia.Mosaic"

# Version, the same for the app and the saver they are built together. The
# marketing version is the VERSION file at the root; the build number is the
# commit count, so it only ever grows.
VERSION="$(tr -d '[:space:]' < "$(dirname "${BASH_SOURCE[0]}")/../VERSION")"
# A release candidate is 1.0-rc1: macOS's own CFBundleShortVersionString takes
# the numbers alone, and MosaicVersion the whole, which the app's updater reads
# (ReleaseVersion).
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[a-z]+[0-9]+)?$ ]]; then
    echo "error: VERSION is \"$VERSION\", not 1.2 or 1.2-rc3" >&2
    exit 1
fi
SHORT_VERSION="${VERSION%%-*}"
BUILD_NUMBER="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-list --count HEAD 2>/dev/null || echo 1)"
