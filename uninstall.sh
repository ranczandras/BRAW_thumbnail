#!/bin/bash
# Removes BRAW Preview and its Quick Look extensions.
set -uo pipefail

APP_NAME="BRAW Preview"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

pkill -x "$APP_NAME" 2>/dev/null
removed=0
for app in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    [[ -d "$app" ]] || continue
    for appex in "$app/Contents/PlugIns/"*.appex; do pluginkit -r "$appex" 2>/dev/null; done
    "$LSREGISTER" -u "$app" 2>/dev/null
    rm -rf "$app" && echo "Törölve / Removed: $app" && removed=1
done
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1

if (( removed )); then
    echo "Kész. / Done."
else
    echo "Nem volt telepítve. / It was not installed."
fi
