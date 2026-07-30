func fixturePresentLocalizationCalls() {
    _ = "fixture.plain".localized
    _ = NSLocalizedString("fixture.plain", comment: "")
    _ = ProviderUILocalization.text("fixture.plain", fallback: "Fallback")
    _ = NormalizedUsageStrings.localized("fixture.plain", default: "Fallback")
    _ = NormalizedUsageStrings.formatted(
        "fixture.plain",
        default: "Fallback",
        arguments: []
    )
    _ = Bundle.main.localizedString(
        forKey: "fixture.plain",
        value: "Fallback",
        table: nil
    )
    _ = (
        titleKey: "fixture.plain",
        explanationKey: "fixture.plain",
        localizationKey: "fixture.plain"
    )
    _ = text("fixture.plain", "Fallback")
}

func text(_ key: String, _ fallback: String) -> String {
    ProviderUILocalization
        .text(
            key,
            fallback: fallback
        )
}
