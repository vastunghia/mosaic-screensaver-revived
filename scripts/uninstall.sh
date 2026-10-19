#!/bin/bash
# Removes every trace of Mosaic and Mosaic Companion from this Mac, for the user
# who runs it: the app and the screen saver, the copies of the photographs, the
# preferences, caches and logs, the login item, the Photos permission, the
# notification settings and the help index. Photographs and the Photos library
# are never touched.
#
# Usage:
#     ./scripts/uninstall.sh              lists what it found, asks, then removes
#     ./scripts/uninstall.sh --dry-run    only lists
#     ./scripts/uninstall.sh --yes        removes without asking
#
# Everything under ~/Library belongs to one profile: on a Mac with several, run
# it in each. The app in /Applications is shared, and goes the first time; a
# standard account is asked for an administrator.
#
# It stands alone, so it can be carried to another Mac: the identifiers below
# are copied from scripts/identity.sh, which stays the place they are decided.
set -u

APP_NAME="Mosaic Companion"
APP_BUNDLE_ID="com.vastunghia.Mosaic"
SAVER_NAME="Mosaic"
SAVER_BUNDLE_ID="com.vastunghia.Mosaic.saver"
SUPPORT_DIR_NAME="Mosaic"
# Before 2026-10-15 the app was Mosaic.app, with the same bundle identifier.
OLD_APP_NAME="Mosaic"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

DRY=0
ASK=1
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY=1 ;;
        --yes) ASK=0 ;;
        *) echo "usage: $0 [--dry-run | --yes]" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" = 0 ]; then
    echo "Run this as the user whose traces should go, not with sudo: it asks for an administrator when it needs one." >&2
    exit 1
fi

TMP_DIR="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
TMP_DIR="${TMP_DIR%/}"
WORK="$(mktemp -d "$TMP_DIR/uninstall.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null
}

# --- What there is ---------------------------------------------------------

# Copies of the app this script removes, and copies elsewhere (a build folder,
# a disk image) that it only names.
APPS=()
OTHER_APPS=()
for app in "/Applications/$APP_NAME.app" "/Applications/$OLD_APP_NAME.app" \
           "$HOME/Applications/$APP_NAME.app" "$HOME/Applications/$OLD_APP_NAME.app"; do
    [ "$(bundle_id "$app")" = "$APP_BUNDLE_ID" ] && APPS+=("$app")
done

# Launch Services keeps a record of every copy it has seen, those on the disk
# images of past releases included, long after they are gone.
ls_copies() {
    "$LSREGISTER" -dump 2>/dev/null | awk -v app="$APP_BUNDLE_ID" -v saver="$SAVER_BUNDLE_ID" '
        /^-+$/ { if (id == app || id == saver) print path; id = ""; path = ""; next }
        /^path:/ && path == "" { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
        /^identifier:/ && id == "" { id = $2 }'
}
gone_copies() {
    local path
    ls_copies | while IFS= read -r path; do
        [ -n "$path" ] && [ ! -e "$path" ] && echo "$path"
    done | sort -u
}

# Spotlight does not index every folder (a build folder, say), but Launch
# Services has seen every copy that was ever opened.
KNOWN_COPIES="$(ls_copies | sort -u)"
GONE_COPIES=0
while IFS= read -r app; do
    [ -n "$app" ] || continue
    if [ ! -e "$app" ]; then GONE_COPIES=$((GONE_COPIES + 1)); continue; fi
    case "$app" in *.app) ;; *) continue ;; esac
    case " ${APPS[*]:-} ${OTHER_APPS[*]:-} " in *" $app "*) continue ;; esac
    [ "$(bundle_id "$app")" = "$APP_BUNDLE_ID" ] && OTHER_APPS+=("$app")
done < <(printf '%s\n' "$KNOWN_COPIES"; mdfind "kMDItemCFBundleIdentifier == '$APP_BUNDLE_ID'" 2>/dev/null)

SAVERS=()
for saver in "$HOME/Library/Screen Savers/$SAVER_NAME.saver" "/Library/Screen Savers/$SAVER_NAME.saver"; do
    [ "$(bundle_id "$saver")" = "$SAVER_BUNDLE_ID" ] && SAVERS+=("$saver")
done

