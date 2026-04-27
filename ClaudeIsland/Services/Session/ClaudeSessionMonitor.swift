//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    /// One HookSocketServer per host. Local lives at `.local`; remote
    /// hosts live at `.remote(name:)`.
    private var servers: [SessionHost: HookSocketServer] = [:]

    /// Local hook socket path — exactly the path Claude Code's hook
    /// script writes to on this Mac. Internal to the monitor — remote
    /// servers are spun up via startServer(host:socketPath:) by
    /// SSHBridgeController, which constructs its own paths via
    /// remoteSocketPath(for:).
    private static let localSocketPath = "/tmp/claude-island.sock"

    /// Per-remote-host socket path on the Mac side. The SSH bridge's
    /// `-R remote:local` forwards to this path.
    static func remoteSocketPath(for hostName: String) -> String {
        "/tmp/claude-island-\(hostName).sock"
    }

    /// All currently-known remote host aliases (the `name` of every
    /// .remote(name:) server in `servers`). Used by SSHBridgeController
    /// (Task 9) to reconcile servers when the registry changes.
    var knownRemoteHostNames: [String] {
        servers.keys.compactMap {
            if case .remote(let name) = $0 { return name }
            return nil
        }
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Singleton

    private static var sharedInstance: ClaudeSessionMonitor?

    static var shared: ClaudeSessionMonitor {
        if let s = sharedInstance { return s }
        let new = ClaudeSessionMonitor()
        sharedInstance = new
        return new
    }

    init() {
        Self.sharedInstance = self
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Periodic status rechecking is host-agnostic — keep as-is.
        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }

        // Start the local hook server. SSHBridgeController will spin
        // up additional servers per remote host (Task 9).
        startServer(host: .local, socketPath: Self.localSocketPath)
    }

    /// Spin up a HookSocketServer for one host. Idempotent — if a server
    /// already exists for that host, this is a no-op.
    func startServer(host: SessionHost, socketPath: String) {
        guard servers[host] == nil else { return }
        let server = HookSocketServer(socketPath: socketPath, host: host)
        server.start(
            onEvent: { [weak self] event, eventHost in
                Task {
                    await SessionStore.shared.process(.hookReceived(event, host: eventHost))
                }

                // InterruptWatcherManager watches the LOCAL ~/.claude/projects/<cwd>/<sid>.jsonl
                // file. Remote sessions have no such file on Mac; trying
                // to attach a watcher fails noisily and gives nothing
                // back. Spec § 数据流 explicitly defers JSONL access for
                // remote to v2.
                if eventHost == .local && event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if eventHost == .local && event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    Task { @MainActor in
                        guard let self else { return }
                        for server in self.servers.values {
                            server.cancelPendingPermissions(sessionId: event.sessionId)
                        }
                    }
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    Task { @MainActor in
                        guard let self else { return }
                        for server in self.servers.values {
                            server.cancelPendingPermission(toolUseId: toolUseId)
                        }
                    }
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
        servers[host] = server
    }

    func stopServer(host: SessionHost) {
        servers[host]?.stop()
        servers.removeValue(forKey: host)
    }

    func stopMonitoring() {
        for server in servers.values {
            server.stop()
        }
        servers.removeAll()
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            // Route to the owning server only. The session carries its
            // host, and each HookSocketServer's pendingPermissions cache
            // is server-local — broadcasting to all servers would just
            // be N-1 silent no-ops plus N-1 noisy debug log lines.
            servers[session.host]?.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            servers[session.host]?.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
