#!/bin/bash
# Builds "1Shot.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="1Shot.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Swift compiler isn't installed yet."
  echo "Run this, click Install, then run ./build.sh again:"
  echo "    xcode-select --install"
  exit 1
fi

# Quit any running 1Shot first (it saves its project), so no old copy keeps running from
# files this build is about to replace.
BUNDLE_ID="com.itsscottwilder.timecodeplayer"
running_copies() {
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$BUNDLE_ID').count" 2>/dev/null || echo 0
}
if [ "$(running_copies)" != "0" ]; then
  echo "Quitting 1Shot..."
  osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$BUNDLE_ID'); for (var i = 0; i < a.count; i++) a.objectAtIndex(i).terminate; ''" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    [ "$(running_copies)" = "0" ] && break
    sleep 0.5
  done
  if [ "$(running_copies)" != "0" ]; then
    echo "1Shot is still open (maybe a dialog is waiting). Quit it, then run ./build.sh again."
    exit 1
  fi
fi

echo "Building..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -O -target arm64-apple-macosx26.0 main.swift ControlServer.swift Graphics.swift Loudness.swift Undo.swift AudioRack.swift SoundDesignPanel.swift Exporter.swift TrimBar.swift VisualDesignPanel.swift TrimPanel.swift WorkspaceTabBar.swift RightPanel.swift TimelineListPanel.swift TimelinePanels.swift ExportRecipes.swift ExportPanel.swift VisualGroups.swift VisualGroupControl.swift Waveform.swift PlateHandles.swift BrollHandles.swift Assets.swift AssetsPanel.swift Project.swift Transcriber.swift Cuts.swift Zooms.swift Broll.swift DavinciExport.swift ColorGrade.swift LevelsView.swift CubeLUT.swift MeterView.swift Compressor.swift Limiter.swift Gate.swift Stabilizer.swift DeEsser.swift -o "$APP/Contents/MacOS/1Shot"
# App icon: AppIcon.png (1024 x 1024) -> every size macOS needs -> AppIcon.icns
if [ -f AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

# Starter editing style guides (copied to ~/Movies/1Shot/Style Guides on launch)
if [ -d StyleGuides ]; then
  mkdir -p "$APP/Contents/Resources/StyleGuides"
  cp StyleGuides/*.md "$APP/Contents/Resources/StyleGuides/"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"   # nudges Finder and the Dock to pick up the new icon

# MCP helper (2.4): the small program the Claude desktop app starts to drive 1Shot.
# It's installed in ~/Library/Application Support/1Shot so its path never changes,
# wherever you keep the app.
echo "Building the MCP helper..."
xcrun swiftc -O -target arm64-apple-macosx26.0 MCP/main.swift -o 1shot-mcp
SUPPORT="$HOME/Library/Application Support/1Shot"
# 3.2: the app was "1Shot Pipeline" before. Move its folders to the new name (once; never overwrites).
for pair in "$HOME/Library/Application Support|1Shot" "$HOME/Movies|1Shot"; do
  base="${pair%%|*}"; new="${pair##*|}"
  if [ -d "$base/1Shot Pipeline" ] && [ ! -e "$base/$new" ]; then
    mv "$base/1Shot Pipeline" "$base/$new"
    echo "Moved $base/1Shot Pipeline to $base/$new"
  fi
done
mkdir -p "$SUPPORT"
rm -f "$SUPPORT/1shot-mcp"            # remove first, so a copy Claude is running isn't overwritten in place
cp 1shot-mcp "$SUPPORT/1shot-mcp"
codesign --force --sign - "$SUPPORT/1shot-mcp" >/dev/null 2>&1 || true
echo "$(pwd)/$APP" > "$SUPPORT/app-path"
"$SUPPORT/1shot-mcp" --install

echo "Done: $(pwd)/$APP"
echo "Drag it into your Applications folder if you like."
open -R "$APP"
