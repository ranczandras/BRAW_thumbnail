#!/bin/bash
# One-line installer for BRAW Preview:
#
#   curl -fsSL https://raw.githubusercontent.com/ranczandras/BRAW_thumbnail/main/get.sh | bash
#
# Downloads the source into a temporary folder, runs install.sh (which builds the app on this
# Mac against the Blackmagic RAW SDK installed here), then deletes the download.
#
# Everything is inside main(), so a download cut short can't run half a script.

main() {
    set -euo pipefail
    local repo="ranczandras/BRAW_thumbnail"
    local ref="${BRAW_PREVIEW_REF:-main}"

    if [[ "$(uname -s)" != Darwin ]]; then
        echo "Error: BRAW Preview is for macOS." >&2
        exit 1
    fi

    # Global, not local: the EXIT trap runs after main() has returned.
    BRAW_PREVIEW_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/braw-preview-source.XXXXXX")"
    trap 'rm -rf "$BRAW_PREVIEW_SOURCE"' EXIT
    local work="$BRAW_PREVIEW_SOURCE"

    echo "Downloading BRAW Preview ($ref)..."
    curl -fsSL "https://github.com/$repo/archive/refs/heads/$ref.tar.gz" | tar -xz -C "$work" --strip-components 1

    # stdin is this very script when piped into bash: keep install.sh off it.
    BRAW_PREVIEW_ONE_LINER=1 bash "$work/install.sh" </dev/null
}

main "$@"
