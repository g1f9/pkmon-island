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
//  Surface selection — two paths depending on installed Ghostty version:
//
//    * Ghostty post-v1.3.1 (PR ghostty-org/ghostty#11922, merged 2026-04-20):
//      `terminal` exposes `tty` and `pid` properties. We filter by
//      `tty == "/dev/<session.tty>"` for a deterministic single-surface
//      match. No more cwd-collision ambiguity.
//
//    * Ghostty <= v1.3.1 (no tty/pid in sdef): legacy heuristic — filter
//      by `working directory`, then if multiple terminals share the cwd,
//      narrow by `name contains <conversation summary>`. We deliberately
//      do NOT fall back to projectName as a hint because a neighboring
//      shell with a path-style prompt title leaks the project basename.
//      Multi-match with no usable hint returns false (UI disables input)
//      rather than gamble on a misroute.
//
//  Capability is probed lazily on first `canInject` and cached once
//  observed true. Users on the legacy path get auto-upgraded the next
//  Vibe Notch launch after they upgrade Ghostty.
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
        let prefix = session.sessionId.prefix(8)
        guard !session.cwd.isEmpty else {
            injectLogger.info("ghostty canInject \(prefix, privacy: .public): empty cwd")
            return false
        }
        guard isGhosttyRunning() else {
            injectLogger.info("ghostty canInject \(prefix, privacy: .public): app not running")
            return false
        }

        return await MainActor.run {
            // Remote session: surface lookup goes through
            // GhosttySurfaceMatcher (ssh-child detection per ps -t).
            // The Ghostty surface that owns the user's interactive
            // ssh tab to this host is the same surface where claude
            // is running on the remote pty — bytes injected there
            // get forwarded back over the user's interactive SSH.
            if case .remote(let hostName) = session.host {
                guard let host = RemoteHostRegistry.shared.hosts.first(where: { $0.name == hostName }) else {
                    injectLogger.info("ghostty canInject \(prefix, privacy: .public): remote host \(hostName, privacy: .public) not in registry")
                    return false
                }
                guard let tty = GhosttySurfaceMatcher.matchingTty(for: session, host: host) else {
                    injectLogger.info("ghostty canInject \(prefix, privacy: .public): no Ghostty surface owns ssh-to-\(hostName, privacy: .public)")
                    return false
                }
                let ttyPath = "/dev/\(tty)"
                do {
                    let matched = try probeByTty(ttyPath)
                    injectLogger.info(
                        "ghostty canInject \(prefix, privacy: .public): remote=\(hostName, privacy: .public) tty=\(ttyPath, privacy: .public) match=\(matched, privacy: .public)"
                    )
                    return matched
                } catch AppleScriptError.permissionDenied {
                    injectLogger.error(
                        "ghostty canInject \(prefix, privacy: .public): TCC permission denied — grant in System Settings → Privacy & Security → Automation"
                    )
                    return false
                } catch {
                    injectLogger.error(
                        "ghostty canInject \(prefix, privacy: .public): remote probe error \(error.localizedDescription, privacy: .public)"
                    )
                    return false
                }
            }

            GhosttyTtyCapability.probeIfNeeded(bundleId: ghosttyBundleId)
            do {
                if GhosttyTtyCapability.isSupported, let ttyPath = Self.ttyPath(for: session) {
                    let matched = try probeByTty(ttyPath)
                    injectLogger.info(
                        "ghostty canInject \(prefix, privacy: .public): tty=\(ttyPath, privacy: .public) match=\(matched, privacy: .public)"
                    )
                    return matched
                }
                let normalized = Self.normalize(cwd: session.cwd)
                let hint = Self.titleHint(for: session)
                let matched = try probeByCwd(cwd: normalized, hint: hint)
                injectLogger.info(
                    "ghostty canInject \(prefix, privacy: .public): legacy cwd=\(normalized, privacy: .public) hint=\(hint ?? "<none>", privacy: .public) match=\(matched, privacy: .public)"
                )
                return matched
            } catch AppleScriptError.permissionDenied {
                injectLogger.error(
                    "ghostty canInject \(prefix, privacy: .public): TCC permission denied — grant in System Settings → Privacy & Security → Automation"
                )
                return false
            } catch {
                injectLogger.error(
                    "ghostty canInject \(prefix, privacy: .public): probe error \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        }
    }

    func inject(_ text: String, into session: SessionState) async -> Bool {
        let escapedText = AppleScriptRunner.escape(text)

        // Submit semantics — applies to all selection paths:
        //   1. Paste via bracketed paste (Cmd+V code path — `/`, `!`, `#`,
        //      embedded newlines all stay literal).
        //   2. Fire `send key "enter"` TWICE. A single synthetic Enter only
        //      stages the text in Claude/Ink's input field — the first one
        //      gets swallowed during bracketed-paste finalization.
        //   The IME-friendly path: `keybind = enter=text:\\r` would let one
        //   Enter submit, but intercepts Enter before macOS IME (Ghostty
        //   Discussion #9264). System Events + activate works but yanks
        //   Ghostty to the front, dismissing the Vibe Notch panel.

        // Resolve the Ghostty surface tty. Remote sessions go through
        // GhosttySurfaceMatcher; local sessions use the existing tty/
        // cwd paths.
        let script: String
        let pathName: String
        if case .remote(let hostName) = session.host {
            let resolved: String? = await MainActor.run {
                guard let host = RemoteHostRegistry.shared.hosts.first(where: { $0.name == hostName }),
                      let tty = GhosttySurfaceMatcher.matchingTty(for: session, host: host) else {
                    return nil
                }
                return "/dev/\(tty)"
            }
            guard let ttyPath = resolved else {
                injectLogger.warning("ghostty inject \(session.sessionId.prefix(8), privacy: .public): no remote tty match for \(hostName, privacy: .public)")
                return false
            }
            script = injectScriptByTty(ttyPath: ttyPath, escapedText: escapedText)
            pathName = "remote-tty"
        } else if GhosttyTtyCapability.isSupported, let ttyPath = Self.ttyPath(for: session) {
            script = injectScriptByTty(ttyPath: ttyPath, escapedText: escapedText)
            pathName = "tty"
        } else {
            let normalized = Self.normalize(cwd: session.cwd)
            let hint = Self.titleHint(for: session)
            script = injectScriptByCwd(cwd: normalized, hint: hint, escapedText: escapedText)
            pathName = "cwd"
        }

        let started = Date()
        do {
            let result = try await MainActor.run { try AppleScriptRunner.run(script) }
            let ok = result.booleanValue
            let dur = Date().timeIntervalSince(started)
            injectLogger.info(
                "ghostty inject \(session.sessionId.prefix(8), privacy: .public) via=\(pathName, privacy: .public) \(text.count, privacy: .public)b ok=\(ok, privacy: .public) \(String(format: "%.2f", dur), privacy: .public)s"
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

    /// tty-path probe: returns true iff exactly one Ghostty surface reports
    /// the requested tty. With PR #11922 each surface has a unique tty, so
    /// "exactly one" is the only correct answer — anything else means the
    /// session has gone away or moved.
    @MainActor
    private func probeByTty(_ ttyPath: String) throws -> Bool {
        let escapedTty = AppleScriptRunner.escape(ttyPath)
        let script = """
        tell application id "\(ghosttyBundleId)"
            return (count of (every terminal whose tty is equal to "\(escapedTty)")) is 1
        end tell
        """
        return try AppleScriptRunner.run(script).booleanValue
    }

    /// Legacy cwd+hint probe. Same uniqueness contract as `injectScriptByCwd`.
    /// Returns true iff there is exactly one terminal we can route to:
    ///   - precisely one cwd-matching terminal, or
    ///   - multiple cwd-matching terminals, with `hint` non-nil, and only
    ///     one of them also has `name contains hint`.
    /// When multi-match and hint is nil, returns false so the UI disables
    /// the input rather than gambling on a misroute. Throws on AppleScript
    /// errors (including TCC denial).
    @MainActor
    private func probeByCwd(cwd: String, hint: String?) throws -> Bool {
        let escapedCwd = AppleScriptRunner.escape(cwd)
        let multiMatchExpr: String
        if let hint = hint {
            let escapedHint = AppleScriptRunner.escape(hint)
            multiMatchExpr = """
            set hintTargets to every terminal whose working directory is equal to "\(escapedCwd)" and name contains "\(escapedHint)"
            return (count of hintTargets) is 1
            """
        } else {
            multiMatchExpr = "return false"
        }
        let script = """
        tell application id "\(ghosttyBundleId)"
            set cwdTargets to every terminal whose working directory is equal to "\(escapedCwd)"
            set matchCount to count of cwdTargets
            if matchCount is 0 then
                return false
            end if
            if matchCount is 1 then
                return true
            end if
            \(multiMatchExpr)
        end tell
        """
        return try AppleScriptRunner.run(script).booleanValue
    }

    private func injectScriptByTty(ttyPath: String, escapedText: String) -> String {
        let escapedTty = AppleScriptRunner.escape(ttyPath)
        return """
        tell application id "\(ghosttyBundleId)"
            set targets to every terminal whose tty is equal to "\(escapedTty)"
            if (count of targets) is not 1 then
                return false
            end if
            set t to item 1 of targets
            input text "\(escapedText)" to t
            delay 0.05
            send key "enter" to t
            delay 0.05
            send key "enter" to t
            return true
        end tell
        """
    }

    private func injectScriptByCwd(cwd: String, hint: String?, escapedText: String) -> String {
        let escapedCwd = AppleScriptRunner.escape(cwd)
        let multiMatchClause: String
        if let hint = hint {
            let escapedHint = AppleScriptRunner.escape(hint)
            multiMatchClause = """
                set hintTargets to every terminal whose working directory is equal to "\(escapedCwd)" and name contains "\(escapedHint)"
                if (count of hintTargets) is not 1 then
                    return false
                end if
                set t to item 1 of hintTargets
            """
        } else {
            multiMatchClause = "return false"
        }
        return """
        tell application id "\(ghosttyBundleId)"
            set cwdTargets to every terminal whose working directory is equal to "\(escapedCwd)"
            set matchCount to count of cwdTargets
            if matchCount is 0 then
                return false
            end if
            if matchCount is 1 then
                set t to item 1 of cwdTargets
            else
                \(multiMatchClause)
            end if
            input text "\(escapedText)" to t
            delay 0.05
            send key "enter" to t
            delay 0.05
            send key "enter" to t
            return true
        end tell
        """
    }

    /// `/dev/`-prefixed tty for matching against Ghostty's `tty` AppleScript
    /// property. SessionStore strips `/dev/` when storing — see
    /// `SessionStore.swift:140` and `:204` — so we re-add it here.
    /// Returns nil if the session has no recorded tty yet (hooks haven't
    /// fired) — falls through to the legacy cwd path.
    static func ttyPath(for session: SessionState) -> String? {
        guard let tty = session.tty, !tty.isEmpty else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// The disambiguation hint for a Ghostty surface match in legacy mode.
    /// We only trust the conversation summary — Claude CLI writes it into
    /// the terminal title via OSC 0/2, so a non-empty summary uniquely
    /// fingerprints a Claude surface. We deliberately do NOT fall back to
    /// projectName: a shell prompt title like "~/Code/<projectName>" would
    /// false-match. Returns nil when no usable summary exists (caller
    /// treats nil as "fail closed on multi-match").
    static func titleHint(for session: SessionState) -> String? {
        guard let summary = session.conversationInfo.summary else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

/// One-shot probe for whether the running Ghostty version exposes the `tty`
/// AppleScript property (PR ghostty-org/ghostty#11922, merged 2026-04-20,
/// post v1.3.1). The capability is monotonic for a Ghostty process — once
/// observed it stays — so we cache `true` aggressively. Negative results
/// don't cache (could be a transient "no terminals open" or TCC issue),
/// so we keep retrying on each call until we observe support or never do.
@MainActor
private enum GhosttyTtyCapability {
    private static var cachedSupported = false

    static var isSupported: Bool { cachedSupported }

    static func probeIfNeeded(bundleId: String) {
        if cachedSupported { return }
        let script = """
        tell application id "\(bundleId)"
            if (count of terminals) is 0 then return false
            try
                set ttyVal to tty of (first terminal)
                if ttyVal starts with "/dev/" then return true
                return false
            on error
                return false
            end try
        end tell
        """
        do {
            if try AppleScriptRunner.run(script).booleanValue {
                cachedSupported = true
                injectLogger.info("ghostty: tty AppleScript property detected — using deterministic surface match")
            }
        } catch {
            // Ignore errors here. TCC denial / app-not-running surfaces in
            // the actual canInject path with proper logging; we don't want
            // to spam.
        }
    }
}
