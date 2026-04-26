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
    private var appearanceObserver: NSKeyValueObservation?
    private var lastState: BadgeState = .idle

    /// What the menu-bar icon currently represents. We render a single composite
    /// NSImage per state with a *fixed outer frame*, so the status item width
    /// never changes — eliminating menu-bar jitter when state transitions.
    private enum BadgeState: Equatable {
        case idle
        case working(Int)
        case approval(Int)
    }

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
        appearanceObserver?.invalidate()
        appearanceObserver = nil
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
        popover.contentSize = viewModel.openedSize

        // Mirror island mode: openedSize switches with contentType
        // (instances / chat / menu) and grows when settings pickers
        // expand. NSPopover.contentSize isn't reactive, so push it
        // whenever the view model publishes a change. SwiftUI inside
        // the popover already reads openedSize for its own .frame().
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let next = self.viewModel.openedSize
                if self.popover.contentSize != next {
                    self.popover.contentSize = next
                }
            }
            .store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            logger.error("statusItem.button is nil — system rejected the request")
            return
        }
        button.target = self
        button.action = #selector(togglePopover(_:))
        statusItem.isVisible = true

        applyState(lastState, on: button)

        // The approval-state image is non-template (mixes red badge with the
        // crab) so we must re-render when the menu-bar appearance flips
        // between light and dark to keep the crab tinted correctly.
        appearanceObserver = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // KVO fires on the main thread for UI properties; assert that and
            // call back into the main-actor-isolated controller synchronously.
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem.button else { return }
                self.applyState(self.lastState, on: button)
            }
        }
    }

    /// Render the crab + a fixed-width badge slot into a single NSImage.
    /// The outer frame is locked to the same dimensions for every state,
    /// guaranteeing the status item width never changes.
    ///
    /// Idle/working states use a template image (system tints to menu-bar
    /// color). Approval state mixes red with the crab so it must be
    /// non-template — the caller picks the crab color based on appearance.
    private static func renderBadgeImage(state: BadgeState, isDark: Bool) -> NSImage? {
        let crabColor: Color
        let isTemplate: Bool
        switch state {
        case .approval:
            crabColor = isDark ? .white : .black
            isTemplate = false
        default:
            crabColor = .white
            isTemplate = true
        }

        let badge: AnyView
        switch state {
        case .idle:
            badge = AnyView(
                Image(systemName: "zzz")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            )
        case .working(let count):
            badge = AnyView(
                Text("·\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.white)
            )
        case .approval(let count):
            badge = AnyView(
                Text("!\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundColor(.red)
            )
        }

        let view = HStack(spacing: 3) {
            ClaudeCrabIcon(size: 14, color: crabColor)
            badge.frame(width: 22, alignment: .leading)
        }
        .frame(width: 42, height: 18, alignment: .leading)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = isTemplate
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
        let approvalCount = sessions.filter { $0.phase.isWaitingForApproval }.count
        let workingCount = sessions.filter { $0.phase.isActive }.count

        // Priority: approvals (urgent) > working (informational) > idle (Zzz).
        // Idle gets a sleeping icon rather than blank space so the badge slot
        // is *always* occupied — image dimensions stay constant, no jitter.
        let next: BadgeState
        if approvalCount > 0 {
            next = .approval(approvalCount)
        } else if workingCount > 0 {
            next = .working(workingCount)
        } else {
            next = .idle
        }
        if next != lastState {
            applyState(next, on: button)
        }
    }

    private func applyState(_ state: BadgeState, on button: NSStatusBarButton) {
        lastState = state
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let image = Self.renderBadgeImage(state: state, isDark: isDark) {
            button.image = image
            button.imagePosition = .imageOnly
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
