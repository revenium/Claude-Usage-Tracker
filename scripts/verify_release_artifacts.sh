#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
release_constants_path="$script_dir/release_constants.sh"
[[ -r $release_constants_path ]] || {
    echo "error: release constants are not readable: $release_constants_path" >&2
    exit 66
}
# shellcheck source=scripts/release_constants.sh
source "$release_constants_path"

usage() {
    cat >&2 <<'EOF'
usage: verify_release_artifacts.sh [options] <dmg> <appcast> <metadata-json>

Options:
  --require-developer-id   Require a Developer ID Application signature.
  --require-notarization   Require stapler and Gatekeeper acceptance.
EOF
}

require_developer_id=false
require_notarization=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --require-developer-id)
            require_developer_id=true
            shift
            ;;
        --require-notarization)
            require_notarization=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            usage
            echo "error: unknown option: $1" >&2
            exit 64
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -ne 3 ]]; then
    usage
    exit 64
fi

dmg_path=$1
appcast_path=$2
metadata_path=$3

for path in "$dmg_path" "$appcast_path" "$metadata_path"; do
    [[ -f $path ]] || {
        echo "error: required artifact not found: $path" >&2
        exit 66
    }
done

actual_sha=$(shasum -a 256 "$dmg_path" | awk '{ print $1 }')

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/revvytach-release-verify.XXXXXX")
mount_point="$work_dir/mount"
mkdir -p "$mount_point"
attached=false
cleanup() {
    if $attached; then
        hdiutil detach "$mount_point" -quiet -force || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg_path" >/dev/null
attached=true

app_path="$mount_point/RevvyTach.app"
info_plist="$app_path/Contents/Info.plist"
[[ -d $app_path && -f $info_plist ]] || {
    echo 'error: DMG does not contain RevvyTach.app at its root' >&2
    exit 65
}

if find "$mount_point" -mindepth 1 -maxdepth 1 \
    ! -name 'RevvyTach.app' \
    ! -name 'Applications' \
    ! -name '.*' \
    | grep -q .; then
    echo 'error: DMG contains files outside RevvyTach.app and the Applications symlink' >&2
    exit 65
fi

[[ -L "$mount_point/Applications" ]] || {
    echo 'error: DMG does not contain an Applications symlink at its root' >&2
    exit 65
}
applications_link_target=$(readlink "$mount_point/Applications")
[[ $applications_link_target == '/Applications' ]] || {
    echo "error: Applications symlink does not point at /Applications: $applications_link_target" >&2
    exit 65
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist"
}

bundle_id=$(plist_value CFBundleIdentifier)
version=$(plist_value CFBundleShortVersionString)
build=$(plist_value CFBundleVersion)
minimum_os=$(plist_value LSMinimumSystemVersion)
feed_url=$(plist_value SUFeedURL)
public_key=$(plist_value SUPublicEDKey)
channel=$(plist_value ReveniumUpdateChannel)

[[ $bundle_id == "$release_bundle_identifier" ]] || {
    echo "error: bundle identity changed: $bundle_id" >&2
    exit 65
}
[[ $minimum_os == '14.0' ]] || {
    echo "error: minimum macOS version changed: $minimum_os" >&2
    exit 65
}
[[ $feed_url == "$release_feed_url" ]] || {
    echo "error: release feed is not the Revenium production feed: $feed_url" >&2
    exit 65
}
[[ $channel == 'production' ]] || {
    echo "error: release channel is not production: $channel" >&2
    exit 65
}

printf '%s' "$public_key" | openssl base64 -d -A > "$work_dir/public-key.bin"
[[ $(stat -f%z "$work_dir/public-key.bin") -eq 32 ]] || {
    echo 'error: SUPublicEDKey is not a 32-byte Ed25519 public key' >&2
    exit 65
}

executable="$app_path/Contents/MacOS/RevvyTach"
architectures=$(lipo -archs "$executable")
[[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || {
    echo "error: release executable is not universal: $architectures" >&2
    exit 65
}

xpath_string() {
    xmllint --xpath "string($1)" "$appcast_path"
}

appcast_version=$(xpath_string '//*[local-name()="item"]/*[local-name()="shortVersionString"]')
appcast_build=$(xpath_string '//*[local-name()="item"]/*[local-name()="version"]')
appcast_minimum_os=$(xpath_string '//*[local-name()="item"]/*[local-name()="minimumSystemVersion"]')
enclosure_url=$(xpath_string '//*[local-name()="enclosure"]/@url')
enclosure_length=$(xpath_string '//*[local-name()="enclosure"]/@length')
signature=$(xpath_string '//*[local-name()="enclosure"]/@*[local-name()="edSignature"]')

expected_download_url="$release_repository_url/releases/download/v$version/RevvyTach.dmg"
actual_length=$(stat -f%z "$dmg_path")

[[ $appcast_version == "$version" ]] || {
    echo 'error: appcast marketing version does not match the app bundle' >&2
    exit 65
}
[[ $appcast_build == "$build" ]] || {
    echo 'error: appcast build does not match the app bundle' >&2
    exit 65
}
[[ $appcast_minimum_os == "$minimum_os" ]] || {
    echo 'error: appcast minimum OS does not match the app bundle' >&2
    exit 65
}
[[ $enclosure_url == "$expected_download_url" ]] || {
    echo "error: appcast enclosure URL is not commit/version-cohesive: $enclosure_url" >&2
    exit 65
}
[[ $enclosure_length == "$actual_length" ]] || {
    echo 'error: appcast enclosure length does not match the DMG' >&2
    exit 65
}

printf '%s' "$signature" | openssl base64 -d -A > "$work_dir/signature.bin"
[[ $(stat -f%z "$work_dir/signature.bin") -eq 64 ]] || {
    echo 'error: appcast does not contain a valid-length Ed25519 signature' >&2
    exit 65
}

metadata_value() {
    plutil -extract "$1" raw -o - "$metadata_path"
}

metadata_version=$(metadata_value version)
metadata_build=$(metadata_value build)
metadata_tag=$(metadata_value tag)
metadata_bundle_id=$(metadata_value bundleIdentifier)
metadata_minimum_os=$(metadata_value minimumSystemVersion)
metadata_sha=$(metadata_value sha256)
metadata_commit=$(metadata_value commit)
metadata_url=$(metadata_value artifactURL)

[[ $metadata_tag == "v$version" &&
   $metadata_version == "$version" &&
   $metadata_build == "$build" &&
   $metadata_bundle_id == "$bundle_id" &&
   $metadata_minimum_os == "$minimum_os" &&
   $metadata_sha == "$actual_sha" &&
   $metadata_url == "$expected_download_url" &&
   $metadata_commit =~ ^[0-9a-f]{40}$ ]] || {
    echo 'error: release metadata is not cohesive with the app, DMG, or appcast' >&2
    exit 65
}

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign -d --entitlements :- "$app_path" > "$work_dir/entitlements.plist" 2>/dev/null
plutil -lint "$work_dir/entitlements.plist" >/dev/null

for forbidden_entitlement in \
    'com.apple.security.get-task-allow' \
    'com.apple.security.cs.disable-library-validation'; do
    if [[ $(plutil -extract "$forbidden_entitlement" raw -o - "$work_dir/entitlements.plist" 2>/dev/null || true) == 'true' ]]; then
        echo "error: release contains forbidden entitlement: $forbidden_entitlement" >&2
        exit 65
    fi
done

signature_details=$(codesign -dvvv "$app_path" 2>&1)
if $require_developer_id; then
    grep -Eq -- '^Authority=Developer ID Application:' <<< "$signature_details" || {
        echo 'error: app is not signed with a Developer ID Application certificate' >&2
        exit 65
    }
    grep -Eq -- '^TeamIdentifier=[A-Z0-9]+$' <<< "$signature_details" || {
        echo 'error: Developer ID signature is missing a team identifier' >&2
        exit 65
    }
fi

if $require_notarization; then
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=4 "$app_path"
fi

# The disk image is the artifact users actually download, so it carries its own
# signature and notarization ticket — verify the container, not just its payload.
dmg_signature_details=$(codesign -dvvv "$dmg_path" 2>&1 || true)
if $require_developer_id; then
    grep -Eq -- '^Authority=Developer ID Application:' <<< "$dmg_signature_details" || {
        echo 'error: disk image is not signed with a Developer ID Application certificate' >&2
        exit 65
    }
    app_team=$(sed -nE 's/^TeamIdentifier=([A-Z0-9]+)$/\1/p' <<< "$signature_details")
    dmg_team=$(sed -nE 's/^TeamIdentifier=([A-Z0-9]+)$/\1/p' <<< "$dmg_signature_details")
    [[ -n $dmg_team && $dmg_team == "$app_team" ]] || {
        echo "error: disk image team identifier does not match the app ($dmg_team != $app_team)" >&2
        exit 65
    }
fi

if $require_notarization; then
    xcrun stapler validate "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
fi

echo "Release artifacts verified: v$version ($build), $architectures, $actual_sha"
