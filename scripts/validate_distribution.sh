#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

fail() {
    echo "distribution validation failed: $*" >&2
    exit 1
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
rg -q '<string>\$\(SPARKLE_FEED_URL\)</string>' "$info_plist" \
    || fail 'Info.plist must use the injected Sparkle feed build setting'
rg -q '<string>\$\(SPARKLE_PUBLIC_ED_KEY\)</string>' "$info_plist" \
    || fail 'Info.plist must use the injected Sparkle public-key build setting'
rg -q '<string>\$\(REVENIUM_UPDATE_CHANNEL\)</string>' "$info_plist" \
    || fail 'Info.plist must use the injected update channel build setting'

project='Claude Usage.xcodeproj/project.pbxproj'
bundle_id_count=$(rg -c "PRODUCT_BUNDLE_IDENTIFIER = \"$expected_bundle_id\";" "$project")
[[ $bundle_id_count -eq 2 ]] \
    || fail 'application bundle identifier changed or is not present in both configurations'
rg -q 'MACOSX_DEPLOYMENT_TARGET = 14\.0;' "$project" \
    || fail 'macOS 14 deployment target must be preserved'
rg -q 'REVENIUM_UPDATE_CHANNEL = development;' "$project" \
    || fail 'Debug update channel is not development-isolated'
rg -q 'REVENIUM_UPDATE_CHANNEL = production;' "$project" \
    || fail 'Release update channel is not production'
[[ $(rg -c 'SPARKLE_FEED_URL = "";' "$project") -eq 2 ]] \
    || fail 'Debug and local Release feed defaults must both be empty'
[[ $(rg -c 'SPARKLE_PUBLIC_ED_KEY = "";' "$project") -eq 2 ]] \
    || fail 'Debug and local Release public-key defaults must both be empty'
rg -q "static let appGroupIdentifier = \"$expected_app_group\"" \
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

if rg -n "$blocked_pattern" "${active_paths[@]}"; then
    fail 'active operational endpoint still references prior ownership'
fi

if rg -n 'github\.io/.+appcast|gh-pages' .github/workflows; then
    fail 'release workflows must not consume or publish the inherited Pages feed'
fi

rg -qF "$expected_feed" 'Claude Usage/Shared/Services/UpdateManager.swift' \
    || fail 'runtime production feed does not match Revenium Releases'
constants='Claude Usage/Shared/Utilities/Constants.swift'
rg -q 'static let owner = "revenium"' "$constants" \
    || fail 'application repository owner is not Revenium'
rg -q 'static let repo = "Claude-Usage-Tracker"' "$constants" \
    || fail 'application repository name is not Claude-Usage-Tracker'
rg -q 'repository: revenium/homebrew-tap' \
    '.github/workflows/update-homebrew-cask.yml' \
    || fail 'Homebrew workflow does not target the Revenium tap'

distribution_workflows=(
    '.github/workflows/distribution-validation.yml'
    '.github/workflows/generate-appcast.yml'
    '.github/workflows/release.yml'
    '.github/workflows/update-homebrew-cask.yml'
)

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
    rg -o 'uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9A-Za-z_.-]+' \
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
rg -qF "$expected_repo/releases/download/v#{version}/Claude-Usage.zip" "$rendered_cask" \
    || fail 'rendered cask URL is not the version-pinned Revenium release asset'
rg -q 'depends_on macos: ">= :sonoma"' "$rendered_cask" \
    || fail 'rendered cask does not preserve the macOS 14 minimum'

echo 'Distribution configuration validated.'
