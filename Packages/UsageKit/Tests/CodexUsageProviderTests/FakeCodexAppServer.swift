import CodexUsageProvider
import Foundation

final class FakeCodexAppServer {
    let client: CodexAppServerClient
    let directoryURL: URL

    init(
        scenario: String,
        limits: CodexTransportLimits? = nil,
        additionalEnvironment: [String: String] = [:],
        codexHomeURL: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexUsageProviderTests-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )

        guard let fixtureURL = Bundle.module.url(
            forResource: "fake-codex-app-server",
            withExtension: "sh",
            subdirectory: "Fixtures"
        ) else {
            throw FakeServerError.fixtureMissing
        }
        let executableURL = directoryURL.appendingPathComponent("fake-app-server")
        try fileManager.copyItem(at: fixtureURL, to: executableURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )

        var environment = additionalEnvironment
        environment["TEST_SCENARIO"] = scenario
        let configuredCodexHomeURL = codexHomeURL ?? directoryURL
        if scenario == "environment" {
            environment["EXPECTED_CODEX_HOME"] =
                configuredCodexHomeURL.resolvingSymlinksInPath().path
        }
        let configuration = try CodexProcessConfiguration(
            executableURL: executableURL,
            arguments: [],
            environment: environment,
            codexHomeURL: configuredCodexHomeURL,
            workingDirectoryURL: directoryURL
        )
        client = CodexAppServerClient(
            processConfiguration: configuration,
            limits: try limits ?? CodexTransportLimits()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    enum FakeServerError: Error {
        case fixtureMissing
    }
}
