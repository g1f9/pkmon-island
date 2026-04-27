//
//  RemoteJSONLMirrorRegistry.swift
//  ClaudeIsland
//
//  Owns one RemoteJSONLMirror per (host, sessionId). SessionStore drives
//  ensure() / stop() based on hook events; SSHBridgeController drives
//  stopAll(host:) when a host is disabled, removed, or the laptop sleeps.
//

import Foundation
import os.log

private let registryLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

@MainActor
final class RemoteJSONLMirrorRegistry {
    static let shared = RemoteJSONLMirrorRegistry()

    /// Composite key — distinguish two different sessionIds on the same host
    /// AND same sessionId across hosts (theoretically possible if a session
    /// id collision happens between two dev VMs).
    private struct Key: Hashable {
        let host: String
        let sessionId: String
    }

    private var mirrors: [Key: RemoteJSONLMirror] = [:]

    private init() {}

    /// Idempotent: start a mirror for this session if not already running.
    /// Looks the host up in RemoteHostRegistry — if the user disabled the
    /// host between the hook event arriving and us getting here, no-op.
    func ensure(hostName: String, cwd: String, sessionId: String) {
        let key = Key(host: hostName, sessionId: sessionId)
        guard mirrors[key] == nil else { return }

        guard let host = RemoteHostRegistry.shared.hosts.first(where: { $0.name == hostName && $0.enabled }) else {
            registryLogger.debug(
                "ensure(): host \(hostName, privacy: .public) not enabled, skipping mirror"
            )
            return
        }

        let mirror = RemoteJSONLMirror(host: host, cwd: cwd, sessionId: sessionId)
        mirrors[key] = mirror
        Task { await mirror.start() }
        registryLogger.info(
            "Mirror started: \(hostName, privacy: .public)/\(sessionId.prefix(8), privacy: .public)"
        )
    }

    /// Stop one mirror by host + session.
    func stop(hostName: String, sessionId: String) {
        let key = Key(host: hostName, sessionId: sessionId)
        guard let mirror = mirrors.removeValue(forKey: key) else { return }
        Task { await mirror.stop() }
        registryLogger.info(
            "Mirror stopped: \(hostName, privacy: .public)/\(sessionId.prefix(8), privacy: .public)"
        )
    }

    /// Stop all mirrors for a host. Used when a host is disabled, removed,
    /// or when the laptop is going to sleep.
    func stopAll(hostName: String) {
        let matching = mirrors.filter { $0.key.host == hostName }
        for (key, mirror) in matching {
            mirrors.removeValue(forKey: key)
            Task { await mirror.stop() }
        }
        if !matching.isEmpty {
            registryLogger.info(
                "Stopped \(matching.count, privacy: .public) mirrors for \(hostName, privacy: .public)"
            )
        }
    }

    /// Stop everything — used at shutdown / sleep.
    func stopEverything() {
        let snapshot = mirrors
        mirrors.removeAll()
        for (_, mirror) in snapshot {
            Task { await mirror.stop() }
        }
    }
}
