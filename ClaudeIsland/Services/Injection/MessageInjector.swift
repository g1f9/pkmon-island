//
//  MessageInjector.swift
//  ClaudeIsland
//
//  Abstraction for sending user text into a running Claude session.
//  Backends: Ghostty (AppleScript), Tmux (paste-buffer).
//  This is a SEPARATE channel from approvals — approvals still go
//  through HookSocketServer's open Unix socket.
//

import Foundation
import os.log

let injectLogger = Logger(subsystem: "com.claudeisland", category: "Inject")

protocol MessageInjector: Sendable {
    /// Stable identifier used in logs and UI ("ghostty", "tmux").
    var displayName: String { get }

    /// Whether this backend can currently route text to the given session.
    func canInject(into session: SessionState) async -> Bool

    /// Inject `text` into the session. Returns true if the backend accepted
    /// the request — does NOT mean Claude has dispatched it; that is
    /// confirmed independently when the JSONL UserPromptSubmit event lands.
    func inject(_ text: String, into session: SessionState) async -> Bool
}

@MainActor
final class MessageInjectorRegistry {
    static let shared = MessageInjectorRegistry()

    /// Highest priority first. Ghostty's path is preferred because it does
    /// not require tmux and uses the native paste flow.
    private let injectors: [any MessageInjector]

    private init() {
        self.injectors = [
            GhosttyInjector(),
            TmuxInjector(),
        ]
    }

    /// Returns the first injector that reports it can handle the session.
    /// Nil means "panel should disable the input bar".
    func resolve(for session: SessionState) async -> (any MessageInjector)? {
        for injector in injectors {
            if await injector.canInject(into: session) {
                return injector
            }
        }
        return nil
    }
}
