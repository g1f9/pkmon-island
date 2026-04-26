//
//  TmuxInjector.swift
//  ClaudeIsland
//
//  Sends user text to a Claude session running inside tmux.
//  Replaces the old `tmux send-keys -l` path which lacked bracketed paste —
//  that caused leading '/' '!' '#' to flip Claude's TUI into a slash/bash/
//  memory mode and embedded newlines to auto-submit.
//
//  Approval keystrokes (1/2/n) are deliberately NOT routed through this
//  path: they live in ToolApprovalHandler and remain `send-keys -l`.
//

import Foundation
import os.log

struct TmuxInjector: MessageInjector {
    let displayName = "tmux"

    private let bufferName = "__pkmon_inject"

    func canInject(into session: SessionState) async -> Bool {
        guard session.isInTmux, let tty = session.tty else { return false }
        return await findTarget(forTty: tty) != nil
    }

    func inject(_ text: String, into session: SessionState) async -> Bool {
        guard let tty = session.tty,
              let target = await findTarget(forTty: tty) else {
            injectLogger.error(
                "tmux inject: no pane for tty \(session.tty ?? "?", privacy: .public)"
            )
            return false
        }
        guard let tmux = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // Stage the text in a temp file so tmux load-buffer can read it
        // without us shell-quoting arbitrary user input.
        let tempPath = NSTemporaryDirectory()
            + "pkmon-inject-\(UUID().uuidString).txt"
        do {
            try text.write(toFile: tempPath, atomically: true, encoding: .utf8)
        } catch {
            injectLogger.error(
                "tmux inject: temp file write failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
        }

        let started = Date()
        do {
            // 1) Load the text from the temp file into a named buffer.
            _ = try await ProcessExecutor.shared.run(
                tmux,
                arguments: ["load-buffer", "-b", bufferName, tempPath]
            )

            // 2) Paste with bracketed-paste flag and delete the buffer after.
            _ = try await ProcessExecutor.shared.run(
                tmux,
                arguments: ["paste-buffer", "-p", "-d", "-b", bufferName, "-t", target.targetString]
            )

            // 3) Press Enter explicitly. Inside bracketed paste the text's
            //    own newlines are inert; we want exactly one submit.
            _ = try await ProcessExecutor.shared.run(
                tmux,
                arguments: ["send-keys", "-t", target.targetString, "Enter"]
            )

            let dur = Date().timeIntervalSince(started)
            injectLogger.info(
                "tmux inject \(session.sessionId.prefix(8), privacy: .public) \(text.count, privacy: .public)b ok=true \(String(format: "%.2f", dur), privacy: .public)s"
            )
            return true
        } catch {
            injectLogger.error(
                "tmux inject failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Internals

    /// Match a Claude session's tty against `tmux list-panes -a` output.
    private func findTarget(forTty tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }
        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )
            for line in output.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")
                if paneTty == tty {
                    return TmuxTarget(from: parts[0])
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
