func fixtureMissingLocalizationCalls() {
    _ = "missing.localized".localized
    _ = NSLocalizedString("missing.ns_localized", comment: "")
    _ = ProviderUILocalization
        .text("missing.provider_ui", fallback: "Fallback")
    _ = NormalizedUsageStrings
        .localized("missing.normalized", default: "Fallback")
    _ = NormalizedUsageStrings.formatted(
        "missing.formatted",
        default: "Fallback",
        arguments: []
    )
    _ = Bundle
        .main
        .localizedString(
            forKey: "missing.bundle",
            value: "Fallback",
            table: nil
        )
    _ = (
        titleKey: "missing.title",
        explanationKey: "missing.explanation",
        localizationKey: "missing.carried"
    )
    _ = text(
        "missing.wrapper",
        "Fallback"
    )
}

func text(_ key: String, _ fallback: String) -> String {
    ProviderUILocalization
        .text(
            key,
            fallback: fallback
        )
}