# Files and folders of this profile, kept by the app, the screen saver, the
# updater and the development tools.
FILES=()
add_existing() {
    local path
    for path in "$@"; do
        if [ -e "$path" ] || [ -L "$path" ]; then FILES+=("$path"); fi
    done
}
add_existing \
    "$HOME/Library/Application Support/$SUPPORT_DIR_NAME" \
    "$HOME/Library/Caches/$APP_BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$APP_BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$APP_BUNDLE_ID.binarycookies" \
    "$HOME/Library/WebKit/$APP_BUNDLE_ID" \
    "$HOME/Library/Saved Application State/$APP_BUNDLE_ID.savedState" \
    "$HOME/Library/Logs/$SUPPORT_DIR_NAME" \
    "$HOME/Library/Caches/mosaic-cull-probe" \
    "$HOME/Library/Preferences/$APP_BUNDLE_ID.plist" \
    "$HOME/Library/Preferences/ByHost/$APP_BUNDLE_ID".*.plist
[ -O /tmp/mosaic-probe ] && add_existing /tmp/mosaic-probe
# Temporary folders: the updater's and the move to /Applications', and those
# the tests leave behind on a Mac that builds Mosaic. Listed as one line.
TEMPS=()
for path in "$TMP_DIR"/Mosaic-* "$TMP_DIR"/mosaic-*; do
    if [ -e "$path" ]; then TEMPS+=("$path"); fi
