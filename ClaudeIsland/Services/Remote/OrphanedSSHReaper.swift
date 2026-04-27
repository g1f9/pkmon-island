//
//  OrphanedSSHReaper.swift
//  ClaudeIsland
//
//  When Vibe Notch dies hard (kill -9, panic, force-quit) its ssh
//  subprocesses (`-N -R` reverse tunnels + tail-mirror processes) get
//  re-parented to launchd (PPID=1) and keep running on their own. They
//  hold the remote /tmp/claude-island.sock open, which makes the next
//  app launch's reverse tunnel fail to bind, and they leak ssh
//  connections to the user's dev VMs.
//
//  Sweep at startup: enumerate ssh processes whose parent is launchd,
//  match against our command signatures, SIGTERM them. Live children of
//  the current app have a non-1 PPID and are untouched.
//

import Darwin
import Foundation
import os.log

private let reaperLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

enum OrphanedSSHReaper {
    /// SIGTERM every ssh process that looks like an orphan from a prior
    /// Vibe Notch run. Idempotent and safe to call before bridges start.
    static func sweep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            reaperLogger.warning("Orphan sweep: ps launch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Drain stdout BEFORE waiting on exit — pipe-buffer deadlock
        // pattern, same as in GhosttySurfaceMatcher.
        let data = (try? pipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
        process.waitUntilExit()

        let out = String(data: data, encoding: .utf8) ?? ""
        var killed = 0
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let (pid, ppid, command) = parsePsLine(String(line)) else { continue }
            // Only orphans (re-parented to launchd). Live ssh children of
            // the current app have ppid == this process's pid, so they
            // don't match.
            guard ppid == 1 else { continue }
            guard isOurOrphan(command: command) else { continue }
            // Sanity check: never SIGTERM ourselves or PID 1.
            guard pid > 1, pid != getpid() else { continue }

            let result = kill(pid_t(pid), SIGTERM)
            if result == 0 {
                killed += 1
                reaperLogger.info(
                    "Orphan sweep: SIGTERM pid=\(pid, privacy: .public) cmd=\(command.prefix(120), privacy: .public)"
                )
            } else {
                reaperLogger.debug(
                    "Orphan sweep: SIGTERM pid=\(pid, privacy: .public) failed errno=\(errno, privacy: .public)"
                )
            }
        }

        if killed > 0 {
            reaperLogger.info("Orphan sweep: terminated \(killed, privacy: .public) leftover ssh process(es)")
        }
    }

    // MARK: - Parsing

    /// Parse one line of `ps -axo pid=,ppid=,command=` output.
    /// Format is leading-padded "pid ppid <command…>".
    private static func parsePsLine(_ line: String) -> (pid: Int, ppid: Int, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Split on whitespace, first two tokens = pid + ppid; rest is the
        // command (which itself contains spaces — rejoin).
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]) else { return nil }
        let command = String(parts[2])
        return (pid, ppid, command)
    }

    /// Does this command line match an ssh subprocess we would have
    /// spawned? Pattern is conservative: requires both an ssh-shaped
    /// argv[0] AND one of our known invocation signatures.
    private static func isOurOrphan(command: String) -> Bool {
        // argv[0] looks like an ssh binary. The bare `"ssh "` prefix
        // covers `ssh ...`; `/ssh ` covers absolute paths like
        // `/usr/bin/ssh ...`.
        let isSSH = command.hasPrefix("ssh ") || command.contains("/ssh ")
        guard isSSH else { return false }

        // Signature 1: our reverse tunnel forwards the remote
        // /tmp/claude-island.sock back to /tmp/claude-island-<host>.sock.
        // The literal path is unique enough to identify us alone.
        if command.contains("/tmp/claude-island.sock")
            && command.contains("/tmp/claude-island-") {
            return true
        }

        // Signature 2: our JSONL mirror tail. Plain ssh+tail isn't
        // unique on its own (rsync, log piping, etc.), but the
        // combination of `tail -c +` and `.claude/projects/` together
        // inside a `bash -lc` ssh payload only comes from us.
        if command.contains("tail -c +")
            && command.contains(".claude/projects/")
            && command.contains("bash -lc") {
            return true
        }

        return false
    }
}
