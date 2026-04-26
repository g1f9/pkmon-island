//
//  AppleScriptRunner.swift
//  ClaudeIsland
//
//  Thin wrapper over NSAppleScript with safe string escaping and TCC-aware
//  error reporting. Intentionally NOT an actor — NSAppleScript must run on
//  the main thread, so callers wrap in `await MainActor.run { ... }`.
//

import AppKit
import Foundation

enum AppleScriptError: Error {
    /// errAEEventNotPermitted (-1743): the user has not granted automation access.
    case permissionDenied
    /// Compilation/execution failure with the AppleScript runtime error number and message.
    case scriptFailed(code: Int, message: String)
}

enum AppleScriptRunner {
    /// Escape a Swift string so it can be safely embedded inside AppleScript
    /// double-quoted literals. Newlines stay as literal LF — AppleScript
    /// double-quoted strings accept embedded newlines.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Execute a script source on the main thread. Returns the descriptor.
    @MainActor
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError.scriptFailed(code: -1, message: "Failed to compile script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "unknown"
            if code == -1743 {
                throw AppleScriptError.permissionDenied
            }
            throw AppleScriptError.scriptFailed(code: code, message: msg)
        }
        return result
    }
}
