#!/bin/bash
# Diagnostics for BRAW Preview. Paste the output into an issue if thumbnails don't show up.
#
#   scripts/doctor.sh [/path/to/clip.braw]
set -uo pipefail

APP_NAME="BRAW Preview"
BUNDLE_ID="${BUNDLE_ID:-io.github.ranczandras.BRAWPreview}"

section() { printf '\n== %s\n' "$*"; }

section "macOS"
sw_vers

section "Installed app"
app=""
for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    [[ -d "$candidate" ]] && app="$candidate" && echo "$candidate"
done
if [[ -z "$app" ]]; then
    echo "NOT INSTALLED – run ./install.sh"
else
    codesign --verify --deep --strict "$app" && echo "signature: ok"
    for appex in "$app/Contents/PlugIns/"*.appex; do
        printf '%s: ' "$(basename "$appex")"
        [[ -d "$appex/Contents/Frameworks/BlackmagicRawAPI.framework" ]] && echo "framework embedded" || echo "FRAMEWORK MISSING"
    done
fi

section "Registered Quick Look extensions (+ = enabled, - = disabled)"
pluginkit -m -v -i "$BUNDLE_ID.thumbnail"
pluginkit -m -v -i "$BUNDLE_ID.preview"

for clip in "$@"; do
    section "File: $clip"
    if [[ ! -f "$clip" ]]; then echo "not found"; continue; fi
    mdls -name kMDItemContentType -name kMDItemContentTypeTree "$clip"
    out="$(mktemp -d)"
    echo "Generating a 512 px thumbnail with qlmanage..."
    qlmanage -t -s 512 -o "$out" "$clip" 2>&1 | tail -5
    ls -l "$out"
    if ls "$out"/*.png >/dev/null 2>&1; then
        echo "Thumbnail OK – opening it."
        open "$out"/*.png
    fi
done

section "Decoder log (last 10 minutes)"
log show --last 10m --style compact --predicate 'subsystem == "BRAWPreview"' 2>/dev/null | tail -25
