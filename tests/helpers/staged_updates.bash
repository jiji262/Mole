#!/usr/bin/env bash
# Fixtures for staged app updates (Squirrel ShipIt, electron-updater, and
# Application Support updates/<App>.app). Loaded by the Bats files that
# exercise those guards; nothing here touches the real HOME.

# Minimal app bundle with an XML Info.plist.
staged_update_make_bundle() {
    local bundle="$1" bundle_id="$2" short="$3" build="$4"
    local plist="$bundle/Contents/Info.plist"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleIdentifier -string "$bundle_id" "$plist"
    plutil -insert CFBundleShortVersionString -string "$short" "$plist"
    plutil -insert CFBundleVersion -string "$build" "$plist"
}

# electron-updater layout: pending/update-info.json naming Foo.zip, which
# holds the listed bundles from the stage directory.
staged_update_make_pending_zip() {
    local cache_dir="$1" stage="$2"
    shift 2
    mkdir -p "$cache_dir/pending"
    printf '{"fileName":"Foo.zip","sha512":"x","isAdminRightsRequired":false}\n' \
        > "$cache_dir/pending/update-info.json"
    (cd "$stage" && zip -qr "$cache_dir/pending/Foo.zip" "$@")
}
