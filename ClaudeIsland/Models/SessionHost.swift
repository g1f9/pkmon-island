//
//  SessionHost.swift
//  ClaudeIsland
//
//  Identifies which machine a Claude session lives on. Local is the Mac;
//  remote is a configured SSH host. The `name` in `.remote` is the
//  user-visible alias (RemoteHost.name), not the SSH target — the alias is
//  stable across user edits to ~/.ssh/config.
//
enum SessionHost: Hashable, Sendable, Codable {
    case local
    case remote(name: String)

    var displayName: String {
        switch self {
        case .local: return "local"
        case .remote(let name): return name
        }
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// Bridge connectivity for a remote session. Not part of `SessionPhase` —
/// the phase state machine is logical (idle/processing/...); this is a
/// transport-level overlay shown in the UI.
enum RemoteConnectionState: Equatable, Sendable {
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)
}
