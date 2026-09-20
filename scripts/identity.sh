#!/bin/bash
# The project's definitive identifiers. This is the only place they live.
#
# WARNING: do not change these lightly. TCC ties the Photos library grant to the
# app's bundle identifier, so changing it means starting over with permissions on
# every machine where the app was already authorised. The same goes for the
# Application Support directory name, which is the path contract between the app
# and the saver (M11, spike 2).

APP_NAME="Mosaic"
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
