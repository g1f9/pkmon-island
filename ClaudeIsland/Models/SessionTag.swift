//
//  SessionTag.swift
//  ClaudeIsland
//
//  Small visual badges next to a session row's title — e.g. "SSH dev"
//  for remote sessions. Designed to be extensible: add a new case here,
//  give it a label/color, and `SessionTagBadge` renders it the same way.
//

import SwiftUI

enum SessionTag: Equatable, Hashable {
    /// Session lives on a remote SSH host. `hostName` is the user's
    /// alias (RemoteHost.name) — same value as SessionHost.remote(name:).
    case remote(hostName: String)

    // Future: case tmux, case yabai, case pinned, …

    var label: String {
        switch self {
        case .remote(let name): return "SSH:\(name)"
        }
    }

    /// Background color for the pill. Kept muted — tags are secondary
    /// to the session phase indicator.
    var tint: Color {
        switch self {
        case .remote: return Color(red: 0.32, green: 0.55, blue: 0.85) // a calm blue
        }
    }
}

extension SessionState {
    /// Tags shown next to the session title in list views. Order matters —
    /// first tag renders leftmost. Empty for plain local sessions.
    var tags: [SessionTag] {
        var out: [SessionTag] = []
        if case .remote(let name) = host {
            out.append(.remote(hostName: name))
        }
        return out
    }
}
