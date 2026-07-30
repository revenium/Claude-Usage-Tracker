#!/bin/bash

# Validate every shipped localization catalog and every literal localization
# helper call site. The environment overrides are intentionally supported so
# scripts/tests/test_validate_localizations.sh can exercise isolated fixtures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="${LOCALIZATION_RESOURCES_DIR:-$REPOSITORY_ROOT/Claude Usage/Resources}"
SOURCE_DIR="${LOCALIZATION_SOURCE_DIR:-$REPOSITORY_ROOT/Claude Usage}"
SKIP_SOURCE_SCAN="${LOCALIZATION_SKIP_SOURCE_SCAN:-0}"
EXPECTED_LOCALES=(de en es fr it ja ko pt zh-Hans)

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

command -v plutil >/dev/null 2>&1 || fail "plutil is required"
command -v ruby >/dev/null 2>&1 || fail "ruby is required"
[[ -d "$RESOURCES_DIR" ]] || fail "resources directory not found: $RESOURCES_DIR"

actual_locale_count="$(
    find "$RESOURCES_DIR" -mindepth 1 -maxdepth 1 \
        -type d -name '*.lproj' | wc -l | tr -d ' '
)"
unexpected_locales=()
while IFS= read -r locale; do
    case " ${EXPECTED_LOCALES[*]} " in
        *" $locale "*) ;;
        *) unexpected_locales+=("$locale") ;;
    esac
done < <(
    find "$RESOURCES_DIR" -mindepth 1 -maxdepth 1 \
        -type d -name '*.lproj' -exec basename {} .lproj \;
)

if [[ "$actual_locale_count" -ne "${#EXPECTED_LOCALES[@]}" ]] \
    || [[ "${#unexpected_locales[@]}" -ne 0 ]]; then
    printf 'error: localization directories must be exactly: %s\n' \
        "${EXPECTED_LOCALES[*]}" >&2
    printf 'error: found %s locale directories' "$actual_locale_count" >&2
    if [[ "${#unexpected_locales[@]}" -ne 0 ]]; then
        printf '; unexpected: %s' "${unexpected_locales[*]}" >&2
    fi
    printf '\n' >&2
    exit 1
fi

for locale in "${EXPECTED_LOCALES[@]}"; do
    catalog="$RESOURCES_DIR/$locale.lproj/Localizable.strings"
    [[ -f "$catalog" ]] || fail "missing catalog: $catalog"
    if ! plutil -lint "$catalog" >/dev/null; then
        printf 'error: malformed property list: %s\n' "$catalog" >&2
        plutil -lint "$catalog" >&2 || true
        exit 1
    fi
done

export LOCALIZATION_VALIDATOR_RESOURCES_DIR="$RESOURCES_DIR"
export LOCALIZATION_VALIDATOR_SOURCE_DIR="$SOURCE_DIR"
export LOCALIZATION_VALIDATOR_SKIP_SOURCE_SCAN="$SKIP_SOURCE_SCAN"

ruby -r json -r open3 -r pathname -r set <<'RUBY'
EXPECTED_LOCALES = %w[de en es fr it ja ko pt zh-Hans].freeze

# Keep this intentionally narrow. A value identical to its lookup key normally
# means a missing translation was hidden by an explicit self-value. Add only
# reviewed product terms here. Tests may extend it through the environment.
RAW_KEY_SELF_VALUE_ALLOWLIST = Set.new.freeze

resources_dir = Pathname(ENV.fetch("LOCALIZATION_VALIDATOR_RESOURCES_DIR"))
source_dir = Pathname(ENV.fetch("LOCALIZATION_VALIDATOR_SOURCE_DIR"))
skip_source_scan =
  ENV.fetch("LOCALIZATION_VALIDATOR_SKIP_SOURCE_SCAN", "0") == "1"
self_value_allowlist = RAW_KEY_SELF_VALUE_ALLOWLIST.dup
fixture_self_values =
  ENV.fetch("LOCALIZATION_SELF_VALUE_ALLOWLIST", "")
    .split(",")
    .map(&:strip)
    .reject(&:empty?)
