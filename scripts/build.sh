#!/bin/bash
# Builds "BRAW Preview.app" (a host app carrying two Quick Look extensions) into OUTPUT_DIR.
#
#   scripts/build.sh [OUTPUT_DIR]          (default: ./build)
#
# Needs the Xcode Command Line Tools and the Blackmagic RAW SDK, which the free
# "Blackmagic RAW" installer puts in /Applications/Blackmagic RAW/Blackmagic RAW SDK.
#
# Environment overrides:
#   BRAW_SDK        SDK's Mac folder     (default: /Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac)
#   BRAW_INCLUDE    header folder        (default: $BRAW_SDK/Include)
#   BRAW_FRAMEWORK  BlackmagicRawAPI.framework to embed (default: $BRAW_SDK/Libraries/BlackmagicRawAPI.framework)
#   SKIP_FRAMEWORK  1 = don't embed the framework (compile check only, e.g. CI)
#   ARCHS           e.g. "arm64 x86_64"  (default: this Mac's architecture)
#   BUNDLE_ID       app bundle identifier
#   SIGN_ID         codesign identity    (default: "-", ad-hoc, fine for your own Mac)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"

APP_NAME="BRAW Preview"
BUNDLE_ID="${BUNDLE_ID:-io.github.ranczandras.BRAWPreview}"
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
MIN_MACOS="12.0"
ARCHS="${ARCHS:-$(uname -m)}"
SIGN_ID="${SIGN_ID:--}"
SKIP_FRAMEWORK="${SKIP_FRAMEWORK:-0}"

BRAW_SDK="${BRAW_SDK:-/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac}"
BRAW_INCLUDE="${BRAW_INCLUDE:-$BRAW_SDK/Include}"
BRAW_FRAMEWORK="${BRAW_FRAMEWORK:-$BRAW_SDK/Libraries/BlackmagicRawAPI.framework}"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ "$(uname -s)" == Darwin ]] || die "this builds a macOS app; run it on a Mac."
xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || die "Xcode Command Line Tools are missing (run: xcode-select --install)."
[[ -f "$BRAW_INCLUDE/BlackmagicRawAPI.h" && -f "$BRAW_INCLUDE/BlackmagicRawAPIDispatch.cpp" ]] \
    || die "Blackmagic RAW SDK headers not found in: $BRAW_INCLUDE"
if [[ "$SKIP_FRAMEWORK" != 1 ]]; then
    [[ -d "$BRAW_FRAMEWORK" ]] || die "BlackmagicRawAPI.framework not found at: $BRAW_FRAMEWORK"
fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx --find clang)"
CXX="$(xcrun --sdk macosx --find clang++)"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(-arch "$arch"); done
COMMON=(-isysroot "$SDKROOT" "${ARCH_FLAGS[@]}" -mmacosx-version-min="$MIN_MACOS" -O2 -Wall -fobjc-arc)
EXTENSION=(-fapplication-extension)

OBJ="$OUT/obj"
APP="$OUT/$APP_NAME.app"
rm -rf "$APP" "$OBJ"
mkdir -p "$OBJ"

step "Compiling (${ARCHS})"
# Blackmagic's loader for BlackmagicRawAPI.framework, from the SDK itself.
"$CXX" "${COMMON[@]}" "${EXTENSION[@]}" -std=c++17 -w -c "$BRAW_INCLUDE/BlackmagicRawAPIDispatch.cpp" -o "$OBJ/dispatch.o"
# -nostdinc++: our code needs no C++ standard library headers, which some Command Line Tools
# installs lack (often after a macOS upgrade). This keeps it that way.
"$CXX" "${COMMON[@]}" "${EXTENSION[@]}" -std=c++17 -nostdinc++ -isystem "$BRAW_INCLUDE" \
    -c "$ROOT/Sources/Shared/BRAWClip.mm" -o "$OBJ/clip.o"
for source in Thumbnail/ThumbnailProvider Preview/ClipPlayer Preview/PreviewViewController; do
    "$CC" "${COMMON[@]}" "${EXTENSION[@]}" -I "$ROOT/Sources/Shared" \
        -c "$ROOT/Sources/$source.m" -o "$OBJ/$(basename "$source").o"
done
"$CC" "${COMMON[@]}" -c "$ROOT/Sources/App/main.m" -o "$OBJ/app.o"

render_plist() { # template destination
    sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__VERSION__|$VERSION|g" \
        -e "s|__BUILD__|$BUILD_NUMBER|g" -e "s|__MIN_MACOS__|$MIN_MACOS|g" "$1" > "$2"
    plutil -lint -s "$2"
}

build_extension() { # executable-name plist-template objects-and-frameworks...
    local name="$1" template="$2"
    shift 2
    local appex="$APP/Contents/PlugIns/$name.appex"
    step "Building $name.appex"
    mkdir -p "$appex/Contents/MacOS"
    render_plist "$template" "$appex/Contents/Info.plist"
    "$CXX" "${COMMON[@]}" "${EXTENSION[@]}" -Wl,-e,_NSExtensionMain \
        "$@" "$OBJ/clip.o" "$OBJ/dispatch.o" \
        -framework Foundation -framework CoreFoundation -framework CoreGraphics \
        -o "$appex/Contents/MacOS/$name"
    if [[ "$SKIP_FRAMEWORK" != 1 ]]; then
        # Each extension gets its own copy: the sandbox of a Quick Look extension can't load
        # code from outside its own bundle. (On APFS "cp -c" clones, so no extra disk space.)
        mkdir -p "$appex/Contents/Frameworks"
        cp -Rc "$BRAW_FRAMEWORK" "$appex/Contents/Frameworks/" 2>/dev/null \
            || ditto "$BRAW_FRAMEWORK" "$appex/Contents/Frameworks/BlackmagicRawAPI.framework"
    fi
}

step "Building $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns"
render_plist "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
"$CC" "${COMMON[@]}" "$OBJ/app.o" -framework Cocoa -o "$APP/Contents/MacOS/$APP_NAME"

build_extension BRAWThumbnail "$ROOT/Resources/Thumbnail-Info.plist" \
    "$OBJ/ThumbnailProvider.o" -framework QuickLookThumbnailing
build_extension BRAWPreview "$ROOT/Resources/Preview-Info.plist" \
    "$OBJ/PreviewViewController.o" "$OBJ/ClipPlayer.o" \
    -framework QuickLookUI -framework AppKit -framework AVFoundation -framework QuartzCore

step "Signing (identity: $SIGN_ID)"
# codesign refuses files carrying Finder info or resource forks.
xattr -cr "$APP"
for appex in "$APP/Contents/PlugIns/"*.appex; do
    framework="$appex/Contents/Frameworks/BlackmagicRawAPI.framework"
    if [[ -d "$framework" ]] && ! codesign --verify --strict "$framework" >/dev/null 2>&1; then
        codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$framework"
    fi
    codesign --force --sign "$SIGN_ID" --timestamp=none \
        --entitlements "$ROOT/Resources/Extension.entitlements" "$appex"
done
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$OBJ"
step "Built: $APP"
