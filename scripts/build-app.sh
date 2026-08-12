#!/bin/zsh
set -euo pipefail

configuration="${1:-debug}"
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
info_plist="$project_dir/Info.plist"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 64
fi

version="${WATT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")}"
build_number="${WATT_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")}"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "WATT_VERSION must use the numeric x.y.z format (received: $version)" >&2
    exit 64
fi

if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    echo "WATT_BUILD_NUMBER must be a positive integer (received: $build_number)" >&2
    exit 64
fi

cd "$project_dir"
swift build -c "$configuration"

binary_path="$(swift build -c "$configuration" --show-bin-path)/Watt"
app_path="$project_dir/.build/Watt.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/Watt"
cp "$info_plist" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"
# Harden even local/ad-hoc builds. This does not require an Apple Developer
# account and keeps the packaged app aligned with the Xcode target's settings.
codesign --force --options runtime --sign - "$app_path"

echo "$app_path"
