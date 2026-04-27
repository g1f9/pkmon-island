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
    ///
    /// When multiple Ghostty surfaces hold an ssh-to-host child (the user
    /// has two `ssh dev` tabs open), we use the conversation summary
    /// from the session as a tie-breaker — claude updates the terminal
    /// title via OSC 0/2, which passes through ssh transparently and
    /// shows up in Ghostty's `name` property. Same idea as the local
    /// cwd-collision tie-breaker in `GhosttyInjector.probeByCwd`.
    static func matchingTty(for session: SessionState, host: RemoteHost) -> String? {
        guard session.host == .remote(name: host.name) else { return nil }

        let surfaces = listGhosttySurfaces()
        // For each Ghostty surface, find the ssh-to-host child (if any)
        // and remember when it started. Most-recent start time is the
        // last-resort tie-breaker for fresh sessions whose JSONL hasn't
        // produced a summary yet.
        var sshMatches: [(tty: String, name: String, startedAgoSec: Double)] = []
        for surface in surfaces {
            if let agoSec = sshChildAgeSeconds(tty: surface.tty, target: host.sshTarget, alias: host.name) {
                sshMatches.append((tty: surface.tty, name: surface.name, startedAgoSec: agoSec))
            }
        }

        switch sshMatches.count {
        case 0:
            matcherLogger.info("ghostty surface match: no ssh-to-\(host.name, privacy: .public) found")
            return nil
        case 1:
            let tty = sshMatches[0].tty
            matcherLogger.info("ghostty surface match: \(tty, privacy: .public) owns ssh-to-\(host.name, privacy: .public)")
            return tty
        default:
            // Tier 1: narrow by conversation summary in Ghostty's surface
            // name. Claude updates the title via OSC 0/2 which passes
            // through ssh transparently.
            let hint = session.conversationInfo.summary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let hint, !hint.isEmpty {
                let narrowed = sshMatches.filter { $0.name.contains(hint) }
                if narrowed.count == 1 {
                    matcherLogger.info(
                        "ghostty surface match: narrowed \(sshMatches.count, privacy: .public) → 1 by summary hint; tty=\(narrowed[0].tty, privacy: .public)"
                    )
                    return narrowed[0].tty
                }
                matcherLogger.info(
                    "ghostty surface match: summary hint did not narrow (\(narrowed.count, privacy: .public)/\(sshMatches.count, privacy: .public)); falling back to most-recent ssh"
                )
            }
            // Tier 2: pick the most recently started ssh process. Fresh
            // sessions can't use the summary hint (Claude hasn't written
            // a summary line yet), but the user almost always just typed
            // `ssh dev` then `claude` — so the newest ssh-to-host process
            // owns the new claude session.
            let sortedByRecent = sshMatches.sorted { $0.startedAgoSec < $1.startedAgoSec }
            let pick = sortedByRecent[0]
            matcherLogger.info(
                "ghostty surface match: \(sshMatches.count, privacy: .public) surfaces with ssh-to-\(host.name, privacy: .public); picking newest tty=\(pick.tty, privacy: .public) (\(Int(pick.startedAgoSec), privacy: .public)s old)"
            )
            return pick.tty
        }
    }

    // MARK: - AppleScript: enumerate Ghostty surfaces

    /// Each Ghostty terminal's tty (no `/dev/` prefix) and `name`. Name is
    /// the surface title, which Claude CLI keeps current via OSC sequences.
    /// Tab character (`\t`) is the field separator and `\n` is the record
    /// separator — neither appears in tty paths or surface titles in
    /// practice, so no escaping needed.
    private static func listGhosttySurfaces() -> [(tty: String, name: String)] {
        // `tab` and `linefeed` are resolved OUTSIDE the `tell application
        // "Ghostty"` block. Ghostty's AppleScript dictionary has a `tab`
        // class (its own browser-tab concept), so inside the tell block the
        // bare identifier `tab` resolves to "tab" the string, not the
        // tab character — which produced rows like "ttys001tab⠂..." that
        // never matched our parser. Capture the constants up top.
        let script = """
        set sep to tab
        set lf to linefeed
        tell application "Ghostty"
            set rows to {}
            repeat with t in (every terminal)
                try
                    set ttyVal to (tty of t as string)
                    set nameVal to ""
                    try
                        set nameVal to (name of t as string)
                    end try
                    set end of rows to (ttyVal & sep & nameVal)
                end try
            end repeat
            set AppleScript's text item delimiters to lf
            return rows as string
        end tell
        """
        do {
            let result = try AppleScriptRunner.run(script)
            let raw = result.stringValue ?? ""
            return raw.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let ttyPart = parts.first else { return nil }
                let tty = String(ttyPart)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "/dev/", with: "")
                guard !tty.isEmpty else { return nil }
                let name = parts.count > 1 ? String(parts[1]) : ""
                return (tty: tty, name: name)
            }
        } catch AppleScriptError.permissionDenied {
            matcherLogger.warning("Ghostty surface enumeration: TCC permission denied")
            return []
        } catch {
            matcherLogger.warning("Ghostty surface enumeration failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Process tree probe

    // BLOCKED: runs on MainActor and the call below is synchronous —
    // each invocation blocks ~1ms × N-Ghostty-surfaces. Acceptable for
    // a typical 1-3 surface user, but if the count grows or ps gets
    // slow under load, move this off the main actor.
    /// Returns the age (seconds since start) of the ssh-to-host child on
    /// `tty`, or nil if no such child exists. Used as a tie-breaker when
    /// multiple Ghostty surfaces all hold an ssh-to-host child.
    private static func sshChildAgeSeconds(tty: String, target: String, alias: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // `etime=` is "elapsed wall-clock since process start" in the form
        // [[DD-]HH:]MM:SS. We parse this to a Double of seconds. `command=`
        // suppresses the header and gives us the full command line.
        process.arguments = ["-t", tty, "-o", "etime=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain the pipe BEFORE waitUntilExit. If we wait first and the
        // child writes more than the pipe buffer (~64KB on Darwin), the
        // child blocks on write while we block on exit — classic deadlock.
        // readToEnd() returns Data?; try? wraps it in another Optional.
        // flatMap collapses both layers down to Data?, then ?? defaults
        // to an empty Data on either nil source.
        let data = (try? pipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
        process.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""

        for line in out.split(separator: "\n") {
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            // "etime command-string" — etime has no internal spaces, so
            // first whitespace-delimited token is etime, the rest is cmd.
            guard let firstSpace = raw.firstIndex(of: " ") else { continue }
            let etimeStr = String(raw[..<firstSpace])
            let cmd = String(raw[raw.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)

            // A line that starts with "ssh ", contains " ssh " (skipping
            // tools like "rsync" or paths that incidentally contain
            // "ssh"), or contains "/ssh " (e.g. /usr/bin/ssh ...).
            let isSSH = cmd.hasPrefix("ssh ") || cmd.contains(" ssh ") || cmd.contains("/ssh ")
            guard isSSH else { continue }
            // Substring match. A short or path-like alias (e.g. "dev")
            // can produce false positives if it happens to appear
            // elsewhere in the SSH command line, but the isSSH guard
            // above ensures we're only looking at lines that are
            // already recognized SSH invocations, so the blast radius
            // is bounded.
            guard cmd.contains(target) || cmd.contains(alias) else { continue }
            return parseEtime(etimeStr)
        }
        return nil
    }

    /// Parse `ps -o etime=` output ("[[DD-]HH:]MM:SS") into seconds.
    /// Returns Double.infinity if unparseable so unknown-age processes
    /// sort to the END (least preferred) instead of accidentally winning.
    private static func parseEtime(_ s: String) -> Double {
        // Pull off optional "DD-" prefix.
        var rest = s
        var days: Double = 0
        if let dashIdx = rest.firstIndex(of: "-") {
            days = Double(rest[..<dashIdx]) ?? 0
            rest = String(rest[rest.index(after: dashIdx)...])
        }
        let parts = rest.split(separator: ":").map(String.init)
        let h: Double
        let m: Double
        let sec: Double
        switch parts.count {
        case 3:
            h = Double(parts[0]) ?? 0
            m = Double(parts[1]) ?? 0
            sec = Double(parts[2]) ?? 0
        case 2:
            h = 0
            m = Double(parts[0]) ?? 0
            sec = Double(parts[1]) ?? 0
        default:
            return .infinity
        }
        return days * 86_400 + h * 3_600 + m * 60 + sec
    }
}
