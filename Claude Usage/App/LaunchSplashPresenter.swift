//
//  LaunchSplashPresenter.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-14.
//

import AppKit
import SwiftUI

/// Brief branded card shown when the app starts with setup already complete,
/// so a menu-bar-only launch is never silent: the logo and "Running in the
/// menu bar" appear centered for a moment, then fade out on their own.
///
/// Menu-bar apps that skip this leave users staring at a Finder window
/// wondering whether the double-click did anything. The card is a
/// non-activating floating panel — it never steals focus, a click dismisses
/// it immediately, and reopening the app (double-clicking it while it is
/// already running) shows it again.
final class LaunchSplashPresenter {
    static let shared = LaunchSplashPresenter()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show() {
        dismiss(animated: false)

        let hosting = NSHostingController(
            rootView: LaunchSplashView { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isReleasedWhenClosed = false
        panel.isMovable = false

        let size = hosting.view.fittingSize
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            // Slightly above center, like macOS's own HUD panels.
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - size.width / 2,
                    y: frame.midY - size.height / 2 + frame.height * 0.12
                )
            )
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.5
                    panel.animator().alphaValue = 0
                },
                completionHandler: {
                    panel.close()
                }
            )
        } else {
            panel.close()
        }
    }
}

private struct LaunchSplashView: View {
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image("WizardLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            Text("app.name".localized)
                .font(.system(size: 22, weight: .semibold))
            Text("launch.splash.running".localized)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
        )
        .onTapGesture(perform: onTap)
    }
}
