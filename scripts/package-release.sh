#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    echo "Usage: $0 <version> [build-number]" >&2
    exit 64
fi

version="$1"
build_number="${2:-1}"
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
dist_dir="$project_dir/dist"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "Version must use the numeric x.y.z format (received: $version)" >&2
    exit 64
fi

if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    echo "Build number must be a positive integer (received: $build_number)" >&2
    exit 64
fi

WATT_VERSION="$version" WATT_BUILD_NUMBER="$build_number" \
    "$script_dir/build-app.sh" release >/dev/null

app_path="$project_dir/.build/Watt.app"
binary_path="$app_path/Contents/MacOS/Watt"
architectures="$(lipo -archs "$binary_path")"

if [[ "$architectures" != "arm64" ]]; then
    echo "Release packaging currently expects an arm64-only binary (found: $architectures)" >&2
    exit 1
fi

mkdir -p "$dist_dir"
archive_name="Watt-${version}-macos-arm64.zip"
archive_path="$dist_dir/$archive_name"
checksum_path="$archive_path.sha256"
rm -f "$archive_path" "$checksum_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
checksum="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
print -r -- "$checksum  $archive_name" > "$checksum_path"

echo "$archive_path"
echo "$checksum_path"
