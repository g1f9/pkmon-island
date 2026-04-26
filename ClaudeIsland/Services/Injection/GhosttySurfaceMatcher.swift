//
//  GhosttySurfaceMatcher.swift
//  ClaudeIsland
//
//  Maps a remote SessionState (host = .remote(name:)) to the local
//  Ghostty surface tty that owns the SSH process talking to that host.
//
//  Local sessions don't go through this — they use the existing
//  GhosttyTtyCapability path with deterministic tty matching.
//

import Foundation
import os.log

private let matcherLogger = Logger(subsystem: "com.claudeisland", category: "Inject")

@MainActor
enum GhosttySurfaceMatcher {
    /// For a remote session, return the local Ghostty surface tty (e.g.
    /// "ttys005" — no /dev/ prefix) that owns an `ssh` child whose
    /// command line contains `host.sshTarget` or `host.name`.
    /// Returns nil if no match or if multiple surfaces match (ambiguous —
    /// safer to disable injection than to misroute).
    static func matchingTty(for session: SessionState, host: RemoteHost) -> String? {
        guard session.host == .remote(name: host.name) else { return nil }

        let ghosttyTtys = listGhosttyTtys()
        var matches: [String] = []
        for tty in ghosttyTtys {
            if hasSSHChild(tty: tty, target: host.sshTarget, alias: host.name) {
                matches.append(tty)
            }
        }
        switch matches.count {
        case 0:
            matcherLogger.info("ghostty surface match: no ssh-to-\(host.name, privacy: .public) found")
            return nil
        case 1:
            matcherLogger.info("ghostty surface match: \(matches[0], privacy: .public) owns ssh-to-\(host.name, privacy: .public)")
            return matches[0]
        default:
            matcherLogger.info("ghostty surface match: \(matches.count, privacy: .public) surfaces own ssh-to-\(host.name, privacy: .public); ambiguous, refusing")
            return nil
        }
    }

    // MARK: - AppleScript: enumerate Ghostty surfaces

    private static func listGhosttyTtys() -> [String] {
        let script = """
        tell application "Ghostty"
            set ttys to {}
            repeat with t in (every terminal)
                try
                    set end of ttys to (tty of t as string)
                end try
            end repeat
            set AppleScript's text item delimiters to ","
            return ttys as string
        end tell
        """
        do {
            let result = try AppleScriptRunner.run(script)
            let raw = result.stringValue ?? ""
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/dev/", with: "") }
                .filter { !$0.isEmpty }
        } catch AppleScriptError.permissionDenied {
            matcherLogger.warning("Ghostty tty enumeration: TCC permission denied")
            return []
        } catch {
            matcherLogger.warning("Ghostty tty enumeration failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Process tree probe

    private static func hasSSHChild(tty: String, target: String, alias: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", tty, "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        // readToEnd() returns Data?; try? wraps it in another Optional.
        // flatMap collapses both layers down to Data?, then ?? defaults
        // to an empty Data on either nil source.
        let data = (try? pipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
        let out = String(data: data, encoding: .utf8) ?? ""

        for line in out.split(separator: "\n") {
            let s = String(line)
            // A line that starts with "ssh ", contains " ssh " (skipping
            // tools like "rsync" or paths that incidentally contain
            // "ssh"), or contains "/ssh " (e.g. /usr/bin/ssh ...).
            let isSSH = s.hasPrefix("ssh ") || s.contains(" ssh ") || s.contains("/ssh ")
            guard isSSH else { continue }
            if s.contains(target) || s.contains(alias) {
                return true
            }
        }
        return false
    }
}
