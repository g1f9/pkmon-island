//
//  StatusBarPopoverView.swift
//  ClaudeIsland
//
//  SwiftUI content for the status-bar mode's popover. Mirrors the notch's
//  in-panel content (instance list / chat / settings) so the user can drive
//  the same flows from the menu bar.
//

import SwiftUI

struct StatusBarPopoverView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    /// Vibe Notch's pixel-crab brand orange — used throughout the menu-bar
    /// popover to signal we're in the "app surface" rather than the system
    /// menu bar's neutral chrome.
    private let crabOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().background(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 360, height: 460)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if showsBackButton {
                Button {
                    viewModel.exitChat()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ClaudeCrabIcon(size: 14, color: crabOrange)
                    .padding(.leading, 4)
            }

            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

            Spacer()

            if !showsBackButton {
                Button {
                    viewModel.toggleMenu()
                } label: {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var showsBackButton: Bool {
        if case .chat = viewModel.contentType { return true }
        return false
    }

    private var headerTitle: String {
        switch viewModel.contentType {
        case .instances: return "Sessions"
        case .menu: return "Settings"
        case .chat(let session): return session.projectName
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.contentType {
        case .instances:
            ClaudeInstancesView(sessionMonitor: sessionMonitor, viewModel: viewModel)
        case .chat(let session):
            ChatView(
                sessionId: session.sessionId,
                initialSession: session,
                sessionMonitor: sessionMonitor,
                viewModel: viewModel
            )
            .id(session.sessionId)
        case .menu:
            NotchMenuView(viewModel: viewModel)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                AppSettings.displayMode = .notch
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 11, weight: .medium))
                    Text("Show in Island")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
