#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

fail() {
    echo "distribution validation failed: $*" >&2
    exit 1
}

release_constants_path="$script_dir/release_constants.sh"
[[ -r $release_constants_path ]] \
    || fail "release constants are not readable: $release_constants_path"
# shellcheck source=scripts/release_constants.sh
source "$release_constants_path"

contains() {
    grep -Eq -- "$1" "$2"
}

contains_fixed() {
    grep -Fq -- "$1" "$2"
}

count_matches() {
    grep -Ec -- "$1" "$2" || true
}

expected_app_group='group.com.claudeusagetracker.shared'

plutil -lint \
    'Claude Usage/Resources/Info.plist' \
    'Claude Usage/Claude UsageRelease.entitlements' \
    'Claude Usage/ClaudeUsageTracker.entitlements' >/dev/null

info_plist='Claude Usage/Resources/Info.plist'
contains '<string>\$\(SPARKLE_FEED_URL\)</string>' "$info_plist" \
    || fail 'Info.plist must use the injected Sparkle feed build setting'
contains '<string>\$\(SPARKLE_PUBLIC_ED_KEY\)</string>' "$info_plist" \
    || fail 'Info.plist must use the injected Sparkle public-key build setting'
contains '<string>\$\(REVENIUM_UPDATE_CHANNEL\)</string>' "$info_plist" \
    || fail 'Info.plist must use the injected update channel build setting'

project='Claude Usage.xcodeproj/project.pbxproj'
bundle_id_count=$(count_matches "PRODUCT_BUNDLE_IDENTIFIER = $release_bundle_identifier;" "$project")
[[ $bundle_id_count -eq 2 ]] \
    || fail 'application bundle identifier changed or is not present in both configurations'
contains 'MACOSX_DEPLOYMENT_TARGET = 14\.0;' "$project" \
    || fail 'macOS 14 deployment target must be preserved'
contains 'REVENIUM_UPDATE_CHANNEL = development;' "$project" \
    || fail 'Debug update channel is not development-isolated'
contains 'REVENIUM_UPDATE_CHANNEL = production;' "$project" \
    || fail 'Release update channel is not production'
# The real feed URL and public key are injected by the release workflow alone, so
# every configuration checked into the project must default them to empty. Comparing
# the empty count against the total count keeps this true as configurations are added
# and, unlike a fixed expected count, still fails when a new one hardcodes a value.
feed_url_total=$(count_matches 'SPARKLE_FEED_URL = ' "$project")
feed_url_empty=$(count_matches 'SPARKLE_FEED_URL = "";' "$project")
[[ $feed_url_total -ge 3 && $feed_url_empty -eq $feed_url_total ]] \
    || fail 'every build configuration must default the Sparkle feed to empty'
public_key_total=$(count_matches 'SPARKLE_PUBLIC_ED_KEY = ' "$project")
public_key_empty=$(count_matches 'SPARKLE_PUBLIC_ED_KEY = "";' "$project")
[[ $public_key_total -ge 3 && $public_key_empty -eq $public_key_total ]] \
    || fail 'every build configuration must default the Sparkle public key to empty'
contains "static let appGroupIdentifier = \"$expected_app_group\"" \
    'Claude Usage/Shared/Utilities/Constants.swift' \
    || fail 'legacy preference/app-group identity changed'

# The vendored copy under Resources/Licenses ships inside the app bundle so
# every distributed copy carries the MIT permission notice and warranty
# disclaimer, as MIT requires (a hosted unit test can assert the resource is
# present in the built app, but it cannot see this repo's root LICENSE to
# compare against, so that check belongs here instead). The two files must
# never drift: regenerate the vendored copy with `cp`, never hand-edit it.
license_path='LICENSE'
vendored_license_path='Claude Usage/Resources/Licenses/RevvyTach-LICENSE.txt'
[[ -r $license_path ]] \
    || fail "root license is not readable: $license_path"
[[ -r $vendored_license_path ]] \
    || fail "vendored license is not readable: $vendored_license_path"
cmp -s "$license_path" "$vendored_license_path" \
    || fail "vendored license has drifted from root LICENSE; regenerate it with: cp '$license_path' '$vendored_license_path'"

blocked_owner=$(printf '%s' 'hamed' '-elfayome')
blocked_worker=$(printf '%s' 'hamed' 'elfayome')
blocked_tap=$(printf '%s' 'ggf' 'evans')
blocked_pattern="$blocked_owner|$blocked_worker|$blocked_tap"

active_paths=(
    '.github'
    'Claude Usage/Resources/Info.plist'
    'Claude Usage/Shared/Services/GitHubService.swift'
    'Claude Usage/Shared/Services/UpdateManager.swift'
    'Claude Usage/Shared/Utilities/Constants.swift'
    'Claude Usage/Views/FeedbackPromptView.swift'
    'Claude Usage/Views/Settings/App/SupportView.swift'
    'CONTRIBUTING.md'
    'README.md'
    'RELEASING.md'
    'SECURITY.md'
    'distribution'
    'scripts'
)

