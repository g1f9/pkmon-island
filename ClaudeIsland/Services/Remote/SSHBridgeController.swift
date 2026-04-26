//
//  SSHBridgeController.swift
//  ClaudeIsland
//
//  Owns one SSHBridge per enabled RemoteHost. Wires sleep/wake hooks so
//  bridges go down with the laptop and come back when it wakes.
//

import AppKit
import Combine
import Foundation
import os.log

private let controllerLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

@MainActor
final class SSHBridgeController {
    static let shared = SSHBridgeController()

    private var bridges: [UUID: SSHBridge] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// Set after `start()`. Lets us know whether to react to registry
    /// updates by spinning bridges up/down.
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        observeWorkspaceNotifications()
        observeRegistry()
        startEnabledBridges()
    }

    func suspendAll() {
        controllerLogger.info("Suspending \(self.bridges.count, privacy: .public) bridges")
        for (_, bridge) in bridges {
            Task { await bridge.stop() }
        }
        bridges.removeAll()
    }

    func resumeAll() {
        controllerLogger.info("Resuming bridges")
        startEnabledBridges()
    }

    // MARK: - Internal

    private func startEnabledBridges() {
        let monitor = ClaudeSessionMonitor.shared
        for host in RemoteHostRegistry.shared.hosts where host.enabled {
            startBridge(for: host, monitor: monitor)
        }
    }

    private func startBridge(for host: RemoteHost, monitor: ClaudeSessionMonitor) {
        guard bridges[host.id] == nil else { return }

        // Make sure the listening socket on the Mac side is up before
        // the tunnel forwards anything to it.
        let socketPath = ClaudeSessionMonitor.remoteSocketPath(for: host.name)
        monitor.startServer(host: .remote(name: host.name), socketPath: socketPath)

        let bridge = SSHBridge(host: host)
        bridges[host.id] = bridge

        Task {
            await bridge.start { [weak self] state in
                Task { @MainActor in
                    self?.handleStateChange(host: host, state: state)
                }
            }
        }
    }

    private func stopBridge(hostId: UUID) {
        guard let bridge = bridges.removeValue(forKey: hostId) else { return }
        Task { await bridge.stop() }
    }

    private func handleStateChange(host: RemoteHost, state: SSHBridge.State) {
        let mapped: RemoteConnectionState?
        switch state {
        case .idle:
            mapped = nil
        case .connecting, .connected:
            mapped = .connected
        case .reconnecting(let attempt):
            mapped = .reconnecting(attempt: attempt)
        case .failed(let reason):
            mapped = .failed(reason: reason)
        }
        Task {
            await SessionStore.shared.process(
                .bridgeStateChanged(host: .remote(name: host.name), state: mapped)
            )
        }
    }

    // MARK: - Observers

    private func observeRegistry() {
        RemoteHostRegistry.shared.$hosts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hosts in
                self?.reconcile(with: hosts)
            }
            .store(in: &cancellables)
    }

    private func reconcile(with hosts: [RemoteHost]) {
        let monitor = ClaudeSessionMonitor.shared

        // Stop bridges for hosts that were removed or disabled
        let currentIds = Set(hosts.filter { $0.enabled }.map { $0.id })
        for id in bridges.keys where !currentIds.contains(id) {
            stopBridge(hostId: id)
        }

        // Start bridges for newly enabled hosts
        for host in hosts where host.enabled {
            startBridge(for: host, monitor: monitor)
        }

        // Stop servers for hosts that no longer exist
        let liveNames = Set(hosts.map { $0.name })
        for h in monitor.knownRemoteHostNames where !liveNames.contains(h) {
            monitor.stopServer(host: .remote(name: h))
        }
    }

    private func observeWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.suspendAll() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.resumeAll() }
            .store(in: &cancellables)
    }
}
