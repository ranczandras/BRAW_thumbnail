#!/bin/bash
# Removes BRAW Preview and its Quick Look extensions.
#
#   bash uninstall.sh
#   curl -fsSL https://raw.githubusercontent.com/ranczandras/BRAW_thumbnail/main/uninstall.sh | bash
set -uo pipefail

# Everything is inside main(), so piping this into bash is safe.
main() {
    local APP_NAME="BRAW Preview"
    local LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

    pkill -x "$APP_NAME" 2>/dev/null
    removed=0
    for app in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
        [[ -d "$app" ]] || continue
        for appex in "$app/Contents/PlugIns/"*.appex; do pluginkit -r "$appex" 2>/dev/null; done
        "$LSREGISTER" -u "$app" 2>/dev/null
        rm -rf "$app" && echo "Removed: $app" && removed=1
    done
    qlmanage -r >/dev/null 2>&1
    qlmanage -r cache >/dev/null 2>&1

    if (( removed )); then
        echo "Done."
    else
        echo "BRAW Preview was not installed."
    fi
}

main "$@"
