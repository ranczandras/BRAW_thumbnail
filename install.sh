#!/bin/bash
# Builds and installs BRAW Preview: Finder thumbnails and Quick Look playback for .braw clips.
#
#   bash install.sh
#
# Run it again any time, e.g. after updating Blackmagic RAW (newer cameras need a newer SDK).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BRAW Preview"
BUNDLE_ID="${BUNDLE_ID:-io.github.ranczandras.BRAWPreview}"
export BUNDLE_ID
REPO_RAW="https://raw.githubusercontent.com/ranczandras/BRAW_thumbnail/main"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BRAW_DOWNLOAD_PAGE="https://www.blackmagicdesign.com/products/blackmagicraw"

# get.sh (the one-line installer) runs this from a temporary download, so point at the web
# copies of the helper scripts instead of local paths.
if [[ "${BRAW_PREVIEW_ONE_LINER:-0}" == 1 ]]; then
    RERUN="curl -fsSL $REPO_RAW/get.sh | bash"
    DOCTOR="curl -fsSL $REPO_RAW/scripts/doctor.sh | bash -s -- /path/to/clip.braw"
else
    RERUN="bash install.sh"
    DOCTOR="bash scripts/doctor.sh /path/to/clip.braw"
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "BRAW Preview is for macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 12 )) || die "macOS 12 Monterey or later is required."

# 1. Xcode Command Line Tools (the compiler).
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    say "The Xcode Command Line Tools are missing – their installer is opening now."
    xcode-select --install 2>/dev/null || true
    die "When that installation has finished, run this again:  $RERUN"
fi

# 2. Blackmagic RAW SDK (part of the free "Blackmagic RAW" download).
export BRAW_SDK="${BRAW_SDK:-/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac}"
if [[ ! -f "$BRAW_SDK/Include/BlackmagicRawAPI.h" || ! -d "$BRAW_SDK/Libraries/BlackmagicRawAPI.framework" ]]; then
    say "The Blackmagic RAW SDK was not found in: $BRAW_SDK"
    echo "Download and install the free \"Blackmagic RAW\" package (it includes the Player and the SDK):"
    echo "  $BRAW_DOWNLOAD_PAGE"
    open "$BRAW_DOWNLOAD_PAGE" 2>/dev/null || true
    die "Then run this again:  $RERUN"
fi

# 3. Build into a temporary folder, so Finder never sees (and registers) a second copy.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/braw-preview.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
say "Building..."
"$ROOT/scripts/build.sh" "$STAGE"

# 4. Install: /Applications, or ~/Applications when /Applications isn't writable.
DEST_DIR=/Applications
[[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$APP_NAME.app"

say "Installing to: $DEST"
pkill -x "$APP_NAME" 2>/dev/null || true
for old in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    [[ -d "$old" ]] || continue
    for appex in "$old/Contents/PlugIns/"*.appex; do pluginkit -r "$appex" 2>/dev/null || true; done
    "$LSREGISTER" -u "$old" 2>/dev/null || true
    rm -rf "$old"
done
ditto "$STAGE/$APP_NAME.app" "$DEST"

# 5. Register the extensions. From here on macOS starts them by itself whenever Finder asks for
#    a thumbnail or preview – no login item or background process needed.
say "Registering the Quick Look extensions..."
"$LSREGISTER" -f -R -trusted "$DEST"
for appex in "$DEST/Contents/PlugIns/"*.appex; do pluginkit -a "$appex"; done
pluginkit -e use -i "$BUNDLE_ID.thumbnail" || true
pluginkit -e use -i "$BUNDLE_ID.preview" || true

# 6. Forget cached thumbnails so existing .braw files get new ones.
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

# Launching the app once also makes macOS enable its extensions.
open "$DEST"

say "Done!"
cat <<EOF
Finder now shows thumbnails for .braw clips, and the Space bar plays them in Quick Look.
If a folder that was already open still shows the old icons, close its window and open it again.

Troubleshooting:  $DOCTOR
EOF
