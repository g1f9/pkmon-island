//
//  RemoteJSONLMirror.swift
//  ClaudeIsland
//
//  Per-(host, session) tail of the remote JSONL file at
//  `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`. Bytes are appended
//  to a local mirror file at the corresponding path under
//  `ClaudePaths.remoteMirrorProjectsDir(forHost:)`, so ConversationParser
//  reads remote sessions through the same code path as local ones.
//
//  This is the v2 piece deferred in the original SSH remote-state spec
//  (`docs/superpowers/specs/2026-04-26-ssh-remote-state-design.md` § 不做的：
//  JSONL 远端访问). Without it, remote chat history is reconstructed from
//  hook events alone — tool call placeholders only, no user/assistant text.
//

import Foundation
import os.log

private let mirrorLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

/// Tails one remote JSONL file via SSH and mirrors bytes into a local file.
/// One actor per (hostName, sessionId).
actor RemoteJSONLMirror {
    let host: RemoteHost
    let cwd: String
    let sessionId: String

    /// Local mirror file path (matches ConversationParser's path layout).
    let localPath: URL

    private var process: Process?
    private var loop: Task<Void, Never>?
    private var stopping = false
    private var fileHandle: FileHandle?

    /// Backoff schedule for tail-reconnect attempts (seconds).
    private static let backoffSchedule: [UInt64] = [1, 2, 4, 8, 16, 30, 60]

    init(host: RemoteHost, cwd: String, sessionId: String) {
        self.host = host
        self.cwd = cwd
        self.sessionId = sessionId

        let projectDir = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        self.localPath = ClaudePaths
            .remoteMirrorProjectsDir(forHost: host.name)
            .appendingPathComponent(projectDir, isDirectory: true)
            .appendingPathComponent(sessionId + ".jsonl")
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil, !stopping else { return }
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        stopping = true
        loop?.cancel()
        terminateProcess()
        try? fileHandle?.close()
        fileHandle = nil
        loop = nil
    }

    // MARK: - Run loop

    private func runLoop() async {
        ensureMirrorDirectory()

        var attempt = 0
        while !Task.isCancelled && !stopping {
            let exitedCleanly = await runOnce()
            if Task.isCancelled || stopping { return }

            attempt += 1
            let waitSec = Self.backoffSchedule[min(attempt - 1, Self.backoffSchedule.count - 1)]
            mirrorLogger.info(
                "Tail for \(self.host.name, privacy: .public)/\(self.sessionId.prefix(8), privacy: .public) exited (clean=\(exitedCleanly, privacy: .public)); reconnecting in \(waitSec, privacy: .public)s"
            )
            try? await Task.sleep(nanoseconds: waitSec * 1_000_000_000)
        }
    }

    /// Spawn one `ssh tail` and stream stdout into the mirror file.
    /// Returns true on a clean exit (we asked for it), false otherwise.
    private func runOnce() async -> Bool {
        // Use $HOME (expanded by the remote login shell) rather than `~`.
        // The bash -c payload below is wrapped in single quotes for ssh
        // delivery, and ~ inside single quotes is taken literally — so
        // an earlier version sat on a literal-tilde path forever.
        // Encoded projectDir + UUID sessionId never contain $ ` " or \,
        // so double-quoting the whole path inside the bash -c body is
        // safe and lets $HOME expand.
        let remotePath = remoteJSONLPath()

        // Resume from the local mirror's current size so we don't re-mirror
        // bytes we already have. `tail -c +N` is 1-indexed: +1 = from start.
        let localSize = currentLocalSize()
        let startByte = localSize + 1
        let remoteCommand = "tail -c +\(startByte) -F \"\(remotePath)\""

        var args = SSHCommandRunner.baseSSHArgs
        args.append(host.sshTarget)
        args.append("bash -lc '\(remoteCommand.replacingOccurrences(of: "'", with: "'\\''"))'")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            mirrorLogger.error("Failed to launch ssh tail: \(error.localizedDescription, privacy: .public)")
            return false
        }
        process = proc

        // Open mirror file for append. Re-open per attempt so that if the
        // file was rotated/deleted out from under us between attempts we
        // recover instead of writing into a zombie inode.
        guard let handle = openMirrorForAppend() else {
            terminateProcess()
            return false
        }
        fileHandle = handle

        let stdoutFD = stdoutPipe.fileHandleForReading
        stdoutFD.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.appendToMirror(data)
            }
        }

        // Wait for ssh to exit (clean stop or transport failure).
        // withCheckedContinuation has no built-in cancellation hook; the
        // ONLY exit path is the terminationHandler firing. `stop()` triggers
        // that via `terminateProcess()`. Don't shortcut this without a
        // replacement cancellation source.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in continuation.resume() }
        }

        stdoutFD.readabilityHandler = nil

        let stderrText = (try? stderrPipe.fileHandleForReading.readToEnd()).flatMap { $0 }.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        if !stderrText.isEmpty {
            mirrorLogger.debug(
                "Tail stderr for \(self.host.name, privacy: .public)/\(self.sessionId.prefix(8), privacy: .public): \(stderrText, privacy: .public)"
            )
        }

        try? fileHandle?.close()
        fileHandle = nil
        process = nil
        return proc.terminationStatus == 0
    }

    private func appendToMirror(_ data: Data) {
        guard let handle = fileHandle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            mirrorLogger.error(
                "Mirror write failed for \(self.host.name, privacy: .public)/\(self.sessionId.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Helpers

    private func remoteJSONLPath() -> String {
        let projectDir = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        // $HOME so the remote login shell can expand it inside double
        // quotes — see the runOnce comment for why we can't use `~`.
        return "$HOME/.claude/projects/\(projectDir)/\(sessionId).jsonl"
    }

    private func currentLocalSize() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private func ensureMirrorDirectory() {
        let dir = localPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func openMirrorForAppend() -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: localPath.path) {
            fm.createFile(atPath: localPath.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: localPath) else {
            mirrorLogger.error("Cannot open mirror for write: \(self.localPath.path, privacy: .public)")
            return nil
        }
        do {
            _ = try handle.seekToEnd()
        } catch {
            try? handle.close()
            return nil
        }
        return handle
    }

    private func terminateProcess() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    /// POSIX-quote a path for safe insertion into a `bash -lc '...'` payload.
    /// Empty / no-shell-meta paths still go through the same wrapping for
    /// consistency.
    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
