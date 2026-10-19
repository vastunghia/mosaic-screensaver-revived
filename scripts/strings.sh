#!/bin/bash
# String Catalogs, compiled without an Xcode project.
#
# Each bundle has its catalogs next to its sources (Hosts/App, Hosts/Saver),
# and xcstringstool turns them into the <language>.lproj folders of the bundle.
# SwiftPM's own resource handling is not used: it would put the strings in a
# bundle of their own, and every Text would need `bundle: .module`.
#
# Usage:
#     source scripts/strings.sh
#     compile_strings Hosts/App/Localizable.xcstrings "$APP/Contents/Resources"
#     DESCRIPTION="$(info_plist_string Hosts/App/InfoPlist.xcstrings NSPhotoLibraryUsageDescription)"

# Compiles one catalog into <resources>/<language>.lproj/<table>.strings(dict).
# xcstringstool writes only the languages that have values, and English has
# none when every key is its own English text: en.lproj is made anyway, so that
# the development language is always a folder to look strings up in.
compile_strings() {
    local catalog="$1" resources="$2"
    mkdir -p "$resources/en.lproj"
    local languages
    languages="$(xcrun xcstringstool compile "$catalog" --output-directory "$resources" --dry-run \
        | sed -n 's|.*/\([^/]*\)\.lproj/.*|\1|p' | sort -u | tr '\n' ' ')"
    xcrun xcstringstool compile "$catalog" --output-directory "$resources"
    languages="${languages% }"
    echo "    $(basename "$catalog"): ${languages:-English keys only}"
}

# The English value of an Info.plist key, from InfoPlist.xcstrings, escaped for
# a plist: the catalog is the only place the text lives, and the build writes
# it into Info.plist as the fallback every language without a translation sees.
info_plist_string() {
    local catalog="$1" key="$2"
    plutil -extract "strings.$key.localizations.en.stringUnit.value" raw -o - "$catalog" \
        | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}
