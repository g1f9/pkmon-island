//
//  RemoteHostRegistry.swift
//  ClaudeIsland
//
//  Persistence + change-broadcast for the user's RemoteHost list.
//  Stored in UserDefaults.standard under the key "remoteHosts" as JSON.
//

import Combine
import Foundation
import os.log

private let registryLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

@MainActor
final class RemoteHostRegistry: ObservableObject {
    static let shared = RemoteHostRegistry()

    private static let storageKey = "remoteHosts"

    /// Current list. Mutating this both persists and notifies.
    @Published private(set) var hosts: [RemoteHost] = []

    private init() {
        load()
    }

    // MARK: - CRUD

    func add(_ host: RemoteHost) {
        guard !hosts.contains(where: { $0.name == host.name }) else {
            registryLogger.warning("RemoteHost '\(host.name, privacy: .public)' already exists")
            return
        }
        hosts.append(host)
        save()
    }

    func update(_ host: RemoteHost) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx] = host
        save()
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) else {
            return
        }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
