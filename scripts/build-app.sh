#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_options=()
if [[ -n "${TILES_BUILD_PATH:-}" ]]; then
  build_options+=(--scratch-path "$TILES_BUILD_PATH")
fi
swift build -c release --product MaterialOrganizer -j 4 "${build_options[@]}"
bin_dir="$(swift build -c release --show-bin-path "${build_options[@]}")"
app_path="$PWD/dist/TILES.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/MaterialOrganizer" "$app_path/Contents/MacOS/MaterialOrganizer"
for bundle in "$bin_dir"/*.bundle(N); do
  ditto "$bundle" "$app_path/Contents/Resources/${bundle:t}"
done
cp scripts/Info.plist "$app_path/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
