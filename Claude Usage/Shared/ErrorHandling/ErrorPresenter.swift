//
//  ErrorPresenter.swift
//  Claude Usage - User-Facing Error Presentation
//
//  Created on 2025-12-27.
//

import SwiftUI
import AppKit

@MainActor
struct ProviderRecoveryActionDispatcher {
    let retry: () -> Void
    let openSettings: () -> Void

    @discardableResult
    func perform(_ action: ProviderRecoveryAction) -> Bool {
        switch action {
        case .retry:
            retry()
            return true
        case .openSettings:
            openSettings()
            return true
        case .installOrUpdateCodex:
            return false
        }
    }
}

/// Presents errors to users in a friendly way
class ErrorPresenter {

    static let shared = ErrorPresenter()

    private init() {}

    private enum AlertAction {
        case dismiss
        case recovery(ProviderRecoveryAction)
        case copyErrorCode
    }

    // MARK: - Alert Presentation

    /// Show an error alert to the user
    func showAlert(for error: AppError, in window: NSWindow? = nil) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = error.message
            alert.informativeText = self.buildInformativeText(for: error)
            alert.alertStyle = error.isRecoverable ? .warning : .critical

            var actions: [AlertAction] = [.dismiss]
            alert.addButton(withTitle: "OK")

            let recoveryActions =
                error.recoveryActions.isEmpty
                && (
                    error.code.category == .sessionKey
                        || error.code.category == .api
                )
                ? [.openSettings]
                : error.recoveryActions
            for recoveryAction in recoveryActions {
                alert.addButton(withTitle: recoveryAction.title)
                actions.append(.recovery(recoveryAction))
            }

            alert.addButton(withTitle: "Copy Error Code")
            actions.append(.copyErrorCode)

            // Show alert
            if let window = window {
                alert.beginSheetModal(for: window) { response in
                    self.handleAlertResponse(
                        response,
                        error: error,
                        actions: actions
                    )
                }
            } else {
                let response = alert.runModal()
                self.handleAlertResponse(
                    response,
                    error: error,
                    actions: actions
                )
            }
        }
    }

    private func buildInformativeText(for error: AppError) -> String {
        var text = ""

        if let suggestion = error.recoverySuggestion {
            text += "\(suggestion)\n\n"
        }

        text += "Error Code: \(error.copyableErrorCode)"

        if let details = error.technicalDetails {
            text += "\n\nDetails: \(details)"
        }

        return SensitiveDataRedactor.redact(text)
    }

    private func handleAlertResponse(
        _ response: NSApplication.ModalResponse,
        error: AppError,
        actions: [AlertAction]
    ) {
        let index =
            response.rawValue
            - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard actions.indices.contains(index) else { return }
        switch actions[index] {
        case .dismiss:
            break
        case .copyErrorCode:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(error.copyableErrorCode, forType: .string)
            self.showTooltip("Error code copied to clipboard")
        case .recovery(let action):
            perform(action)
        }
    }

    private func perform(_ action: ProviderRecoveryAction) {
        let dispatcher = ProviderRecoveryActionDispatcher(
            retry: {
                ShortcutManager.shared.onRefresh?()
            },
            openSettings: {
                ShortcutManager.shared.onOpenSettings?()
            }
        )
        if !dispatcher.perform(action) {
            showCodexInstallationGuidance()
        }
    }

    private func showCodexInstallationGuidance() {
        let alert = NSAlert()
        alert.messageText = ProviderUILocalization.text(
            "provider.recovery.codex_help.title",
            fallback: "Install or Update Codex"
        )
        alert.informativeText = ProviderUILocalization.text(
            "provider.recovery.codex_help.explanation",
            fallback:
                "Install or update Codex using the same trusted package manager or installer you normally use, then confirm that “codex --version” succeeds."
        )
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Toast Notifications

    /// Show a brief error toast
    func showToast(for error: AppError) {
        showTooltip("⚠️ \(error.message)")
    }

    private func showTooltip(_ message: String) {
        // For macOS, we can use NSUserNotification or create a custom tooltip window
        // This is a simplified version
        DispatchQueue.main.async {
            // Could implement custom toast window here
            LoggingService.shared.logUIEvent(
                "Toast: \(message)"
            )
        }
    }

    // MARK: - Error Details View

    /// Get a SwiftUI view for error details
    func errorDetailsView(for error: AppError) -> some View {
        ErrorDetailsView(error: error)
    }
}

// MARK: - SwiftUI Error Details View

struct ErrorDetailsView: View {
    let error: AppError

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: iconName)
                    .font(.system(size: 32))
                    .foregroundColor(iconColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(error.message)
                        .font(.headline)

                    Text(error.code.category.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Divider()

            // Error Code
            HStack {
                Text("Error Code:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(error.copyableErrorCode)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Spacer()

                Button(action: copyErrorCode) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }

            // Recovery Suggestion
            if let suggestion = error.recoverySuggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What to do:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(suggestion)
                        .font(.body)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                )
            }

            // Technical Details (collapsible)
            if let details = error.technicalDetails {
                DisclosureGroup("Technical Details") {
                    Text(details)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
            }

            // Timestamp
            Text("Occurred: \(error.timestamp.formatted())")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: 450)
    }

    private var iconName: String {
        if error.isRecoverable {
            return "exclamationmark.triangle.fill"
        } else {
            return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        if error.isRecoverable {
            return .orange
        } else {
            return .red
        }
    }

    private func copyErrorCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(error.copyableErrorCode, forType: .string)
    }
}

// MARK: - Preview

#Preview("Error Details - Recoverable") {
    ErrorDetailsView(
        error: AppError(
            code: .networkTimeout,
            message: "Request timed out",
            technicalDetails: "The server did not respond within 30 seconds",
            isRecoverable: true,
            recoverySuggestion: "Please check your internet connection and try again"
        )
    )
}

#Preview("Error Details - Critical") {
    ErrorDetailsView(
        error: AppError(
            code: .sessionKeyInvalid,
            message: "Invalid session key",
            technicalDetails: "Session key does not match expected format",
            isRecoverable: false,
            recoverySuggestion: "Please obtain a new session key from claude.ai"
        )
    )
}