if grep -ERn -- "$blocked_pattern" "${active_paths[@]}"; then
    fail 'active operational endpoint still references prior ownership'
fi

if grep -ERn -- 'github\.io/.+appcast|gh-pages' .github/workflows; then
    fail 'release workflows must not consume or publish the inherited Pages feed'
fi

constants='Claude Usage/Shared/Utilities/Constants.swift'
[[ $release_repository_url == \
    'https://github.com/revenium/RevvyTach' ]] \
    || fail 'shared release repository does not match the trusted origin'
contains 'productionFeedURL = URL\(string: Constants\.GitHub\.appcastURL\)!' \
    'Claude Usage/Shared/Services/UpdateManager.swift' \
    || fail 'runtime production feed does not use the application repository constants'
contains 'static let owner = "revenium"' "$constants" \
    || fail 'application repository owner is not Revenium'
contains 'static let repo = "RevvyTach"' "$constants" \
    || fail 'application repository name is not RevvyTach'
contains_fixed 'static let repoURL = "https://github.com/\(owner)/\(repo)"' \
    "$constants" \
    || fail 'application repository URL does not derive from its trusted identity'
contains_fixed 'static let releasesURL = "\(repoURL)/releases"' "$constants" \
    || fail 'application releases URL does not derive from its repository URL'
contains_fixed 'static let appcastURL = "\(releasesURL)/latest/download/appcast.xml"' \
    "$constants" \
    || fail 'application appcast path does not target the latest release asset'
contains 'repos/revenium/homebrew-tap/contents/Casks/revvytach\.rb' \
    '.github/workflows/update-homebrew-cask.yml' \
    || fail 'Homebrew workflow does not target the Revenium tap'
homebrew_workflow='.github/workflows/update-homebrew-cask.yml'
appcast_workflow='.github/workflows/generate-appcast.yml'
release_workflow='.github/workflows/release.yml'
if contains 'workflow_dispatch' "$homebrew_workflow"; then
    fail 'Homebrew tap token workflow must not have a manual tag-owned entry point'
fi
contains 'environment: release' "$homebrew_workflow" \
    || fail 'Homebrew publication is not protected by the release environment'
[[ $(count_matches 'HOMEBREW_TAP_TOKEN' "$release_workflow") -eq 1 ]] \
    || fail 'Homebrew tap token must only be passed to the isolated cask publisher'
contains 'HOMEBREW_TAP_TOKEN: \$\{\{ secrets\.HOMEBREW_TAP_TOKEN \}\}' "$release_workflow" \
    || fail 'Homebrew tap token is not scoped to the isolated cask publisher call'
contains 'expected_digest' "$homebrew_workflow" \
    || fail 'Homebrew publication does not verify the GitHub-reported artifact digest'
contains 'merge-base --is-ancestor "\$source_commit" FETCH_HEAD' "$homebrew_workflow" \
    || fail 'Homebrew publication does not require source containment in main'
contains 'current_sha' "$homebrew_workflow" \
    || fail 'Homebrew Contents API update lacks an optimistic blob-SHA guard'

contains 'fetch-depth: 0' "$appcast_workflow" \
    || fail 'manual appcast verification must fetch complete source history'
contains 'source_commit=\$\(git rev-parse HEAD\)' "$appcast_workflow" \
    || fail 'manual appcast verification does not resolve the checked-out tag commit'
contains 'git fetch --no-tags origin main' "$appcast_workflow" \
    || fail 'manual appcast verification does not fetch the authoritative main branch'
contains 'merge-base --is-ancestor "\$source_commit" FETCH_HEAD' "$appcast_workflow" \
    || fail 'manual appcast verification does not require source containment in main'
contains 'hdiutil attach -nobrowse -readonly -mountpoint' "$appcast_workflow" \
    || fail 'manual appcast verification does not mount the published disk image read-only'

contains 'revenium-release-workflow:\$GITHUB_SHA' "$release_workflow" \
    || fail 'release drafts do not carry exact-commit ownership provenance'
contains '--draft' "$release_workflow" \
    || fail 'release workflow does not create a private draft'
contains 'verified-draft' "$release_workflow" \
    || fail 'release workflow does not re-download its draft assets'
contains 'cmp -s' "$release_workflow" \
    || fail 'release workflow does not byte-compare remote and local draft assets'
contains '--draft=false' "$release_workflow" \
    || fail 'release workflow does not explicitly publish the verified draft'

