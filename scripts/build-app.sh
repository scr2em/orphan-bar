#!/bin/zsh
# Builds OrphanBar.app into ./build. With --install, replaces ~/Applications/OrphanBar.app and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/OrphanBar"
app="build/OrphanBar.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/OrphanBar"
cp Support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x OrphanBar 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/OrphanBar.app
    cp -R "$app" ~/Applications/
    open ~/Applications/OrphanBar.app
    echo "Installed ~/Applications/OrphanBar.app"
fi
