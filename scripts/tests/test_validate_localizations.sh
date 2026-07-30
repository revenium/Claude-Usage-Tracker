#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$REPOSITORY_ROOT/scripts/validate_localizations.sh"
FIXTURES="$REPOSITORY_ROOT/scripts/fixtures/localization-validator"
EXPECTED_LOCALES=(de en es fr it ja ko pt zh-Hans)
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/localization-validator.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

test_number=0

new_case() {
    test_number=$((test_number + 1))
    CASE_DIR="$TEST_ROOT/case-$test_number"
    mkdir -p "$CASE_DIR"
    for locale in "${EXPECTED_LOCALES[@]}"; do
        mkdir -p "$CASE_DIR/$locale.lproj"
        cp "$FIXTURES/valid.strings" \
            "$CASE_DIR/$locale.lproj/Localizable.strings"
    done
}

run_catalog_validator() {
    LOCALIZATION_RESOURCES_DIR="$CASE_DIR" \
    LOCALIZATION_SKIP_SOURCE_SCAN=1 \
    LOCALIZATION_SELF_VALUE_ALLOWLIST=fixture.allowed \
        "$VALIDATOR"
}

run_source_validator() {
    LOCALIZATION_RESOURCES_DIR="$CASE_DIR" \
    LOCALIZATION_SOURCE_DIR="$SOURCE_DIR" \
        "$VALIDATOR"
}

expect_failure() {
    local expected_message="$1"
    local output_file="$TEST_ROOT/failure-output"
    if run_catalog_validator >"$output_file" 2>&1; then
        printf 'error: expected validator failure containing: %s\n' \
            "$expected_message" >&2
        exit 1
    fi
    if ! grep -F "$expected_message" "$output_file" >/dev/null; then
        printf 'error: validator failed without expected message: %s\n' \
            "$expected_message" >&2
        sed -n '1,160p' "$output_file" >&2
        exit 1
    fi
}

new_case
for locale in "${EXPECTED_LOCALES[@]}"; do
    cp "$FIXTURES/allowlisted-self-value.strings" \
        "$CASE_DIR/$locale.lproj/Localizable.strings"
done
run_catalog_validator >/dev/null
printf 'ok: valid escaped catalog and allowlisted raw self-value\n'

new_case
cp "$FIXTURES/malformed.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure "malformed property list"
printf 'ok: malformed catalog rejected\n'

new_case
cp "$FIXTURES/duplicate.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure "duplicate localization key"
printf 'ok: duplicate key rejected\n'

new_case
cp "$FIXTURES/missing-key.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure 'de: missing key "fixture.plain"'
printf 'ok: missing key rejected\n'

new_case
cp "$FIXTURES/extra-key.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure 'de: extra key "fixture.extra"'
printf 'ok: extra key rejected\n'

new_case
cp "$FIXTURES/placeholder-type.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure "placeholder signature mismatch"
printf 'ok: placeholder type mismatch rejected\n'

new_case
cp "$FIXTURES/placeholder-count.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure "placeholder signature mismatch"
printf 'ok: placeholder count mismatch rejected\n'

new_case
cp "$FIXTURES/placeholder-position.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure "placeholder signature mismatch"
printf 'ok: placeholder position mismatch rejected\n'

new_case
cp "$FIXTURES/empty-value.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure "empty value"
printf 'ok: empty value rejected\n'

new_case
cp "$FIXTURES/raw-self-value.strings" \
    "$CASE_DIR/de.lproj/Localizable.strings"
expect_failure "raw-key self-value"
printf 'ok: non-allowlisted raw self-value rejected\n'

new_case
mv "$CASE_DIR/de.lproj" "$CASE_DIR/de.missing"
expect_failure "localization directories must be exactly"
printf 'ok: missing locale rejected\n'

new_case
mkdir -p "$CASE_DIR/nl.lproj"
cp "$FIXTURES/valid.strings" \
    "$CASE_DIR/nl.lproj/Localizable.strings"
expect_failure "localization directories must be exactly"
printf 'ok: extra locale rejected\n'

new_case
SOURCE_DIR="$TEST_ROOT/source-present"
mkdir -p "$SOURCE_DIR"
cp "$FIXTURES/SourcePresent.swift" "$SOURCE_DIR/SourcePresent.swift"
cp "$FIXTURES/NormalizedUsageView.swift" \
    "$SOURCE_DIR/NormalizedUsageView.swift"
run_source_validator >/dev/null
printf 'ok: present literal keys accepted for every helper family\n'
fixture_only_output="$TEST_ROOT/fixture-only-output"
if LOCALIZATION_RESOURCES_DIR="$CASE_DIR" \
    LOCALIZATION_SOURCE_DIR="$SOURCE_DIR" \
    LOCALIZATION_SELF_VALUE_ALLOWLIST=fixture.allowed \
        "$VALIDATOR" >"$fixture_only_output" 2>&1; then
    printf 'error: test-only self-value allowlist was accepted in production mode\n' \
        >&2
    exit 1
fi
grep -F "LOCALIZATION_SELF_VALUE_ALLOWLIST is fixture-only" \
    "$fixture_only_output" >/dev/null
printf 'ok: self-value allowlist override is fixture-only\n'

new_case
SOURCE_DIR="$TEST_ROOT/source-missing"
mkdir -p "$SOURCE_DIR"
cp "$FIXTURES/SourceMissing.swift" "$SOURCE_DIR/SourceMissing.swift"
cp "$FIXTURES/NormalizedUsageViewMissing.swift" \
    "$SOURCE_DIR/NormalizedUsageView.swift"
source_output="$TEST_ROOT/source-failure-output"
if run_source_validator >"$source_output" 2>&1; then
    printf 'error: expected source call-site validation failure\n' >&2
    exit 1
fi
for missing_key in \
    missing.localized \
    missing.ns_localized \
    missing.provider_ui \
    missing.normalized \
    missing.formatted \
    missing.bundle \
    missing.title \
    missing.explanation \
    missing.carried \
    missing.wrapper \
    popover.normalized.missing_deferred
do
    if ! grep -F "source localization key \"$missing_key\" is absent" \
        "$source_output" >/dev/null; then
        printf 'error: source scanner missed helper key: %s\n' \
            "$missing_key" >&2
        sed -n '1,200p' "$source_output" >&2
        exit 1
    fi
done
printf 'ok: absent literal keys rejected for every helper family\n'

printf 'Localization validator fixture tests passed: %d cases.\n' \
    "$test_number"