# Pre-rename hosts (bundle ID HamedElfayome.Claude-Usage, app file "Claude Usage.app")
# can only find an update inside the DMG when a bundle carrying the legacy filename is
# present, because the v4.0.0 rename changed the filename and bundle ID together and
# defeats all three of Sparkle's install-source matching rules. Dropping this staging
# step silently strands every remaining 3.x install on a bogus signature error.
contains 'LEGACY_APP_NAME: Claude Usage' "$release_workflow" \
    || fail 'release workflow does not define the legacy app name used for Sparkle update discovery'
contains 'cp -R "\$app_path" "\$stage_dir/\$LEGACY_APP_NAME\.app"' "$release_workflow" \
    || fail 'release workflow does not stage the legacy-named app copy; 3.x in-app updates would break'
contains 'Claude Usage\.app' "$script_dir/verify_release_artifacts.sh" \
    || fail 'release artifact verification does not check for the legacy-named app copy'

distribution_workflows=(
    '.github/workflows/distribution-validation.yml'
    '.github/workflows/generate-appcast.yml'
    '.github/workflows/release.yml'
    '.github/workflows/update-homebrew-cask.yml'
)

xcode_workflows=(
    '.github/workflows/distribution-validation.yml'
    '.github/workflows/generate-appcast.yml'
    '.github/workflows/release.yml'
)

for workflow in "${xcode_workflows[@]}"; do
    contains 'xcode-select -s /Applications/Xcode_26\.0\.1\.app/Contents/Developer' \
        "$workflow" \
        || fail "Xcode workflow is not pinned to 26.0.1: $workflow"
done

for workflow in "${distribution_workflows[@]}"; do
    ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$workflow" \
        || fail "invalid workflow YAML: $workflow"
done
ruby "$script_dir/validate_yaml_duplicates.rb" "${distribution_workflows[@]}" \
    || fail 'distribution workflow contains a duplicate YAML key'

while IFS= read -r uses_line; do
    action_ref=${uses_line#*@}
    [[ $action_ref =~ ^[0-9a-f]{40}([[:space:]]|$) ]] \
        || fail "GitHub Action is not pinned to a full commit: $uses_line"
done < <(
    grep -Eho -- 'uses:[[:space:]]+[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+@[0-9A-Za-z_.-]+' \
        "${distribution_workflows[@]}" \
        | sed -E 's/^.*uses:[[:space:]]+//'
)

for shell_script in scripts/*.sh; do
    bash -n "$shell_script"
done

# `keychain-access-groups` is only honoured on a Developer ID app when an
# embedded provisioning profile allowlists it. Signing without one does not
# degrade to "the entitlement is ignored" — AMFI refuses to spawn the process
# (`launchctl error 163`), so the app cannot launch at all. v3.3.0 shipped
# exactly that, passed every existing gate including notarization and
# Gatekeeper, and was unlaunchable on every machine. Gatekeeper assessment does
# not execute the app, which is why nothing here caught it.
#
# So: if an entitlements file claims that key, the release workflow must embed a
# provisioning profile. Both halves, or neither.
#
# Deliberately scoped to this one key rather than "restricted entitlements" in
# general. Other entitlements plausibly carry the same requirement, but which
# ones do is not something to assert from memory in a gate that can block a
# release — asserting an unverified platform rule is what produced the bug this
# check exists to prevent. Widening it means first confirming, per key, that a
# profile really is required.
# Ask the plist parser whether the key is really set, rather than grepping for
# the name: the entitlements file documents at length why the key is absent, and
# a textual match would fire on that explanation.
keychain_entitlement_files=()
while IFS= read -r entitlements_file; do
    plutil -extract keychain-access-groups raw -o - "$entitlements_file" \
        >/dev/null 2>&1 \
        && keychain_entitlement_files+=("$entitlements_file")
done < <(find . -name '*.entitlements' -not -path './build/*')

if (( ${#keychain_entitlement_files[@]} > 0 )); then
    contains_fixed 'embedded.provisionprofile' .github/workflows/release.yml \
        || fail "keychain-access-groups declared in ${keychain_entitlement_files[*]} but the release workflow never embeds a provisioning profile; the signed app will fail to launch (launchctl error 163)"
fi

rendered_cask=$(mktemp "${TMPDIR:-/tmp}/revvytach-cask.XXXXXX.rb")
trap 'rm -f "$rendered_cask"' EXIT
"$script_dir/render_homebrew_cask.sh" \
    '99.99.99' \
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    "$rendered_cask" >/dev/null
contains_fixed "$release_repository_url/releases/download/v#{version}/RevvyTach.dmg" "$rendered_cask" \
    || fail 'rendered cask URL is not the version-pinned Revenium release asset'
contains_fixed 'depends_on macos: :sonoma' "$rendered_cask" \
    || fail 'rendered cask does not preserve the macOS 14 minimum'
if contains_fixed 'depends_on macos: "' "$rendered_cask"; then
    fail 'rendered cask uses the deprecated string-comparison form of depends_on macos:; use the bare symbol (>= is the default comparator)'
fi

echo 'Distribution configuration validated.'
