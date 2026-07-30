#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <sha256> <output-path>" >&2
    exit 64
fi

version=$1
sha256=$2
output_path=$3

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must be a stable semantic version (X.Y.Z)" >&2
    exit 65
fi

if [[ ! $sha256 =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: sha256 must be 64 lowercase hexadecimal characters" >&2
    exit 65
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
template="$repo_root/distribution/homebrew/claude-usage.rb.template"

if [[ ! -f $template ]]; then
    echo "error: cask template not found: $template" >&2
    exit 66
fi

mkdir -p "$(dirname "$output_path")"
sed \
    -e "s/__VERSION__/$version/g" \
    -e "s/__SHA256__/$sha256/g" \
    "$template" > "$output_path"

if rg -q '__VERSION__|__SHA256__' "$output_path"; then
    echo "error: unresolved cask template placeholder" >&2
    exit 65
fi

ruby -c "$output_path" >/dev/null
echo "Rendered Homebrew cask: $output_path"
