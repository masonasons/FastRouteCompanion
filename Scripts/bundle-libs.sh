#!/bin/bash
#
# Copies the Homebrew codec libraries the executable links against (libopus,
# libFLAC and whatever they depend on) into the app's Frameworks folder, points
# the executable at the copies through @rpath, and signs them so the app runs
# on a Mac without Homebrew. Runs as an Xcode build phase.
#
set -euo pipefail

EXE="$BUILT_PRODUCTS_DIR/$EXECUTABLE_PATH"
FRAMEWORKS="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
mkdir -p "$FRAMEWORKS"

# Prints the absolute Homebrew library references of a Mach-O file.
brew_deps() {
    otool -L "$1" | awk 'NR>1 {print $1}' | grep -E '^/opt/homebrew/|^/usr/local/(opt|lib|Cellar)/' || true
}

# Rewrites one Homebrew reference in $1 to its bundled copy, copying the
# library first if it is not bundled yet. Recurses into the copied library.
bundle_ref() {
    local file="$1" ref="$2"
    local name
    name=$(basename "$ref")
    if [ ! -f "$FRAMEWORKS/$name" ]; then
        if [ ! -f "$ref" ]; then
            echo "warning: $ref is referenced by $file but is not installed" >&2
            return
        fi
        cp -f "$ref" "$FRAMEWORKS/$name"
        chmod u+w "$FRAMEWORKS/$name"
        install_name_tool -id "@rpath/$name" "$FRAMEWORKS/$name"
        for dep in $(brew_deps "$FRAMEWORKS/$name"); do
            bundle_ref "$FRAMEWORKS/$name" "$dep"
        done
    fi
    install_name_tool -change "$ref" "@rpath/$name" "$file"
}

# Debug builds put the code in a .debug.dylib next to a stub executable, so
# every Mach-O in the MacOS folder is checked.
for binary in "$EXE" "$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH"/*.dylib; do
    [ -f "$binary" ] || continue
    for dep in $(brew_deps "$binary"); do
        bundle_ref "$binary" "$dep"
    done
done

# Sign the copies so library validation and Gatekeeper accept them.
for lib in "$FRAMEWORKS"/*.dylib; do
    [ -f "$lib" ] || continue
    codesign --force --sign "$IDENTITY" --timestamp=none "$lib"
done

echo "Bundled codec libraries: $(ls "$FRAMEWORKS" | tr '\n' ' ')"