unless fixture_self_values.empty? || skip_source_scan
  warn(
    "LOCALIZATION_SELF_VALUE_ALLOWLIST is fixture-only and requires " \
    "LOCALIZATION_SKIP_SOURCE_SCAN=1"
  )
  exit 1
end
self_value_allowlist.merge(fixture_self_values)

errors = []

def strip_comments(text)
  output = +""
  index = 0
  state = :normal
  while index < text.length
    character = text[index]
    following = text[index + 1]
    case state
    when :normal
      if character == '"'
        output << character
        state = :string
      elsif character == "/" && following == "*"
        output << "  "
        index += 1
        state = :block_comment
      elsif character == "/" && following == "/"
        output << "  "
        index += 1
        state = :line_comment
      else
        output << character
      end
    when :string
      output << character
      if character == "\\"
        if following
          output << following
          index += 1
        end
      elsif character == '"'
        state = :normal
      end
    when :block_comment
      if character == "*" && following == "/"
        output << "  "
        index += 1
        state = :normal
      else
        output << (character == "\n" ? "\n" : " ")
      end
    when :line_comment
      if character == "\n"
        output << "\n"
        state = :normal
      else
        output << " "
      end
    end
    index += 1
  end
  output
end

def decoded_assignment_keys(path)
  uncommented = strip_comments(path.read)
  uncommented.scan(/"((?:\\.|[^"\\])*)"\s*=/m).flatten.map do |encoded|
    # Localization keys in this project are ASCII. JSON decoding also makes
    # escaped quotes/backslashes compare by their actual value in fixtures.
    JSON.parse(%("#{encoded}"))
  rescue JSON::ParserError
    encoded
  end
end

def load_catalog(path)
  stdout, stderr, status =
    Open3.capture3("plutil", "-convert", "json", "-o", "-", path.to_s)
  raise "plutil conversion failed for #{path}: #{stderr}" unless status.success?

  JSON.parse(stdout)
end

