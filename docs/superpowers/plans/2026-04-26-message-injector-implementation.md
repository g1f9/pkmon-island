# MessageInjector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the chat panel reply box actually send the user's text into the running Claude session, whether Claude is running inside Ghostty or inside tmux.

**Architecture:** Introduce `MessageInjector` protocol with a Registry that picks the right backend per `SessionState`. Two backends: `GhosttyInjector` (NSAppleScript `input text` — verified to share Cmd+V's bracketed-paste path) and `TmuxInjector` (`tmux load-buffer` + `paste-buffer -p -d` — replaces the broken `send-keys -l`). The chat view delegates to the Registry; the existing approval handler is left untouched.

**Tech Stack:** Swift 5+ / SwiftUI / actors / `os.log` / `NSAppleScript` / `NSWorkspace` / `ProcessExecutor` (existing async wrapper around `Process`).

**Notes for the implementer:**
- This codebase has **no test target** — `xcodebuild test` finds nothing. The verification step in every task is `xcodebuild -scheme ClaudeIsland -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` (Release requires a Mac Development cert that may not exist on every dev machine; Debug with signing disabled is the canonical local-build command). Real correctness is established by the manual smoke checklist in Task 9 (G1–G6, T1–T4).
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`. New files dropped into `ClaudeIsland/` are auto-detected — **do NOT touch `project.pbxproj`**.
- Spec lives at `docs/superpowers/specs/2026-04-26-message-injector-design.md`. Re-read sections of it if a task feels under-specified.

**Reference design context:** Verified at Ghostty commit `67b5783b`: `input text` AppleScript → `surface.sendText` → `ghostty_surface_text` → `textCallback` → `completeClipboardPaste(text, true)` (same path as Cmd+V). So the AppleScript route gives bracketed paste for free.

---

## Task 1: Create the `MessageInjector` protocol + Registry skeleton

**Files:**
- Create: `ClaudeIsland/Services/Injection/MessageInjector.swift`

- [ ] **Step 1: Write the file**

```swift
//
//  MessageInjector.swift
//  ClaudeIsland
//
//  Abstraction for sending user text into a running Claude session.
//  Backends: Ghostty (AppleScript), Tmux (paste-buffer).
//  This is a SEPARATE channel from approvals — approvals still go
//  through HookSocketServer's open Unix socket.
//

import Foundation
import os.log

let injectLogger = Logger(subsystem: "com.claudeisland", category: "Inject")

protocol MessageInjector: Sendable {
    /// Stable identifier used in logs and UI ("ghostty", "tmux").
    var displayName: String { get }

    /// Whether this backend can currently route text to the given session.
    func canInject(into session: SessionState) async -> Bool

    /// Inject `text` into the session. Returns true if the backend accepted
    /// the request — does NOT mean Claude has dispatched it; that is
    /// confirmed independently when the JSONL UserPromptSubmit event lands.
    func inject(_ text: String, into session: SessionState) async -> Bool
}

@MainActor
final class MessageInjectorRegistry {
    static let shared = MessageInjectorRegistry()

    /// Highest priority first. Ghostty's path is preferred because it does
    /// not require tmux and uses the native paste flow.
    private let injectors: [any MessageInjector]

    private init() {
        self.injectors = [
            GhosttyInjector(),
            TmuxInjector(),
        ]
    }

    /// Returns the first injector that reports it can handle the session.
    /// Nil means "panel should disable the input bar".
    func resolve(for session: SessionState) async -> (any MessageInjector)? {
        for injector in injectors {
            if await injector.canInject(into: session) {
                return injector
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Add temporary stubs so the project still builds**

The Registry references `GhosttyInjector` and `TmuxInjector` which don't exist yet. Add these as the last lines of the same file so the build compiles. They will be replaced by full implementations in Tasks 3 and 4.

```swift
// Temporary stubs — replaced by GhosttyInjector.swift / TmuxInjector.swift
struct GhosttyInjector: MessageInjector {
    let displayName = "ghostty"
    func canInject(into session: SessionState) async -> Bool { false }
    func inject(_ text: String, into session: SessionState) async -> Bool { false }
}

struct TmuxInjector: MessageInjector {
    let displayName = "tmux"
    func canInject(into session: SessionState) async -> Bool { false }
    func inject(_ text: String, into session: SessionState) async -> Bool { false }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run:

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -5
```

Expected: `** BUILD SUCCEEDED **` at the end. If failure mentions `GhosttyInjector` or `TmuxInjector`, re-check Step 2.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Services/Injection/MessageInjector.swift
git commit -m "Scaffold MessageInjector protocol and Registry"
```

---

## Task 2: `AppleScriptRunner` utility

**Files:**
- Create: `ClaudeIsland/Services/Injection/AppleScriptRunner.swift`

This wraps `NSAppleScript` with consistent string escaping and error decoding, so `GhosttyInjector` (and any future AppleScript-based injector) doesn't repeat the boilerplate.

- [ ] **Step 1: Write the file**

```swift
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
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/Services/Injection/AppleScriptRunner.swift
git commit -m "Add AppleScriptRunner helper for NSAppleScript invocations"
```

---

## Task 3: Implement `GhosttyInjector`

**Files:**
- Create: `ClaudeIsland/Services/Injection/GhosttyInjector.swift`
- Modify: `ClaudeIsland/Services/Injection/MessageInjector.swift` — remove the `GhosttyInjector` stub

- [ ] **Step 1: Write `GhosttyInjector.swift`**

```swift
//
//  GhosttyInjector.swift
//  ClaudeIsland
//
//  Sends user text to a Ghostty terminal hosting a Claude session.
//  Uses Ghostty 1.3+ AppleScript dictionary: `input text "..." to terminal`.
//  Verified at ghostty commit 67b5783b — `input text` calls
//  `surface.completeClipboardPaste(text, true)`, i.e. the Cmd+V path,
//  so we get bracketed paste, multi-line preservation, and no leading
//  '/' '!' '#' mode-switch hazards for free.
//

import AppKit
import Foundation

struct GhosttyInjector: MessageInjector {
    let displayName = "ghostty"

    /// Verified bundle id (locally checked 2026-04-26). If Ghostty rebrands,
    /// update this constant — `canInject` short-circuits when the app isn't
    /// running, so a stale id silently disables the backend.
    private let ghosttyBundleId = "com.mitchellh.ghostty"

    func canInject(into session: SessionState) async -> Bool {
        guard !session.cwd.isEmpty else { return false }
        guard isGhosttyRunning() else { return false }

        let normalized = Self.normalize(cwd: session.cwd)
        return await MainActor.run { (try? probeMatchingTerminal(cwd: normalized)) ?? false }
    }

    func inject(_ text: String, into session: SessionState) async -> Bool {
        let normalized = Self.normalize(cwd: session.cwd)
        let escapedText = AppleScriptRunner.escape(text)
        let escapedCwd = AppleScriptRunner.escape(normalized)

        let script = """
        tell application id "\(ghosttyBundleId)"
            set targets to every terminal whose working directory is equal to "\(escapedCwd)"
            if (count of targets) is 0 then
                return false
            end if
            input text "\(escapedText)" to item 1 of targets
            return true
        end tell
        """

        let started = Date()
        do {
            let result = try await MainActor.run { try AppleScriptRunner.run(script) }
            let ok = result.booleanValue
            let dur = Date().timeIntervalSince(started)
            injectLogger.info(
                "ghostty inject \(session.sessionId.prefix(8), privacy: .public) \(text.count, privacy: .public)b ok=\(ok, privacy: .public) \(String(format: "%.2f", dur), privacy: .public)s"
            )
            return ok
        } catch AppleScriptError.permissionDenied {
            injectLogger.error(
                "ghostty inject TCC denied for \(session.sessionId.prefix(8), privacy: .public) — automation permission missing"
            )
            return false
        } catch {
            injectLogger.error(
                "ghostty inject failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Internals

    private func isGhosttyRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == ghosttyBundleId }
    }

    /// Lightweight existence probe — returns true iff Ghostty has at least
    /// one terminal whose working directory matches `cwd`.
    @MainActor
    private func probeMatchingTerminal(cwd: String) throws -> Bool {
        let escapedCwd = AppleScriptRunner.escape(cwd)
        let script = """
        tell application id "\(ghosttyBundleId)"
            return (count of (every terminal whose working directory is equal to "\(escapedCwd)")) > 0
        end tell
        """
        do {
            let result = try AppleScriptRunner.run(script)
            return result.booleanValue
        } catch AppleScriptError.permissionDenied {
            // Until automation permission is granted we cannot answer the
            // question. Return false so the registry falls through to tmux;
            // the actual permission prompt fires at first inject.
            return false
        }
    }

    /// Normalize a cwd so equality matches Ghostty's `working directory`
    /// representation. We standardize the path (resolves `..`, removes the
    /// trailing slash for non-root paths) but DO NOT resolve symlinks —
    /// Ghostty itself reports the unresolved path.
    static func normalize(cwd: String) -> String {
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        let path = url.path
        // standardizedFileURL doesn't strip a trailing slash on macOS; do it
        // manually unless the path IS the root.
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }
}
```

- [ ] **Step 2: Remove the `GhosttyInjector` stub from `MessageInjector.swift`**

In `ClaudeIsland/Services/Injection/MessageInjector.swift`, delete the stub block:

```swift
struct GhosttyInjector: MessageInjector {
    let displayName = "ghostty"
    func canInject(into session: SessionState) async -> Bool { false }
    func inject(_ text: String, into session: SessionState) async -> Bool { false }
}
```

Leave the `TmuxInjector` stub in place — Task 4 replaces it.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -5
```

Expected: `** BUILD SUCCEEDED **`. Duplicate-symbol errors here mean the stub wasn't removed in Step 2.

- [ ] **Step 4: Sanity-check normalization in isolation (optional but cheap)**

Run a quick standalone Swift test from the command line — this does not require the test target:

```bash
swift -e 'import Foundation; let p = URL(fileURLWithPath: "/Users/bytedance/Code/pkmon-island/").standardizedFileURL.path; print(p)'
```

Expected output: `/Users/bytedance/Code/pkmon-island` (no trailing slash).

If it shows the trailing slash, the `dropLast()` branch in `normalize(cwd:)` handles it.

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/Services/Injection/GhosttyInjector.swift \
        ClaudeIsland/Services/Injection/MessageInjector.swift
git commit -m "Implement GhosttyInjector via NSAppleScript input text"
```

---

## Task 4: Implement `TmuxInjector` (with bracketed paste fix)

**Files:**
- Create: `ClaudeIsland/Services/Injection/TmuxInjector.swift`
- Modify: `ClaudeIsland/Services/Injection/MessageInjector.swift` — remove the `TmuxInjector` stub

This replaces the `tmux send-keys -l <text>` path that was misbehaving on `/`, `!`, `#`, and multi-line input. We write the text to a temp file (avoiding shell quoting and keeping `ProcessExecutor`'s API unchanged), then `tmux load-buffer -b name <path>` reads it, `paste-buffer -p` pastes with bracketed paste, `-d` cleans up the buffer.

> **Note on the temp-file approach:** I considered a stdin pipe so `load-buffer -` could read directly. `ProcessExecutor.run` does not expose stdin — adding it would widen a shared API just for tmux. The temp file is bounded, immediately deleted, and contains a single user message that's already going to live in Claude's transcript. This is the contained choice.

- [ ] **Step 1: Write `TmuxInjector.swift`**

```swift
//
//  TmuxInjector.swift
//  ClaudeIsland
//
//  Sends user text to a Claude session running inside tmux.
//  Replaces the old `tmux send-keys -l` path which lacked bracketed paste —
//  that caused leading '/' '!' '#' to flip Claude's TUI into a slash/bash/
//  memory mode and embedded newlines to auto-submit.
//
//  Approval keystrokes (1/2/n) are deliberately NOT routed through this
//  path: they live in ToolApprovalHandler and remain `send-keys -l`.
//

import Foundation

struct TmuxInjector: MessageInjector {
    let displayName = "tmux"

    private let bufferName = "__pkmon_inject"

    func canInject(into session: SessionState) async -> Bool {
        guard session.isInTmux, let tty = session.tty else { return false }
        return await findTarget(forTty: tty) != nil
    }

    func inject(_ text: String, into session: SessionState) async -> Bool {
        guard let tty = session.tty,
              let target = await findTarget(forTty: tty) else {
            injectLogger.error(
                "tmux inject: no pane for tty \(session.tty ?? "?", privacy: .public)"
            )
            return false
        }
        guard let tmux = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // Stage the text in a temp file so tmux load-buffer can read it
        // without us shell-quoting arbitrary user input.
        let tempPath = NSTemporaryDirectory()
            + "pkmon-inject-\(UUID().uuidString).txt"
        do {
            try text.write(toFile: tempPath, atomically: true, encoding: .utf8)
        } catch {
            injectLogger.error(
                "tmux inject: temp file write failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
        }

        let started = Date()
        do {
            // 1) Load the text from the temp file into a named buffer.
            _ = try await ProcessExecutor.shared.run(
                tmux,
                arguments: ["load-buffer", "-b", bufferName, tempPath]
            )

            // 2) Paste with bracketed-paste flag and delete the buffer after.
            _ = try await ProcessExecutor.shared.run(
                tmux,
                arguments: ["paste-buffer", "-p", "-d", "-b", bufferName, "-t", target.targetString]
            )

            // 3) Press Enter explicitly. Inside bracketed paste the text's
            //    own newlines are inert; we want exactly one submit.
            _ = try await ProcessExecutor.shared.run(
                tmux,
                arguments: ["send-keys", "-t", target.targetString, "Enter"]
            )

            let dur = Date().timeIntervalSince(started)
            injectLogger.info(
                "tmux inject \(session.sessionId.prefix(8), privacy: .public) \(text.count, privacy: .public)b ok=true \(String(format: "%.2f", dur), privacy: .public)s"
            )
            return true
        } catch {
            injectLogger.error(
                "tmux inject failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Internals

    /// Match a Claude session's tty against `tmux list-panes -a` output.
    private func findTarget(forTty tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }
        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )
            for line in output.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")
                if paneTty == tty {
                    return TmuxTarget(from: parts[0])
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
```

- [ ] **Step 2: Remove the `TmuxInjector` stub from `MessageInjector.swift`**

Delete the stub block:

```swift
struct TmuxInjector: MessageInjector {
    let displayName = "tmux"
    func canInject(into session: SessionState) async -> Bool { false }
    func inject(_ text: String, into session: SessionState) async -> Bool { false }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Services/Injection/TmuxInjector.swift \
        ClaudeIsland/Services/Injection/MessageInjector.swift
git commit -m "Implement TmuxInjector with bracketed paste via paste-buffer -p"
```

---

## Task 5: Wire `ChatView` to the Registry

**Files:**
- Modify: `ClaudeIsland/UI/Views/ChatView.swift`

Switch the chat view from "is in tmux?" to "does any injector accept this session?". The button's `sendMessage()` body is rewritten; the `sendToSession` and `findTmuxTarget` private helpers are deleted.

- [ ] **Step 1: Add the resolved-injector state**

Locate the `@State` block at the top of `ChatView` (around `ChatView.swift:17-27`). Add:

```swift
@State private var resolvedInjector: (any MessageInjector)?
@State private var lastInjectFailed: Bool = false
```

- [ ] **Step 2: Replace `canSendMessages`**

Find at `ChatView.swift:357-359`:

```swift
/// Can send messages only if session is in tmux
private var canSendMessages: Bool {
    session.isInTmux && session.tty != nil
}
```

Replace with:

```swift
/// True iff the registry has a backend that can route text to this session.
private var canSendMessages: Bool {
    resolvedInjector != nil
}
```

- [ ] **Step 3: Re-resolve the injector on view lifecycle**

In the existing `.task { ... }` block on the `ZStack` (around `ChatView.swift:94-113`), add resolution at the very top, before the `guard !hasLoadedOnce` line:

```swift
resolvedInjector = await MessageInjectorRegistry.shared.resolve(for: session)
```

Then add a fresh modifier right below the existing `.onReceive(sessionMonitor.$instances) { ... }` block (around `ChatView.swift:146-161`):

```swift
.onReceive(sessionMonitor.$instances) { sessions in
    if let updated = sessions.first(where: { $0.sessionId == sessionId }) {
        Task {
            resolvedInjector = await MessageInjectorRegistry.shared.resolve(for: updated)
        }
    }
}
```

Note: There is already an `.onReceive(sessionMonitor.$instances)` modifier doing other work — add this as a SECOND `.onReceive` modifier (SwiftUI runs both); do NOT merge into the existing one, to keep responsibilities separate.

- [ ] **Step 4: Rewrite `sendToSession` to delegate to the Registry**

Find at `ChatView.swift:481-488`:

```swift
private func sendToSession(_ text: String) async {
    guard session.isInTmux else { return }
    guard let tty = session.tty else { return }

    if let target = await findTmuxTarget(tty: tty) {
        _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
    }
}
```

Replace with:

```swift
private func sendToSession(_ text: String) async {
    let injector = resolvedInjector
        ?? (await MessageInjectorRegistry.shared.resolve(for: session))

    guard let injector else {
        lastInjectFailed = true
        return
    }

    let ok = await injector.inject(text, into: session)
    if ok {
        lastInjectFailed = false
        return
    }

    // First try failed. The session's environment may have shifted (Ghostty
    // closed the tab, TCC just got denied, tmux pane died) — re-resolve once.
    if let fresh = await MessageInjectorRegistry.shared.resolve(for: session),
       fresh.displayName != injector.displayName {
        let ok2 = await fresh.inject(text, into: session)
        lastInjectFailed = !ok2
    } else {
        lastInjectFailed = true
    }
}
```

- [ ] **Step 5: Delete the `findTmuxTarget` helper**

Find at `ChatView.swift:490-518`. Delete the entire `private func findTmuxTarget(tty:) async -> TmuxTarget? { ... }` method. It is no longer referenced.

- [ ] **Step 6: Build**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -5
```

Expected: `** BUILD SUCCEEDED **`. If you see "cannot find type 'TmuxTarget'" — that means an import was lost; `TmuxTarget` lives in `Services/Tmux/TmuxTarget.swift` (or similar) and may already be visible via Swift's module-internal linkage. Confirm by re-running.

- [ ] **Step 7: Commit**

```bash
git add ClaudeIsland/UI/Views/ChatView.swift
git commit -m "Route chat sends through MessageInjectorRegistry"
```

---

## Task 6: Update placeholder text and surface inject failures

**Files:**
- Modify: `ClaudeIsland/UI/Views/ChatView.swift`

The current placeholder hardcodes *"Open Claude Code in tmux to enable messaging"* — Ghostty is now a first-class option. Also wire a transient inline error chip when an inject fails (e.g. TCC denial, dead Ghostty tab).

- [ ] **Step 1: Replace the placeholder string**

Find at `ChatView.swift:363`:

```swift
TextField(canSendMessages ? "Message Claude..." : "Open Claude Code in tmux to enable messaging", text: $inputText)
```

Replace with:

```swift
TextField(canSendMessages
            ? "Message Claude..."
            : "Open Claude Code in Ghostty or tmux to enable messaging",
          text: $inputText)
```

- [ ] **Step 2: Add an inline error chip below the input bar**

Locate the `inputBar` computed property (around `ChatView.swift:361-407`). Wrap the existing `HStack` in a `VStack(spacing: 6)` and add a chip that renders when `lastInjectFailed` is true. Replace the body of `inputBar` with:

```swift
private var inputBar: some View {
    VStack(spacing: 6) {
        if lastInjectFailed {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("Send failed. If using Ghostty, grant Automation permission in System Settings → Privacy & Security → Automation.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                Spacer()
                Button {
                    lastInjectFailed = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        HStack(spacing: 10) {
            TextField(canSendMessages
                        ? "Message Claude..."
                        : "Open Claude Code in Ghostty or tmux to enable messaging",
                      text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(canSendMessages ? .white : .white.opacity(0.4))
                .focused($isInputFocused)
                .disabled(!canSendMessages)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessages ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!canSendMessages || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessages || inputText.isEmpty)
        }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color.black.opacity(0.2))
    .overlay(alignment: .top) {
        LinearGradient(
            colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 24)
        .offset(y: -24)
        .allowsHitTesting(false)
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: lastInjectFailed)
    .zIndex(1)
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/UI/Views/ChatView.swift
git commit -m "Update chat placeholder and surface inject failures inline"
```

---

## Task 7: Remove dead code in `ToolApprovalHandler` and `TmuxController`

**Files:**
- Modify: `ClaudeIsland/Services/Tmux/ToolApprovalHandler.swift`
- Modify: `ClaudeIsland/Services/Tmux/TmuxController.swift`

After Task 5, `ToolApprovalHandler.sendMessage` and `TmuxController.sendMessage` have no callers. Delete them so the only message-sending path is the Registry.

**Important:** Do NOT touch `approveOnce`, `approveAlways`, or `reject` in `ToolApprovalHandler`. Those still send `1`/`2`/`n` via `send-keys -l`, which is correct for modal approval prompts (CLAUDE.md flags this as load-bearing).

- [ ] **Step 1: Remove `sendMessage` from `ToolApprovalHandler`**

In `ClaudeIsland/Services/Tmux/ToolApprovalHandler.swift`, delete lines 46-49:

```swift
    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: message, pressEnter: true)
    }
```

- [ ] **Step 2: Remove `sendMessage` from `TmuxController`**

In `ClaudeIsland/Services/Tmux/TmuxController.swift`, delete lines 24-26:

```swift
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(message, to: target)
    }
```

- [ ] **Step 3: Verify nothing else calls these**

```bash
grep -rn 'ToolApprovalHandler.shared.sendMessage\|TmuxController.shared.sendMessage' \
    /Users/bytedance/Code/pkmon-island/ClaudeIsland/
```

Expected: no output. If any callers remain, route them to `MessageInjectorRegistry.shared.resolve(...)` first; do not reintroduce `sendMessage` on those types.

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/Services/Tmux/ToolApprovalHandler.swift \
        ClaudeIsland/Services/Tmux/TmuxController.swift
git commit -m "Remove unused sendMessage helpers; injection lives in Registry"
```

---

## Task 8: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

Document the new boundary so future sessions don't conflate approvals with message injection.

- [ ] **Step 1: Add a new section**

After the existing `## Approval keystrokes (Services/Tmux/ToolApprovalHandler.swift)` section in `CLAUDE.md`, add:

```markdown
## Message injection vs approvals — they are NOT the same channel

- **Approvals** (Allow/Deny/Reject) go through `HookSocketServer`'s open
  socket; they're a hook-protocol RPC and have nothing to do with tmux or
  the user's terminal.
- **Replies in the chat panel** go through `Services/Injection/`. The
  Registry picks `GhosttyInjector` (NSAppleScript `input text`, which
  Ghostty 1.3+ routes through `completeClipboardPaste` — the Cmd+V path,
  including bracketed paste) when Claude is running in Ghostty, and falls
  back to `TmuxInjector` (`tmux load-buffer` + `paste-buffer -p -d`) when
  it's in tmux. **Do not "fix" the inject path back to `send-keys -l`** —
  that path doesn't engage bracketed paste, so `/`, `!`, `#`, and embedded
  newlines get misinterpreted by Claude's TUI.
- `ToolApprovalHandler.approveOnce/approveAlways/reject` deliberately
  still use `send-keys -l "1"|"2"|"n"`. The approval prompt is a modal
  expecting a single character, not a paste — leaving those alone.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Document approval vs message-injection channel split in CLAUDE.md"
```

---

## Task 9: Manual smoke checklist (the only real test)

**Files:** None.

This codebase has no test target — correctness is established here. Run through every check below and capture results in your final summary. Do not skip.

- [ ] **Build a Release binary and launch it**

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
open /path/to/built/ClaudeIsland.app
```

Find the binary path with:

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug -showBuildSettings 2>/dev/null | grep -E 'BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME'
```

- [ ] **G1 — Ghostty + plain text**: Open Ghostty, run `claude` in your project dir. From the chat panel, send `hello`. Claude turns up `hello` as a user message.

- [ ] **G2 — Ghostty + leading slash**: Send `/help` (literal). Verify Claude does NOT enter slash-command mode and shows `/help` as the user message text. This is the regression case for the bracketed-paste fix.

- [ ] **G3 — Ghostty + multi-line**: Send a 3-line message containing literal newlines. Claude shows a single user message with three lines, not three separate submits.

- [ ] **G4 — Ghostty installed but Claude in iTerm**: Quit Ghostty (or run Claude in a non-Ghostty terminal). The input bar's placeholder reads `Open Claude Code in Ghostty or tmux to enable messaging`; the field is disabled.

- [ ] **G5 — TCC permission denied**: With Ghostty running, go to *System Settings → Privacy & Security → Automation* and **revoke** ClaudeIsland's permission to control Ghostty. From the chat panel, attempt to send a message. The orange chip appears with the System Settings instruction; nothing reaches Claude. Then re-grant the permission and confirm the next send works.

- [ ] **G6 — Ghostty fall-through to tmux**: Run Claude inside tmux WHILE Ghostty is also open with the same cwd. Confirm the Registry prefers Ghostty (only one path is exercised; you can verify in `Console.app` filtering subsystem `com.claudeisland` category `Inject`).

- [ ] **T1 — tmux + leading slash**: Run Claude in tmux only (no Ghostty match). Send `/help`. Claude shows `/help` as a user message, NOT entering slash mode. Regression for the old `send-keys -l` bug.

- [ ] **T2 — tmux + multi-line**: Send 3-line content. Single user message, three lines preserved.

- [ ] **T3 — Approvals untouched**: Trigger a tool that requires approval (e.g. `Bash` with a non-allowlisted command). Verify the *Allow* and *Deny* buttons still work end-to-end. They should — they go through `HookSocketServer`, not the Registry.

- [ ] **T4 — Approval keystroke still `1`/`n`**: From a tmux pane, run a tool that approval-prompts. Click *Allow* in the panel. Confirm via `Console.app` you see `Approval` category logs and NOT `Inject` category logs. (Inject path must not be triggered by approvals.)

- [ ] **Final commit (only if any docs / smoke notes were updated)**

```bash
git status
# If anything tracked changed, commit it. Otherwise, nothing to do.
```

- [ ] **Report**

When summarizing the implementation, write:
> Manual smoke checklist G1–G6 and T1–T4 passed.

Or list which ones failed — never claim "tested" without going through this list (CLAUDE.md is explicit about this).

---

## Out of scope (do NOT add to this plan)

- Kitty / iTerm2 / WezTerm injectors. Interface is ready; add later if users ask.
- An "auto-launch Claude in Ghostty" button.
- Disambiguation UI when multiple Ghostty terminals match `cwd` (current behavior: take the first match — fine until proven otherwise).
- Any change to the approval channel (`HookSocketServer`, `ToolApprovalHandler.approveOnce/approveAlways/reject`).
