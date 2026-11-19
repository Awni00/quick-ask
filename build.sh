#!/usr/bin/env bash
# Builds Quick Ask.app into build/. With --install, also copies it to
# ~/Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Quick Ask.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuickAsk "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/web "$APP/Contents/Resources/"
# Icons are generated from Resources/Icon/*.svg; regenerate them when an SVG is
# newer than its output (or run tools/render-icons.swift by hand).
ICON=Resources/Icon
if [[ $ICON/AppIcon.svg -nt $ICON/AppIcon.icns || $ICON/MenuBarIcon.svg -nt $ICON/MenuBarIcon.png ]]; then
  swift tools/render-icons.swift $ICON/AppIcon.svg $ICON/MenuBarIcon.svg $ICON
fi
cp $ICON/AppIcon.icns $ICON/MenuBarIcon.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"  # ad-hoc signature, for this Mac only
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x QuickAsk || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Quick Ask.app"
  cp -R "$APP" ~/Applications/
  # `open` passes on the caller's environment; start the app with a clean one,
  # as Finder or a login item would.
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin open ~/Applications/"Quick Ask.app"
  echo "Installed and started ~/Applications/Quick Ask.app"
fi
