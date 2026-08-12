#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
    echo "Usage: $0 <github-owner/repository> <version> [archive-path]" >&2
    exit 64
fi

repository="$1"
version="$2"
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
archive_path="${3:-$project_dir/dist/Watt-${version}-macos-arm64.zip}"
template_path="$project_dir/packaging/Casks/watt.rb.template"
output_path="$project_dir/dist/watt.rb"

if [[ ! "$repository" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]]; then
    echo "Repository must use the github-owner/repository format" >&2
    exit 64
fi

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "Version must use the numeric x.y.z format" >&2
    exit 64
fi

if [[ ! -f "$archive_path" ]]; then
    echo "Archive not found: $archive_path" >&2
    exit 66
fi

checksum="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
mkdir -p "${output_path:h}"

REPOSITORY="$repository" VERSION="$version" CHECKSUM="$checksum" \
    ruby - "$template_path" "$output_path" <<'RUBY'
template_path, output_path = ARGV
contents = File.read(template_path)
  .gsub("__REPOSITORY__", ENV.fetch("REPOSITORY"))
  .gsub("__VERSION__", ENV.fetch("VERSION"))
  .gsub("__SHA256__", ENV.fetch("CHECKSUM"))
File.write(output_path, contents)
RUBY

echo "$output_path"