def placeholder_signature(value)
  placeholders = []
  implicit_position = 1
  position_style = nil
  index = 0

  while index < value.length
    unless value[index] == "%"
      index += 1
      next
    end

    if value[index + 1] == "%"
      index += 2
      next
    end

    candidate = value[index..]
    match = candidate.match(
      /\A%(?:(\d+)\$|)[-+#0']*(?:\d+|)(?:\.\d+|)(hh|h|ll|l|q|L|z|t|j|)([@diuoxXfFeEgGaAcCsSp])/
    )
    unless match
      index += 1
      next
    end

    explicit_position = match[1]&.to_i
    current_style = explicit_position ? :explicit : :implicit
    if position_style && position_style != current_style
      return { error: "mixes positional and non-positional placeholders" }
    end
    position_style = current_style

    argument_position = explicit_position || implicit_position
    implicit_position += 1 unless explicit_position
    placeholders << [argument_position, "#{match[2]}#{match[3]}"]
    index += match[0].length
  end

  { signature: placeholders.sort }
end

catalogs = {}
EXPECTED_LOCALES.each do |locale|
  path = resources_dir.join("#{locale}.lproj", "Localizable.strings")
  begin
    assignment_keys = decoded_assignment_keys(path)
    key_counts = Hash.new(0)
    assignment_keys.each { |key| key_counts[key] += 1 }
    duplicate_keys =
      key_counts.select { |_key, count| count > 1 }.keys.sort
    duplicate_keys.each do |key|
      errors << "#{locale}: duplicate localization key #{key.inspect}"
    end
    catalogs[locale] = load_catalog(path)
  rescue StandardError => error
    errors << "#{locale}: #{error.message}"
  end
end

base = catalogs["en"] || {}
base_keys = base.keys.to_set

EXPECTED_LOCALES.each do |locale|
  catalog = catalogs[locale] || {}
  keys = catalog.keys.to_set

  (base_keys - keys).sort.each do |key|
    errors << "#{locale}: missing key #{key.inspect}"
  end
  (keys - base_keys).sort.each do |key|
    errors << "#{locale}: extra key #{key.inspect}"
  end

  catalog.sort.each do |key, value|
    unless value.is_a?(String)
      errors << "#{locale}: value for #{key.inspect} is not a string"
      next
    end
    errors << "#{locale}: empty value for #{key.inspect}" if value.strip.empty?
    if value == key && !self_value_allowlist.include?(key)
      errors << "#{locale}: raw-key self-value for #{key.inspect} is not allowlisted"
    end

    signature = placeholder_signature(value)
    if signature[:error]
      errors << "#{locale}: #{key.inspect} #{signature[:error]}"
      next
    end
    next if locale == "en" || !base.key?(key)

    base_signature = placeholder_signature(base.fetch(key))
    if signature[:signature] != base_signature[:signature]
      errors <<
        "#{locale}: placeholder signature mismatch for #{key.inspect}; " \
        "expected #{base_signature[:signature].inspect}, " \
        "found #{signature[:signature].inspect}"
    end
  end
end

unless skip_source_scan
  unless source_dir.directory?
    errors << "Swift source directory not found: #{source_dir}"
  else
    call_sites = Hash.new { |hash, key| hash[key] = Set.new }
    swift_files = source_dir.glob("**/*.swift").sort

    swift_files.each do |path|
      source = path.read
      relative_path =
        path.relative_path_from(source_dir.parent).to_s

      patterns = [
        /"([A-Za-z0-9][A-Za-z0-9_.-]+)"\s*\.localized\b/,
        /NSLocalizedString\s*\(\s*"([A-Za-z0-9][A-Za-z0-9_.-]+)"/m,
        /ProviderUILocalization\s*\.\s*text\s*\(\s*"([A-Za-z0-9][A-Za-z0-9_.-]+)"/m,
        /NormalizedUsageStrings\s*\.\s*(?:localized|formatted)\s*\(\s*"([A-Za-z0-9][A-Za-z0-9_.-]+)"/m,
        /Bundle\s*\.\s*main\s*\.\s*localizedString\s*\(\s*forKey:\s*"([A-Za-z0-9][A-Za-z0-9_.-]+)"/m,
        /(?:titleKey|explanationKey|localizationKey):\s*"([A-Za-z0-9][A-Za-z0-9_.-]+)"/
      ]

      # Some views wrap ProviderUILocalization.text in a local two-argument
      # text(_:_:). Scan those literal wrapper call sites as well.
      if source.match?(
        /ProviderUILocalization\s*\.\s*text\s*\(\s*key\s*,\s*fallback:\s*fallback\s*\)/m
      )
        patterns << /\btext\s*\(\s*"([A-Za-z0-9][A-Za-z0-9_.-]+)"\s*,/m
      end

      # Normalized notices intentionally carry their key until rendering.
      if path.basename.to_s == "NormalizedUsageView.swift"
        patterns << /\bkey:\s*"(popover\.normalized\.[A-Za-z0-9_.-]+)"/
      end

      patterns.each do |pattern|
        source.to_enum(:scan, pattern).each do
          key = Regexp.last_match(1)
          line = source[0...Regexp.last_match.begin(1)].count("\n") + 1
          call_sites[key] << "#{relative_path}:#{line}"
        end
      end
    end

    (call_sites.keys.to_set - base_keys).sort.each do |key|
      errors <<
        "en: source localization key #{key.inspect} is absent; " \
        "used at #{call_sites.fetch(key).to_a.sort.join(', ')}"
    end
  end
end

if errors.empty?
  puts(
    "Localization validation passed: " \
    "#{EXPECTED_LOCALES.length} locales, #{base_keys.length} unique keys."
  )
  exit 0
end

warn "Localization validation failed with #{errors.length} issue(s):"
errors.each { |error| warn "  - #{error}" }
exit 1
RUBY