done
# Crash reports of the app, and of the screen saver's host when Mosaic was in it.
for report in "$HOME/Library/Logs/DiagnosticReports"/*; do
    [ -f "$report" ] || continue
    case "$(basename "$report")" in
        "$APP_NAME"-*|"$OLD_APP_NAME"-*) FILES+=("$report") ;;
        legacyScreenSaver*) grep -q "$APP_BUNDLE_ID" "$report" 2>/dev/null && FILES+=("$report") ;;
    esac
done

# The updater mounts the new release under a temporary folder.
MOUNTS=()
while IFS= read -r point; do
    [ -n "$point" ] && MOUNTS+=("$point")
done < <(mount | sed -n 's|^.* on \(.*/Mosaic-update-[^ ]*\) (.*$|\1|p')

HAS_PREFERENCES=0
defaults read "$APP_BUNDLE_ID" >/dev/null 2>&1 && HAS_PREFERENCES=1

NCPREFS="$WORK/ncprefs.plist"
NOTIFICATION_ENTRIES=0
if defaults export com.apple.ncprefs "$NCPREFS" 2>/dev/null; then
    count="$(plutil -extract apps raw -o - "$NCPREFS" 2>/dev/null || echo 0)"
    i=$((count - 1))
    while [ "$i" -ge 0 ]; do
        if [ "$(plutil -extract "apps.$i.bundle-id" raw -o - "$NCPREFS" 2>/dev/null)" = "$APP_BUNDLE_ID" ]; then
            plutil -remove "apps.$i" "$NCPREFS"
            NOTIFICATION_ENTRIES=$((NOTIFICATION_ENTRIES + 1))
        fi
        i=$((i - 1))
    done
fi

NOTIFICATION_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
LOWER_ID="$(printf '%s' "$APP_BUNDLE_ID" | tr '[:upper:]' '[:lower:]')"
NOTIFICATION_ROWS=0
if [ -r "$NOTIFICATION_DB" ]; then
    NOTIFICATION_ROWS="$(sqlite3 -readonly "$NOTIFICATION_DB" \
        "SELECT count(*) FROM app WHERE lower(identifier) = '$LOWER_ID';" 2>/dev/null || echo 0)"
fi

SAVER_CHOSEN=0
defaults -currentHost read com.apple.screensaver moduleDict 2>/dev/null | grep -q "/$SAVER_NAME.saver" && SAVER_CHOSEN=1
WALLPAPER_STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
WALLPAPER_CHOSEN=0
grep -a -q "/$SAVER_NAME.saver" "$WALLPAPER_STORE" 2>/dev/null && WALLPAPER_CHOSEN=1


HELP_CACHE="$HOME/Library/Caches/com.apple.helpd"
HELP_INDEXED=0
grep -a -q -r "$APP_BUNDLE_ID" "$HELP_CACHE"/*.plist 2>/dev/null && HELP_INDEXED=1

# The login item can only be taken back by the app itself, from a build that
# knows how (after v0.5).
UNREGISTERS=""
for app in ${APPS[@]+"${APPS[@]}"}; do
    exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" 2>/dev/null)"
    if [ -x "$exe" ] && grep -a -q -- "--unregister-login-item" "$exe"; then UNREGISTERS="$exe"; break; fi
done

# --- The plan --------------------------------------------------------------

echo "Mosaic on this Mac, for $(id -un):"
for path in ${APPS[@]+"${APPS[@]}"} ${SAVERS[@]+"${SAVERS[@]}"} ${FILES[@]+"${FILES[@]}"}; do
    size="$(du -sh "$path" 2>/dev/null | cut -f1)"
    printf '  remove   %-6s %s\n' "$size" "$path"
done
if [ ${#TEMPS[@]} -gt 0 ]; then
    size="$(du -shc "${TEMPS[@]}" 2>/dev/null | tail -1 | cut -f1)"
    printf '  remove   %-6s %s temporary folders in %s\n' "$size" "${#TEMPS[@]}" "$TMP_DIR"
fi
[ "$HAS_PREFERENCES" = 1 ] && echo "  remove   preferences ($APP_BUNDLE_ID)"
for point in ${MOUNTS[@]+"${MOUNTS[@]}"}; do echo "  eject    $point"; done
if [ ${#APPS[@]} -gt 0 ]; then
    if [ -n "$UNREGISTERS" ]; then
        echo "  remove   the login item, if there is one"
    else
        echo "  check    the login item: this build cannot remove it, System Settings will open"
    fi
    echo "  reset    the Photos permission and every other privacy permission of $APP_NAME"
else
    echo "  reset    the Photos permission and every other privacy permission of $APP_BUNDLE_ID"
fi
[ "$NOTIFICATION_ENTRIES" -gt 0 ] && echo "  remove   the notification settings of $APP_NAME"
[ "$NOTIFICATION_ROWS" -gt 0 ] && echo "  remove   $APP_NAME from the Notification Center database"
[ "$SAVER_CHOSEN" = 1 ] && echo "  reset    the choice of screen saver"
[ "$HELP_INDEXED" = 1 ] && echo "  empty    the help cache (every app's, rebuilt on demand)"
[ "$GONE_COPIES" -gt 0 ] && echo "  forget   $GONE_COPIES copies no longer on disk that Launch Services remembers"
for app in ${OTHER_APPS[@]+"${OTHER_APPS[@]}"}; do echo "  keep     $app (not installed: delete it yourself if you want)"; done

if [ "$DRY" = 1 ]; then
    echo "Dry run: nothing removed."
    exit 0
fi
if [ "$ASK" = 1 ]; then
    printf 'Remove all of this? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing removed."; exit 0 ;; esac
fi

# --- Removal ---------------------------------------------------------------

FAILED=0
fail() { echo "  failed:  $*" >&2; FAILED=1; }

# Pids of the processes running from the bundle at $1.
pids_of() {
    local list
    list="$(ps -axo pid=,command=)"
    printf '%s\n' "$list" | awk -v prefix="$1/Contents/MacOS/" 'index($0, prefix) { print $1 }'
}

echo "==> quitting Mosaic Companion and the screen saver"
if pgrep -x ScreenSaverEngine >/dev/null; then
    osascript -e 'tell application "ScreenSaverEngine" to quit' >/dev/null 2>&1
fi
for app in ${APPS[@]+"${APPS[@]}"} ${OTHER_APPS[@]+"${OTHER_APPS[@]}"}; do
    pids="$(pids_of "$app")"
    [ -n "$pids" ] || continue
    # SIGTERM, not a Quit: a login item asks for confirmation before quitting.
    kill -TERM $pids 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "$(pids_of "$app")" ] && break
        sleep 1
    done
    pids="$(pids_of "$app")"
    [ -n "$pids" ] && kill -KILL $pids 2>/dev/null
done
# The screen saver's host keeps the bundle loaded until it exits.
pgrep -x legacyScreenSaver >/dev/null && killall legacyScreenSaver 2>/dev/null
for point in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
    hdiutil detach -quiet "$point" || hdiutil detach -quiet -force "$point" || fail "eject $point"
done

OPEN_LOGIN_ITEMS=0
if [ ${#APPS[@]} -gt 0 ]; then
    echo "==> login item"
    if [ -n "$UNREGISTERS" ]; then
        "$UNREGISTERS" --unregister-login-item || { fail "login item"; OPEN_LOGIN_ITEMS=1; }
    else
        OPEN_LOGIN_ITEMS=1
    fi
fi

# Before the app goes: tccutil finds the bundle identifier through Launch Services.
echo "==> privacy permissions"
if [ ${#APPS[@]} -gt 0 ] || [ ${#OTHER_APPS[@]} -gt 0 ]; then
    tccutil reset All "$APP_BUNDLE_ID" || fail "privacy permissions (tccutil)"
elif ! tccutil reset All "$APP_BUNDLE_ID" 2>/dev/null; then
    echo "    no copy of $APP_NAME left to reset them through: they stay in"
    echo "    System Settings > Privacy & Security > Photos until macOS forgets them"
fi

if [ "$NOTIFICATION_ENTRIES" -gt 0 ] || [ "$NOTIFICATION_ROWS" -gt 0 ]; then
    echo "==> notifications"
    if [ "$NOTIFICATION_ENTRIES" -gt 0 ]; then
        defaults import com.apple.ncprefs "$NCPREFS" || fail "notification settings"
    fi
    if [ "$NOTIFICATION_ROWS" -gt 0 ]; then
        # A trigger deletes the app's notifications along with it.
        sqlite3 "$NOTIFICATION_DB" ".timeout 5000" \
            "DELETE FROM app WHERE lower(identifier) = '$LOWER_ID';" || fail "notifications"
    fi
    killall usernoted NotificationCenter 2>/dev/null
fi

echo "==> preferences and files"
if [ "$HAS_PREFERENCES" = 1 ]; then
    defaults delete "$APP_BUNDLE_ID" 2>/dev/null || fail "preferences"
fi
for path in ${FILES[@]+"${FILES[@]}"} ${TEMPS[@]+"${TEMPS[@]}"}; do
    rm -rf "$path" || fail "$path"
done

if [ "$SAVER_CHOSEN" = 1 ]; then
    defaults -currentHost delete com.apple.screensaver moduleDict || fail "choice of screen saver"
fi

if [ "$HELP_INDEXED" = 1 ]; then
    echo "==> help cache"
    killall helpd 2>/dev/null
    rm -rf "$HELP_CACHE" || fail "$HELP_CACHE"
fi

echo "==> screen saver and app"
for saver in ${SAVERS[@]+"${SAVERS[@]}"}; do
    rm -rf "$saver" || fail "$saver"
done
NEEDS_ADMIN=()
for app in ${APPS[@]+"${APPS[@]}"}; do
    "$LSREGISTER" -u "$app" 2>/dev/null
    if [ -w "$(dirname "$app")" ]; then
        rm -rf "$app" || fail "$app"
    else
        NEEDS_ADMIN+=("$app")
    fi
done
if [ ${#NEEDS_ADMIN[@]} -gt 0 ]; then
    echo "    $(dirname "${NEEDS_ADMIN[0]}") is not writable by $(id -un): asking for an administrator"
    osascript - "${NEEDS_ADMIN[@]}" >/dev/null <<'APPLESCRIPT' || fail "${NEEDS_ADMIN[*]}"
on run argv
    set command to "/bin/rm -rf"
    repeat with target in argv
        set command to command & " " & quoted form of (target as text)
    end repeat
    do shell script command with administrator privileges
end run
APPLESCRIPT
fi
# The removed copies, and the ones Launch Services remembers from elsewhere:
# a record at a time, so until none is left.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    left="$(gone_copies)"
    [ -n "$left" ] || break
    printf '%s\n' "$left" | while IFS= read -r path; do "$LSREGISTER" -u "$path" 2>/dev/null; done
done
[ -z "$(gone_copies)" ] || fail "Launch Services still remembers: $(gone_copies | tr '\n' ' ')"

echo
if [ "$FAILED" = 1 ]; then
    echo "Done, with failures above."
else
    echo "Done: Mosaic is gone from this profile."
fi
if [ "$OPEN_LOGIN_ITEMS" = 1 ]; then
    echo "- If $APP_NAME is still in Login Items & Extensions, remove it there (opening it now)."
    open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
fi
if [ "$WALLPAPER_CHOSEN" = 1 ]; then
    echo "- Mosaic was the screen saver: choose another in System Settings."
fi
echo "- The unified log keeps Mosaic's messages until macOS rotates them away, in a few days."
for app in ${OTHER_APPS[@]+"${OTHER_APPS[@]}"}; do echo "- Still here, not installed: $app"; done
exit "$FAILED"
