#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

fail() {
    echo "distribution validation failed: $*" >&2
    exit 1
}

contains() {
    grep -Eq -- "$1" "$2"
}

contains_fixed() {
    grep -Fq -- "$1" "$2"
}

count_matches() {
    grep -Ec -- "$1" "$2" || true
}

expected_repo='https://github.com/revenium/Claude-Usage-Tracker'
expected_feed="$expected_repo/releases/latest/download/appcast.xml"
expected_bundle_id='HamedElfayome.Claude-Usage'
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
bundle_id_count=$(count_matches "PRODUCT_BUNDLE_IDENTIFIER = \"$expected_bundle_id\";" "$project")
[[ $bundle_id_count -eq 2 ]] \
    || fail 'application bundle identifier changed or is not present in both configurations'
contains 'MACOSX_DEPLOYMENT_TARGET = 14\.0;' "$project" \
    || fail 'macOS 14 deployment target must be preserved'
contains 'REVENIUM_UPDATE_CHANNEL = development;' "$project" \
    || fail 'Debug update channel is not development-isolated'
contains 'REVENIUM_UPDATE_CHANNEL = production;' "$project" \
    || fail 'Release update channel is not production'
[[ $(count_matches 'SPARKLE_FEED_URL = "";' "$project") -eq 3 ]] \
    || fail 'Debug, local Release, and UI-testing feed defaults must all be empty'
[[ $(count_matches 'SPARKLE_PUBLIC_ED_KEY = "";' "$project") -eq 3 ]] \
    || fail 'Debug, local Release, and UI-testing public-key defaults must all be empty'
contains "static let appGroupIdentifier = \"$expected_app_group\"" \
    'Claude Usage/Shared/Utilities/Constants.swift' \
    || fail 'legacy preference/app-group identity changed'

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
    'Claude Usage/Views/Settings/App/MobileAppView.swift'
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

contains_fixed "$expected_feed" 'Claude Usage/Shared/Services/UpdateManager.swift' \
    || fail 'runtime production feed does not match Revenium Releases'
constants='Claude Usage/Shared/Utilities/Constants.swift'
contains 'static let owner = "revenium"' "$constants" \
    || fail 'application repository owner is not Revenium'
contains 'static let repo = "Claude-Usage-Tracker"' "$constants" \
    || fail 'application repository name is not Claude-Usage-Tracker'
contains 'repos/revenium/homebrew-tap/contents/Casks/claude-usage\.rb' \
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
contains 'metadata_commit == "\$source_commit"' "$homebrew_workflow" \
    || fail 'Homebrew publication does not bind metadata to the checked-out tag commit'
contains 'merge-base --is-ancestor "\$source_commit" FETCH_HEAD' "$homebrew_workflow" \
    || fail 'Homebrew publication does not require source containment in main'
contains 'current_sha' "$homebrew_workflow" \
    || fail 'Homebrew Contents API update lacks an optimistic blob-SHA guard'

contains 'fetch-depth: 0' "$appcast_workflow" \
    || fail 'manual appcast verification must fetch complete source history'
contains 'metadata_commit=\$\(plutil -extract commit raw -o -' "$appcast_workflow" \
    || fail 'manual appcast verification does not read release source metadata'
contains 'source_commit=\$\(git rev-parse HEAD\)' "$appcast_workflow" \
    || fail 'manual appcast verification does not resolve the checked-out tag commit'
contains 'metadata_commit == "\$source_commit"' "$appcast_workflow" \
    || fail 'manual appcast verification does not bind metadata to the checked-out tag'
contains 'git fetch --no-tags origin main' "$appcast_workflow" \
    || fail 'manual appcast verification does not fetch the authoritative main branch'
contains 'merge-base --is-ancestor "\$source_commit" FETCH_HEAD' "$appcast_workflow" \
    || fail 'manual appcast verification does not require source containment in main'

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
    grep -Eho -- 'uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9A-Za-z_.-]+' \
        "${distribution_workflows[@]}" \
        | sed -E 's/^.*uses:[[:space:]]+//'
)

for shell_script in scripts/*.sh; do
    bash -n "$shell_script"
done

rendered_cask=$(mktemp "${TMPDIR:-/tmp}/claude-usage-cask.XXXXXX.rb")
trap 'rm -f "$rendered_cask"' EXIT
"$script_dir/render_homebrew_cask.sh" \
    '99.99.99' \
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    "$rendered_cask" >/dev/null
contains_fixed "$expected_repo/releases/download/v#{version}/Claude-Usage.zip" "$rendered_cask" \
    || fail 'rendered cask URL is not the version-pinned Revenium release asset'
contains 'depends_on macos: ">= :sonoma"' "$rendered_cask" \
    || fail 'rendered cask does not preserve the macOS 14 minimum'

echo 'Distribution configuration validated.'
