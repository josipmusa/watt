#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
source_path="${1:-$project_dir/Resources/AppIcon-1024.png}"
output_path="${2:-$project_dir/Resources/Watt.icns}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/watt-app-icon.XXXXXX")"
iconset_path="$temporary_dir/Watt.iconset"
normalized_path="$temporary_dir/AppIcon-1024.png"

cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT

if [[ ! -f "$source_path" ]]; then
    echo "App icon source not found: $source_path" >&2
    exit 1
fi

mkdir -p "$iconset_path" "${output_path:h}"
swift "$script_dir/normalize-app-icon.swift" "$source_path" "$normalized_path"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$normalized_path" \
        --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$normalized_path" \
        --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns --output "$output_path" "$iconset_path"
echo "$output_path"
