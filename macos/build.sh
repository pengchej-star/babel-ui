#!/bin/sh
# Build "Babel UI.app" (Release, ad-hoc signed) into ./build/.
#   ./build.sh            build only
#   ./build.sh install    build, then copy the app to ~/Applications (quit the running copy first)
set -eu
cd "$(dirname "$0")"
xcodebuild -project BabelUI.xcodeproj -scheme BabelUI -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData build -quiet
rm -rf "build/Babel UI.app"
cp -R "build/DerivedData/Build/Products/Release/Babel UI.app" "build/Babel UI.app"
echo "Built: $(pwd)/build/Babel UI.app"
if [ "${1:-}" = install ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Babel UI.app"
  cp -R "build/Babel UI.app" "$HOME/Applications/Babel UI.app"
  echo "Installed: $HOME/Applications/Babel UI.app"
fi
