//
//  RemoteHost.swift
//  ClaudeIsland
//
//  User-facing config for a single SSH-reachable dev VM.
//

import Foundation

struct RemoteHost: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String         // Alias the user picks, e.g. "dev-vm".
                             // Used as SessionHost.remote(name:) and to
                             // derive the per-host socket filename.
    var sshTarget: String    // Argument passed to `ssh`. Can be "user@host"
                             // or a Host alias from ~/.ssh/config.
    var enabled: Bool

    init(id: UUID = UUID(), name: String, sshTarget: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.sshTarget = sshTarget
        self.enabled = enabled
    }
}
