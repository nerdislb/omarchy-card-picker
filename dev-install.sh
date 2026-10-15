#!/bin/bash
# Publish complete, versioned QML URLs; preserve all desktop preferences.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/.config/omarchy/plugins/nerdibeard.card-picker"
omarchy plugin validate "$here"
python3 "$here/bin/install-generation.py" "$here" "$target"
omarchy plugin validate "$target"
echo "Installed Card Picker generation; no shell restart required."
