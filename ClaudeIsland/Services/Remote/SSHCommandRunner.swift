//
//  SSHCommandRunner.swift
//  ClaudeIsland
//
//  Wrapper around Process for `ssh` and `scp` invocations. Forces
//  BatchMode=yes so reconnects never block the app on a hidden password
//  prompt; enforces an outer timeout so a wedged TCP connection can't
//  pin a Process forever.
//

import Foundation

/// Lock-protected single-shot gate. The continuation in `runProcess`
/// can be resumed by either the timeout timer or the process's
/// terminationHandler — `tryResume` ensures only the first one wins.
/// Defined as a class so the closures running on different queues
/// share the same flag, and so `@Sendable` constraints are satisfied
/// by reference semantics.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume(_ block: () -> Void) {
        lock.lock()
        let already = resumed
        resumed = true
        lock.unlock()
        if !already { block() }
    }
}

enum SSHCommandRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var ok: Bool { exitCode == 0 }
    }

    enum SSHError: Error, LocalizedError {
        case launchFailed(reason: String)
        case timedOut(after: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let reason): return "Failed to launch ssh: \(reason)"
            case .timedOut(let t): return "ssh timed out after \(Int(t))s"
            }
        }
    }

    /// Standard hardening flags for any non-interactive ssh invocation.
    /// Callers add `-N`, `-R`, target, etc. on top.
    static let baseSSHArgs: [String] = [
        "-o", "BatchMode=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "ConnectTimeout=10",
    ]

    /// One-shot ssh: `ssh <baseArgs> <target> <remoteCmd>`.
    /// Returns a Result on completion or throws on launch/timeout failure.
    static func run(
        target: String,
        remoteCommand: String,
        timeout: TimeInterval = 15
    ) async throws -> Result {
        var args = baseSSHArgs
        args.append(target)
        args.append(remoteCommand)
        return try await runProcess(executable: "/usr/bin/ssh", args: args, timeout: timeout)
    }

    /// `scp <baseArgs> <localPath> <target>:<remotePath>`. Same hardening.
    static func scpUpload(
        localPath: String,
        target: String,
        remotePath: String,
        timeout: TimeInterval = 30
    ) async throws -> Result {
        var args = baseSSHArgs
        args.append(localPath)
        args.append("\(target):\(remotePath)")
        return try await runProcess(executable: "/usr/bin/scp", args: args, timeout: timeout)
    }

    /// Private bridge from Process to async/await. Used only by `run` and
    /// `scpUpload` — the long-running `ssh -N -R` tunnel in `SSHBridge` does
    /// NOT go through here because it needs to keep the Process handle for
    /// its own cancellation lifecycle.
    private static func runProcess(
        executable: String,
        args: [String],
        timeout: TimeInterval
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SSHError.launchFailed(reason: error.localizedDescription)
        }

        // Single-resume guard: both the timeout firing `terminate()` and the
        // process exiting normally end up calling resume() — without this
        // lock, a timeout would resume(throwing:) and then terminationHandler
        // would resume(returning:), trapping the checked continuation.
        let resumeGate = ResumeGate()

        // Hoist the timer out of the continuation closure so `onCancel` can
        // also cancel it. Without this the timer leaks until `timeout`
        // seconds after a Task cancellation if the terminate→exit race ends
        // with the process exiting before we observed isRunning.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: DispatchTime.now() + timeout)

        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                timer.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                    }
                    resumeGate.tryResume {
                        continuation.resume(throwing: SSHError.timedOut(after: timeout))
                    }
                }
                timer.resume()

                process.terminationHandler = { proc in
                    timer.cancel()
                    // readToEnd() returns Data?; try? wraps it in another Optional.
                    // flatMap collapses both layers down to Data?, then ?? defaults
                    // to an empty Data on either nil source.
                    let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
                    let result = Result(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? ""
                    )
                    resumeGate.tryResume {
                        continuation.resume(returning: result)
                    }
                }
            }
        } onCancel: {
            timer.cancel()
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
