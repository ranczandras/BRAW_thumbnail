#!/bin/bash
# Builds and installs BRAW Preview: Finder thumbnails and Quick Look previews for .braw clips.
#
#   ./install.sh
#
# Run it again any time, e.g. after updating Blackmagic RAW (newer cameras need a newer SDK).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BRAW Preview"
BUNDLE_ID="${BUNDLE_ID:-io.github.ranczandras.BRAWPreview}"
export BUNDLE_ID
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BRAW_DOWNLOAD_PAGE="https://www.blackmagicdesign.com/products/blackmagicraw"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mHiba / Error:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Ez macOS-re való. / This is for macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 12 )) || die "macOS 12 vagy újabb kell. / macOS 12 or later is required."

# 1. Xcode Command Line Tools (compiler, codesign helpers).
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    say "Az Xcode Command Line Tools hiányzik – most felugrik a telepítője."
    echo "The Xcode Command Line Tools are missing – their installer is opening now."
    xcode-select --install 2>/dev/null || true
    die "Ha végzett a telepítés, futtasd újra: ./install.sh  (Run ./install.sh again when it has finished.)"
fi

# 2. Blackmagic RAW SDK (part of the free "Blackmagic RAW" download).
export BRAW_SDK="${BRAW_SDK:-/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac}"
if [[ ! -f "$BRAW_SDK/Include/BlackmagicRawAPI.h" || ! -d "$BRAW_SDK/Libraries/BlackmagicRawAPI.framework" ]]; then
    say "Nem találom a Blackmagic RAW SDK-t itt: $BRAW_SDK"
    echo "Töltsd le és telepítsd az ingyenes \"Blackmagic RAW\" csomagot (benne van a Player és az SDK):"
    echo "Download and install the free \"Blackmagic RAW\" package (it includes the Player and the SDK):"
    echo "  $BRAW_DOWNLOAD_PAGE"
    open "$BRAW_DOWNLOAD_PAGE" 2>/dev/null || true
    die "Utána futtasd újra: ./install.sh  (Then run ./install.sh again.)"
fi

# 3. Build into a temporary folder, so Finder never sees (and registers) a second copy.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/braw-preview.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
say "Fordítás... / Building..."
"$ROOT/scripts/build.sh" "$STAGE"

# 4. Install: /Applications, or ~/Applications when /Applications isn't writable.
DEST_DIR=/Applications
[[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$APP_NAME.app"

say "Telepítés ide: / Installing to: $DEST"
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
say "Regisztrálás... / Registering..."
"$LSREGISTER" -f -R -trusted "$DEST"
for appex in "$DEST/Contents/PlugIns/"*.appex; do pluginkit -a "$appex"; done
pluginkit -e use -i "$BUNDLE_ID.thumbnail" || true
pluginkit -e use -i "$BUNDLE_ID.preview" || true

# 6. Forget cached thumbnails so existing .braw files get new ones.
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

# Launching the app once also makes macOS enable its extensions.
open "$DEST"

say "Kész! / Done!"
cat <<EOF
A Finder mostantól bélyegképet mutat a .braw fájlokhoz, szóközzel pedig nagy előnézetet.
Ha egy már megnyitott mappában még a régi ikon látszik, zárd be és nyisd meg újra az ablakot.
Hibakeresés:  ./scripts/doctor.sh /útvonal/klip.braw

Finder now shows thumbnails for .braw files, and a large preview with the Space bar.
Troubleshooting:  ./scripts/doctor.sh /path/to/clip.braw
EOF
