//
//  GhosttyInjector.swift
//  ClaudeIsland
//
//  Sends user text to a Ghostty terminal hosting a Claude session.
//  Uses Ghostty 1.3+ AppleScript dictionary: `input text "..." to terminal`.
//  Verified at ghostty commit 67b5783b — `input text` calls
//  `surface.completeClipboardPaste(text, true)`, i.e. the Cmd+V path,
//  so we get bracketed paste, multi-line preservation, and no leading
//  '/' '!' '#' mode-switch hazards for free.
//

import AppKit
import Foundation
import os.log

struct GhosttyInjector: MessageInjector {
    let displayName = "ghostty"

    /// Verified bundle id (locally checked 2026-04-26). If Ghostty rebrands,
    /// update this constant — `canInject` short-circuits when the app isn't
    /// running, so a stale id silently disables the backend.
    private let ghosttyBundleId = "com.mitchellh.ghostty"

    func canInject(into session: SessionState) async -> Bool {
        guard !session.cwd.isEmpty else { return false }
        guard isGhosttyRunning() else { return false }

        let normalized = Self.normalize(cwd: session.cwd)
        return await MainActor.run { (try? probeMatchingTerminal(cwd: normalized)) ?? false }
    }

    func inject(_ text: String, into session: SessionState) async -> Bool {
        let normalized = Self.normalize(cwd: session.cwd)
        let escapedText = AppleScriptRunner.escape(text)
        let escapedCwd = AppleScriptRunner.escape(normalized)

        let script = """
        tell application id "\(ghosttyBundleId)"
            set targets to every terminal whose working directory is equal to "\(escapedCwd)"
            if (count of targets) is 0 then
                return false
            end if
            input text "\(escapedText)" to item 1 of targets
            return true
        end tell
        """

        let started = Date()
        do {
            let result = try await MainActor.run { try AppleScriptRunner.run(script) }
            let ok = result.booleanValue
            let dur = Date().timeIntervalSince(started)
            injectLogger.info(
                "ghostty inject \(session.sessionId.prefix(8), privacy: .public) \(text.count, privacy: .public)b ok=\(ok, privacy: .public) \(String(format: "%.2f", dur), privacy: .public)s"
            )
            return ok
        } catch AppleScriptError.permissionDenied {
            injectLogger.error(
                "ghostty inject TCC denied for \(session.sessionId.prefix(8), privacy: .public) — automation permission missing"
            )
            return false
        } catch {
            injectLogger.error(
                "ghostty inject failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Internals

    private func isGhosttyRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == ghosttyBundleId }
    }

    /// Lightweight existence probe — returns true iff Ghostty has at least
    /// one terminal whose working directory matches `cwd`.
    @MainActor
    private func probeMatchingTerminal(cwd: String) throws -> Bool {
        let escapedCwd = AppleScriptRunner.escape(cwd)
        let script = """
        tell application id "\(ghosttyBundleId)"
            return (count of (every terminal whose working directory is equal to "\(escapedCwd)")) > 0
        end tell
        """
        do {
            let result = try AppleScriptRunner.run(script)
            return result.booleanValue
        } catch AppleScriptError.permissionDenied {
            // Until automation permission is granted we cannot answer the
            // question. Return false so the registry falls through to tmux;
            // the actual permission prompt fires at first inject.
            return false
        }
    }

    /// Normalize a cwd so equality matches Ghostty's `working directory`
    /// representation. We standardize the path (resolves `..`, removes the
    /// trailing slash for non-root paths) but DO NOT resolve symlinks —
    /// Ghostty itself reports the unresolved path.
    static func normalize(cwd: String) -> String {
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        let path = url.path
        // standardizedFileURL doesn't strip a trailing slash on macOS; do it
        // manually unless the path IS the root.
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }
}
