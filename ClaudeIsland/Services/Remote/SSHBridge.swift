//
//  SSHBridge.swift
//  ClaudeIsland
//
//  Owns one persistent `ssh -N -R` reverse-Unix-socket tunnel for one
//  RemoteHost. Auto-reconnects with exponential backoff. Reports state
//  changes via the closure passed to `start`.
//
//  This is intentionally NOT routed through SSHCommandRunner — that helper
//  is one-shot. The tunnel needs the long-running Process handle so we
//  can SIGTERM on stop and observe stderr.
//

import Foundation
import os.log

private let bridgeLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

actor SSHBridge {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(reason: String)
    }

    let host: RemoteHost

    private var process: Process?
    private(set) var state: State = .idle
    private var reconnectTask: Task<Void, Never>?

    /// Callback fires on every state change. Invoked on the actor; do
    /// any UI hop on the receiving side.
    private var onStateChange: (@Sendable (State) -> Void)?

    private static let backoffSchedule: [UInt64] = [1, 2, 4, 8, 16, 30, 60]
    private static let backoffMaxNs: UInt64 = 60 * 1_000_000_000

    init(host: RemoteHost) {
        self.host = host
    }

    func start(onStateChange: @escaping @Sendable (State) -> Void) {
        self.onStateChange = onStateChange
        reconnectTask = Task { await self.connectLoop() }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        terminateProcess()
        Task { await cleanupRemoteSocket() }
        setState(.idle)
    }

    // MARK: - Internal

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }

    private func connectLoop() async {
        var attempt = 0
        setState(.connecting)
        while !Task.isCancelled {
            let exitedCleanly = await runOnce()
            if Task.isCancelled || state == .idle { return }
            attempt += 1
            // Always transition out of any post-runOnce state (.connected /
            // .failed / .connecting) into .reconnecting before sleeping.
            // Without this, .failed(reason:) from a launch error would stay
            // visible to UI for the entire backoff window even though we
            // are already planning to retry — making .failed semantically
            // ambiguous (is it terminal, or per-attempt?). Holding
            // .reconnecting throughout the sleep makes the contract clear:
            // .failed only ever appears for the brief window between
            // launch failure and the cancellation guard above.
            setState(.reconnecting(attempt: attempt))
            let waitNs = backoff(forAttempt: attempt)
            bridgeLogger.info(
                "SSH tunnel for \(self.host.name, privacy: .public) exited (clean=\(exitedCleanly, privacy: .public)); reconnecting in \(waitNs / 1_000_000_000, privacy: .public)s"
            )
            try? await Task.sleep(nanoseconds: waitNs)
        }
    }

    /// Runs one ssh -N -R subprocess to completion. Returns true on
    /// expected (clean) exit, false if it died unexpectedly.
    private func runOnce() async -> Bool {
        let socketPath = "/tmp/claude-island.sock"
        let macSocketPath = "/tmp/claude-island-\(host.name).sock"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = SSHCommandRunner.baseSSHArgs + [
            "-N",
            "-o", "ControlMaster=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-R", "\(socketPath):\(macSocketPath)",
            host.sshTarget,
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
        } catch {
            setState(.failed(reason: "launch ssh: \(error.localizedDescription)"))
            return false
        }
        process = proc

        // Switch state to connected only once ssh has had a moment to
        // establish forwarding. ExitOnForwardFailure=yes means ssh will
        // exit fast if the bind fails, so a 1s probe is sufficient.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if proc.isRunning {
            setState(.connected)
        }

        // This await DOES NOT respond to Task cancellation directly —
        // withCheckedContinuation has no built-in cancellation hook. The
        // ONLY way out of this await is for `terminationHandler` to fire,
        // which requires the ssh subprocess to exit. `stop()` triggers
        // exit by calling `terminateProcess()` (SIGTERM); without that,
        // cancelling the parent Task here will leave this coroutine
        // parked indefinitely. Don't "simplify" `stop()` by removing
        // `terminateProcess()`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in continuation.resume() }
        }

        let stderr = (try? stderrPipe.fileHandleForReading.readToEnd()).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        if !stderr.isEmpty {
            bridgeLogger.error(
                "SSH tunnel for \(self.host.name, privacy: .public) stderr: \(stderr, privacy: .public)"
            )
        }
        process = nil
        return proc.terminationStatus == 0
    }

    private func terminateProcess() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    private func cleanupRemoteSocket() async {
        // Best-effort. If this fails we'll rely on StreamLocalBindUnlink
        // on the next start.
        _ = try? await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "rm -f /tmp/claude-island.sock",
            timeout: 5
        )
    }

    private func backoff(forAttempt attempt: Int) -> UInt64 {
        let idx = min(attempt - 1, Self.backoffSchedule.count - 1)
        let seconds = Self.backoffSchedule[max(idx, 0)]
        let ns = UInt64(seconds) * 1_000_000_000
        return min(ns, Self.backoffMaxNs)
    }
}
