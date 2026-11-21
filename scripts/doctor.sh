#!/bin/bash
# Diagnostics for BRAW Preview. Paste the output into an issue if thumbnails or playback don't work.
#
#   bash scripts/doctor.sh [/path/to/clip.braw ...]
#   curl -fsSL https://raw.githubusercontent.com/ranczandras/BRAW_thumbnail/main/scripts/doctor.sh | bash -s -- /path/to/clip.braw
set -uo pipefail

section() { printf '\n== %s\n' "$*"; }

# Everything is inside main(), so piping this into bash is safe.
main() {
    local APP_NAME="BRAW Preview"
    local BUNDLE_ID="${BUNDLE_ID:-io.github.ranczandras.BRAWPreview}"

    section "macOS"
    sw_vers

    section "Installed app"
    local app=""
    for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
        [[ -d "$candidate" ]] && app="$candidate" && echo "$candidate"
    done
    if [[ -z "$app" ]]; then
        echo "NOT INSTALLED – see https://github.com/ranczandras/BRAW_thumbnail#install"
    else
        codesign --verify --deep --strict "$app" && echo "signature: ok"
        for appex in "$app/Contents/PlugIns/"*.appex; do
            printf '%s: ' "$(basename "$appex")"
            if [[ -d "$appex/Contents/Frameworks/BlackmagicRawAPI.framework" ]]; then
                echo "framework embedded"
            else
                echo "FRAMEWORK MISSING"
            fi
        done
    fi

    section "Registered Quick Look extensions (+ = enabled, - = disabled)"
    pluginkit -m -v -i "$BUNDLE_ID.thumbnail" </dev/null
    pluginkit -m -v -i "$BUNDLE_ID.preview" </dev/null

    local clip out
    for clip in "$@"; do
        section "File: $clip"
        if [[ ! -f "$clip" ]]; then
            echo "not found"
            continue
        fi
        mdls -name kMDItemContentType -name kMDItemContentTypeTree "$clip" </dev/null
        out="$(mktemp -d)"
        echo "Generating a 512 px thumbnail with qlmanage..."
        qlmanage -t -s 512 -o "$out" "$clip" </dev/null 2>&1 | tail -5
        ls -l "$out"
        if ls "$out"/*.png >/dev/null 2>&1; then
            echo "Thumbnail OK – opening it."
            open "$out"/*.png
        fi
    done

    section "Decoder and player log (last 10 minutes)"
    log show --last 10m --style compact --predicate 'subsystem == "BRAWPreview"' </dev/null 2>/dev/null | tail -25
}

main "$@"
