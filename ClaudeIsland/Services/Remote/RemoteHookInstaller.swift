//
//  RemoteHookInstaller.swift
//  ClaudeIsland
//
//  Installs the Claude Code hook script on a remote host via SCP, and
//  merges hook entries into the remote ~/.claude/settings.json. The hook
//  script writes events to local /tmp/claude-island.sock on the remote,
//  which the SSH bridge forwards to Mac.
//

import Foundation
import os.log

private let installerLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

enum RemoteHookInstaller {
    enum InstallError: Error, LocalizedError {
        case unreachable(stderr: String)
        case versionDetectionFailed
        case scpFailed(stderr: String)
        case settingsReadFailed(stderr: String)
        case settingsWriteFailed(stderr: String)
        case bundledScriptMissing

        var errorDescription: String? {
            switch self {
            case .unreachable(let s): return "Host unreachable: \(s)"
            case .versionDetectionFailed: return "Could not detect Claude Code on remote (PATH issue?)"
            case .scpFailed(let s): return "scp failed: \(s)"
            case .settingsReadFailed(let s): return "Read remote settings.json failed: \(s)"
            case .settingsWriteFailed(let s): return "Write remote settings.json failed: \(s)"
            case .bundledScriptMissing: return "Hook script not found in app bundle"
            }
        }
    }

    static func install(on host: RemoteHost) async throws {
        // 1. Reachability
        let probe = try await SSHCommandRunner.run(
            target: host.sshTarget, remoteCommand: "echo ok", timeout: 5
        )
        guard probe.ok, probe.stdout.contains("ok") else {
            throw InstallError.unreachable(stderr: probe.stderr)
        }
        installerLogger.info("Reachable: \(host.name, privacy: .public)")

        // 2. Claude version through a login shell so PATH includes
        //    nvm/asdf/~/.local/bin etc.
        let versionResult = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: #"bash -lc 'claude --version'"#,
            timeout: 10
        )
        guard versionResult.ok else {
            throw InstallError.versionDetectionFailed
        }
        installerLogger.info(
            "Remote claude version: \(versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)"
        )

        // 3. Ensure remote hooks dir exists
        _ = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "mkdir -p ~/.claude/hooks",
            timeout: 5
        )

        // 4. SCP the hook script
        guard let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") else {
            throw InstallError.bundledScriptMissing
        }
        // scp's destination has to expand ~ via the shell on the remote
        // side; OpenSSH scp passes the path through. Rather than rely on
        // shell expansion, scp to /tmp first then `mv` into place.
        let scp = try await SSHCommandRunner.scpUpload(
            localPath: bundled.path,
            target: host.sshTarget,
            remotePath: "/tmp/claude-island-state.py",
            timeout: 30
        )
        guard scp.ok else { throw InstallError.scpFailed(stderr: scp.stderr) }

        let move = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "mv /tmp/claude-island-state.py ~/.claude/hooks/claude-island-state.py && chmod +x ~/.claude/hooks/claude-island-state.py",
            timeout: 5
        )
        guard move.ok else { throw InstallError.scpFailed(stderr: move.stderr) }

        // 5. Merge ~/.claude/settings.json
        try await mergeSettings(on: host, claudeVersionOutput: versionResult.stdout)
    }

    static func uninstall(on host: RemoteHost) async throws {
        // 1. Read remote settings
        let read = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "cat ~/.claude/settings.json 2>/dev/null || echo '{}'",
            timeout: 5
        )
        guard read.ok else { throw InstallError.settingsReadFailed(stderr: read.stderr) }

        // 2. Strip Claude Island entries from ALL event types
        let stripped = stripAllClaudeIslandEntries(from: read.stdout)

        // 3. Write back
        try await writeRemoteSettings(host: host, jsonString: stripped)

        // 4. Remove hook script
        _ = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "rm -f ~/.claude/hooks/claude-island-state.py",
            timeout: 5
        )
    }

    // MARK: - Settings merge

    private static func mergeSettings(on host: RemoteHost, claudeVersionOutput: String) async throws {
        let read = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "cat ~/.claude/settings.json 2>/dev/null || echo '{}'",
            timeout: 5
        )
        guard read.ok else { throw InstallError.settingsReadFailed(stderr: read.stderr) }

        // Strip then re-add — same as local HookInstaller (CLAUDE.md "strip
        // ALL Claude Island entries from ALL event types").
        var json = parseJSON(read.stdout)
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let kept = entries.compactMap { removingClaudeIslandHooks(from: $0) }
                if !kept.isEmpty { cleaned[event] = kept }
            } else {
                cleaned[event] = value
            }
        }
        hooks = cleaned

        // Reuse local HookInstaller's version gating.
        let parsedVersion = parseClaudeVersion(claudeVersionOutput)

        // We don't assume any particular `python` on the remote — the
        // bundled script has a `#!/usr/bin/env python3` shebang and we
        // chmod +x it, so invoke it directly.
        let directCommand = "$HOME/.claude/hooks/claude-island-state.py"
        let hookEntry: [[String: Any]] = [["type": "command", "command": directCommand]]
        let hookEntryWithTimeout: [[String: Any]] = [
            ["type": "command", "command": directCommand, "timeout": 86400]
        ]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry],
        ]

        let events = HookInstaller.supportedHookEvents(
            for: parsedVersion,
            withMatcher: withMatcher,
            withMatcherAndTimeout: withMatcherAndTimeout,
            withoutMatcher: withoutMatcher,
            preCompactConfig: preCompactConfig
        )
        for (event, config) in events {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + config
        }

        json["hooks"] = hooks
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            throw InstallError.settingsWriteFailed(stderr: "JSON encode failed")
        }
        try await writeRemoteSettings(host: host, jsonString: jsonString)
    }

    private static func writeRemoteSettings(host: RemoteHost, jsonString: String) async throws {
        // Use base64 to avoid shell-quoting hazards in the JSON body.
        let b64 = Data(jsonString.utf8).base64EncodedString()
        let cmd = "echo \(b64) | base64 -d > ~/.claude/settings.json"
        let result = try await SSHCommandRunner.run(
            target: host.sshTarget, remoteCommand: cmd, timeout: 10
        )
        guard result.ok else { throw InstallError.settingsWriteFailed(stderr: result.stderr) }
    }

    // MARK: - JSON helpers

    private static func parseJSON(_ s: String) -> [String: Any] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func stripAllClaudeIslandEntries(from jsonStr: String) -> String {
        var json = parseJSON(jsonStr)
        guard var hooks = json["hooks"] as? [String: Any] else {
            return jsonStr
        }
        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let kept = entries.compactMap { removingClaudeIslandHooks(from: $0) }
                if !kept.isEmpty { cleaned[event] = kept }
            } else {
                cleaned[event] = value
            }
        }
        if cleaned.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = cleaned
        }
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: out, encoding: .utf8) else { return jsonStr }
        return str
    }

    private static func removingClaudeIslandHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
        entryHooks.removeAll { hook in
            (hook["command"] as? String ?? "").contains("claude-island-state")
        }
        if entryHooks.isEmpty { return nil }
        var out = entry
        out["hooks"] = entryHooks
        return out
    }

    private static func parseClaudeVersion(_ output: String) -> HookInstaller.ClaudeCodeVersion? {
        // Output format: "X.Y.Z (Claude Code)" or similar
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges >= 4 else {
            return nil
        }
        func num(_ idx: Int) -> Int {
            guard let r = Range(match.range(at: idx), in: output),
                  let n = Int(output[r]) else { return 0 }
            return n
        }
        return HookInstaller.ClaudeCodeVersion(major: num(1), minor: num(2), patch: num(3))
    }
}
