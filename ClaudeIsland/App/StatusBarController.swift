//
//  StatusBarController.swift
//  ClaudeIsland
//
//  Status-bar (menu-bar) presentation mode.
//  Shows a small crab icon in the macOS menu bar with a red count badge
//  whenever sessions are waiting for permission approval. Click reveals an
//  NSPopover hosting the same SwiftUI session list / chat surface used by
//  the notch overlay.
//

import AppKit
import Combine
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "StatusBar")

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let sessionMonitor: ClaudeSessionMonitor
    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    init(sessionMonitor: ClaudeSessionMonitor) {
        self.sessionMonitor = sessionMonitor
        // Geometry is irrelevant in popover mode — pass zero rects.
        // Mouse-based open/close in NotchViewModel won't fire because the
        // mouse can never be inside a zero-width rect.
        self.viewModel = NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: .zero,
            windowHeight: 0,
            hasPhysicalNotch: false
        )
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configurePopover()
        configureButton()
        observeSessions()
        logger.info("StatusBarController ready")
    }

    func tearDown() {
        if popover.isShown { popover.performClose(nil) }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Setup

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(
            rootView: StatusBarPopoverView(
                sessionMonitor: sessionMonitor,
                viewModel: viewModel
            )
        )
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 360, height: 460)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            logger.error("statusItem.button is nil — system rejected the request")
            return
        }
        if let image = Self.renderCrabImage() {
            button.image = image
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            // Fallback so the item never collapses to 0 width.
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(
                string: "VN",
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]
            )
        }
        button.target = self
        button.action = #selector(togglePopover(_:))
        statusItem.isVisible = true
    }

    /// Rasterise the pixel-art crab as a flat white silhouette marked as a
    /// template image so macOS auto-tints it to match every other menu-bar
    /// icon (white on dark menu bars, black on light ones).
    private static func renderCrabImage() -> NSImage? {
        let renderer = ImageRenderer(content: ClaudeCrabIcon(size: 16, color: .white))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }

    private func observeSessions() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateBadge(from: sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Badge

    private func updateBadge(from sessions: [SessionState]) {
        guard let button = statusItem.button else { return }
        let count = sessions.filter { $0.phase.isWaitingForApproval }.count
        if count > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(count)",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold)
                ]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Actions

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // popover.behavior = .transient already dismisses on outside click.
    }
}
