#!/bin/bash
# Brings the String Catalogs in line with the code: keys the code uses are
# added, keys it no longer uses are marked stale. Run it after changing what
# the interface says, and commit the catalogs it changes.
#
#     ./scripts/strings-sync.sh            # updates the catalogs
#     ./scripts/strings-sync.sh --check    # changes nothing; fails if they are behind
#
# The compiler lists the strings of each source file in a .stringsdata file as
# it compiles it, from String(localized:), LocalizedStringResource and SwiftUI's
# literals (not from NSLocalizedString). That takes a real build, kept apart
# in .build/strings so that the flags do not rebuild the main one.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
for argument in "$@"; do
    case "$argument" in
        --check) CHECK=1 ;;
        *) echo "usage: $0 [--check]" >&2; exit 2 ;;
    esac
done

# Which sources feed which catalog. A string anywhere else is an error: no
# catalog would carry its translations.
APP_CATALOG="Hosts/App/Localizable.xcstrings"
SAVER_CATALOG="Hosts/Saver/Localizable.xcstrings"
catalog_for() {
    case "$1" in
        Hosts/App/*|Sources/AppUpdate/*) echo "$APP_CATALOG" ;;
        Hosts/Saver/*) echo "$SAVER_CATALOG" ;;
        *) echo "" ;;
    esac
}

# A .stringsdata file is named after its source file alone: two sources with
# the same name would overwrite each other's.
DUPLICATES="$(find Sources Hosts -name '*.swift' -exec basename {} \; | sort | uniq -d)"
if [ -n "$DUPLICATES" ]; then
    echo "error: source files share a name, and their strings would be lost: $DUPLICATES" >&2
    exit 1
fi

# The build is incremental and re-emits the strings of the modules it
# recompiles only, so the folder of .stringsdata lives beside it; without the
# folder, the build starts from scratch.
SCRATCH=".build/strings"
STRINGSDATA="$SCRATCH/stringsdata"
if [ ! -d "$STRINGSDATA" ]; then
    rm -rf "$SCRATCH"
    mkdir -p "$STRINGSDATA"
fi

echo "==> swift build, extracting strings"
LOG="$SCRATCH/build.log"
build() {
    swift build -c release --scratch-path "$SCRATCH" \
        -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$STRINGSDATA" \
        > "$LOG" 2>&1
}
# Twice, when the first fails: building from scratch, the compiler crashed twice
# loading a clang module (signal 6, 2026-10-19), and went on the next time.
if ! build; then
    echo "    the build failed; trying once more"
    if ! build; then
        tail -20 "$LOG" >&2
        echo "error: the build failed; the whole log is in $LOG" >&2
        exit 1
    fi
fi

# The .stringsdata of each catalog, from sources that still exist.
APP_FILES=()
SAVER_FILES=()
STRAYS=()
for data in "$STRINGSDATA"/*.stringsdata; do
    source="$(plutil -extract source raw -o - "$data")"
    source="${source#"$PWD/"}"
    [ -f "$source" ] || continue
    count="$(plutil -extract tables json -o - "$data" | { grep -o '"key"' || true; } | wc -l | tr -d ' ')"
    case "$(catalog_for "$source")" in
        "$APP_CATALOG") APP_FILES+=("$data") ;;
        "$SAVER_CATALOG") SAVER_FILES+=("$data") ;;
        *) [ "$count" = 0 ] || STRAYS+=("$source ($count)") ;;
    esac
done
if [ ${#STRAYS[@]} -gt 0 ]; then
    echo "error: localized strings outside the app and the screen saver, which no catalog carries:" >&2
    printf '    %s\n' "${STRAYS[@]}" >&2
    exit 1
fi

sync_catalog() {
    local catalog="$1"
    shift
    xcrun xcstringstool sync "$catalog" --stringsdata "$@"
}

if [ "$CHECK" = 1 ]; then
    TEMP="$(mktemp -d)"
    trap 'rm -rf "$TEMP"' EXIT
    BEHIND=0
    for catalog in "$APP_CATALOG" "$SAVER_CATALOG"; do
        # Same file name: sync takes the table's name from it.
        copy="$TEMP/$(dirname "$catalog")/$(basename "$catalog")"
        mkdir -p "$(dirname "$copy")"
        cp "$catalog" "$copy"
        if [ "$catalog" = "$APP_CATALOG" ]; then
            sync_catalog "$copy" "${APP_FILES[@]}"
        else
            sync_catalog "$copy" "${SAVER_FILES[@]}"
        fi
        if ! cmp -s "$catalog" "$copy"; then
            echo "$catalog is behind the code" >&2
            BEHIND=1
        fi
    done
    if [ "$BEHIND" = 1 ]; then
        echo "error: run ./scripts/strings-sync.sh and commit the catalogs" >&2
        exit 1
    fi
    echo "==> the catalogs are in line with the code"
    exit 0
fi

echo "==> sync"
sync_catalog "$APP_CATALOG" "${APP_FILES[@]}"
sync_catalog "$SAVER_CATALOG" "${SAVER_FILES[@]}"
for catalog in "$APP_CATALOG" "$SAVER_CATALOG"; do
    keys="$(xcrun xcstringstool print "$catalog" | grep -c . || true)"
    echo "    $catalog: $keys keys"
done
git status --short -- "$APP_CATALOG" "$SAVER_CATALOG"
