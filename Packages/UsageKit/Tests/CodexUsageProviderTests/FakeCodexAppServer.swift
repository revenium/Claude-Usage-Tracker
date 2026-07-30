import CodexUsageProvider
import Foundation

final class FakeCodexAppServer {
    let client: CodexAppServerClient
    let directoryURL: URL
    let requestLogURL: URL
    private let initializationLogURL: URL
    private let processLogURL: URL
    private let pidFileURL: URL

    init(
        scenario: String,
        limits: CodexTransportLimits? = nil,
        additionalEnvironment: [String: String] = [:],
        codexHomeURL: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexUsageProviderTests-\(UUID().uuidString)")
        pidFileURL = directoryURL.appendingPathComponent("process.pid")
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        requestLogURL = directoryURL.appendingPathComponent("requests.jsonl")
        initializationLogURL = directoryURL.appendingPathComponent(
            "initializations.jsonl"
        )
        processLogURL = directoryURL.appendingPathComponent("processes.log")

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
        environment["REQUEST_LOG"] = requestLogURL.path
        environment["INITIALIZATION_LOG"] = initializationLogURL.path
        environment["PROCESS_LOG"] = processLogURL.path
        environment["PID_FILE"] = pidFileURL.path
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

    func recordedRequests() throws -> [CodexRequestFrame] {
        try recordedFrames(at: requestLogURL)
    }

    func recordedInitializations() throws -> [CodexRequestFrame] {
        try recordedFrames(at: initializationLogURL)
    }

    func launchedProcessIdentifiers() throws -> [Int32] {
        guard FileManager.default.fileExists(atPath: processLogURL.path) else {
            return []
        }
        return try String(contentsOf: processLogURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map {
                guard let identifier = Int32($0), identifier > 0 else {
                    throw FakeServerError.invalidProcessLog
                }
                return identifier
            }
    }

    func assertAllProcessesExited(timeout: TimeInterval = 5) async throws {
        for identifier in try launchedProcessIdentifiers() {
            try await assertProcessExited(identifier, timeout: timeout)
        }
    }

    func processIdentifier(
        timeout: TimeInterval = 5
    ) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: pidFileURL),
               let value = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               let identifier = Int32(value),
               identifier > 0
            {
                return identifier
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FakeServerError.pidObservationTimedOut
    }

    func assertProcessExited(
        _ identifier: Int32,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            errno = 0
            if kill(identifier, 0) == -1, errno == ESRCH {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FakeServerError.processStillExists(identifier)
    }

    enum FakeServerError: Error {
        case fixtureMissing
        case invalidProcessLog
        case pidObservationTimedOut
        case processStillExists(Int32)
    }

    private func recordedFrames(at url: URL) throws -> [CodexRequestFrame] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0A).map {
            try JSONDecoder().decode(CodexRequestFrame.self, from: Data($0))
        }
    }
}
