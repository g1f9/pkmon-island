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

    /// Generic: caller supplies all args (used for `ssh -N -R` long-running
    /// tunnel; that path doesn't go through this helper because we need to
    /// keep the Process handle for cancellation).
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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = DispatchTime.now() + timeout
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: deadline)
                timer.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                        continuation.resume(throwing: SSHError.timedOut(after: timeout))
                    }
                }
                timer.resume()

                process.terminationHandler = { proc in
                    timer.cancel()
                    let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()).flatMap { $0 } ?? Data()
                    let result = Result(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? ""
                    )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
