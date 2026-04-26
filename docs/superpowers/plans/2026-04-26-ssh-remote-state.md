# SSH Remote Claude Session State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Vibe Notch see, control, and inject messages into Claude Code sessions running on a single SSH-reachable dev VM, with the same fidelity as local sessions.

**Architecture:** A dedicated persistent `ssh -N -R` reverse-Unix-socket tunnel ferries hook events from the remote `/tmp/claude-island.sock` to a Mac-side per-host listener. `SessionStore` is host-agnostic; ingress tags every event with `host` before processing. Approval RPCs ride the same tunnel back; chat injection reuses `GhosttyInjector` since the user's Ghostty SSH tab already owns the remote claude's pty.

**Tech Stack:** Swift 5.9 + SwiftUI + Combine on macOS 13+. OpenSSH client (system-provided). No new test target — pkmon-island has none (per CLAUDE.md). Verification is build-success + manual smoke per task.

**Spec:** `docs/superpowers/specs/2026-04-26-ssh-remote-state-design.md`

**Verification convention for every task** (since there's no XCTest):
- "Build" step: `xcodebuild -scheme ClaudeIsland -configuration Debug build` exits 0
- "Smoke" step: launch the app, exercise the touched code path, watch Console.app filter `subsystem:com.claudeisland` for the expected log line
- Commits use Conventional-Commit-ish prefixes (`feat:`, `refactor:`, `fix:`) consistent with the repo's recent history (e.g. commit `0b31e50`).

**Scope reminder (from spec § Non-goals):** No multi-host UI in v1, no ProxyJump UI, no password / OTP / device-cert, no remote tmux mode, no remote JSONL parsing, no offline buffering, no Linux/Windows clients.

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `ClaudeIsland/Models/SessionHost.swift` | `SessionHost` enum (`.local` / `.remote(name:)`), `RemoteConnectionState` enum |
| `ClaudeIsland/Models/RemoteHost.swift` | User-facing remote host config (`name`, `sshTarget`, `enabled`) |
| `ClaudeIsland/Services/Remote/RemoteHostRegistry.swift` | Loads/saves `[RemoteHost]` to `UserDefaults` |
| `ClaudeIsland/Services/Remote/SSHCommandRunner.swift` | Wrapper around `Process` for `ssh`/`scp` with `BatchMode=yes` + timeout |
| `ClaudeIsland/Services/Remote/SSHBridge.swift` | Single host's `ssh -N -R` lifecycle, exponential-backoff reconnect |
| `ClaudeIsland/Services/Remote/SSHBridgeController.swift` | Multi-host orchestration; sleep/wake hooks |
| `ClaudeIsland/Services/Remote/RemoteHookInstaller.swift` | SCP hook script + merge remote `~/.claude/settings.json` |
| `ClaudeIsland/Services/Injection/GhosttySurfaceMatcher.swift` | Match Ghostty surface → SSH child for remote sessions |
| `ClaudeIsland/UI/Views/RemoteHostsSection.swift` | Inline section for `NotchMenuView` |
| `docs/superpowers/spike-results-2026-04-26.md` | Phase-0 spike findings (informs Phase 7) |

### Modified files

| Path | Change |
|---|---|
| `ClaudeIsland/Models/SessionState.swift` | Add `host: SessionHost` and `connectionState: RemoteConnectionState?` |
| `ClaudeIsland/Services/Hooks/HookSocketServer.swift` | Drop singleton; per-instance `socketPath` + `host`; ingress tags events |
| `ClaudeIsland/Services/State/SessionStore.swift` | `createSession` takes host; bridge-state mutator; 5-min idle rule skips reconnecting |
| `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift` | Manages multiple `HookSocketServer` instances keyed by host |
| `ClaudeIsland/App/AppDelegate.swift` | Boots `SSHBridgeController` after monitor; wires sleep/wake notifications |
| `ClaudeIsland/Services/Injection/GhosttyInjector.swift` | Use `GhosttySurfaceMatcher` for `host == .remote(...)` sessions |
| `ClaudeIsland/UI/Views/NotchMenuView.swift` | Embed `RemoteHostsSection` |

---

## Phase 0 — Spike

### Task 1: Phase 0 spike — verify SSH and Ghostty assumptions

**Files:**
- Create: `docs/superpowers/spike-results-2026-04-26.md`

This is a research task. The spec assumes (a) `ssh -N -R` with `StreamLocalBindUnlink=yes` works against the user's actual dev VM, and (b) we can identify which Ghostty surface owns an SSH child process. If either is wrong, later phases need a different approach. Output is a written findings doc.

- [ ] **Step 1: Confirm OpenSSH client supports the flags we want**

Run: `ssh -V`

Expected: `OpenSSH_X.Y` where X.Y ≥ `6.7`. (`StreamLocalBindUnlink` landed in 6.7.)

Record version in spike-results.

- [ ] **Step 2: From Mac, sanity-check reverse Unix-socket forwarding to the dev VM**

Open one terminal as the SSH bridge:

```bash
ssh -N -v \
    -o BatchMode=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StreamLocalBindUnlink=yes \
    -R /tmp/claude-island.sock:/tmp/claude-island-spike.sock \
    <sshTarget>
```

In another Mac terminal start a one-shot listener that mimics what `HookSocketServer` will do:

```bash
nc -lU /tmp/claude-island-spike.sock
```

SSH into the dev VM (separate tab) and:

```bash
echo '{"hello":"from-remote"}' | nc -U /tmp/claude-island.sock
```

Expected: the JSON appears on the Mac listener within ~1s.

- [ ] **Step 3: Confirm `StreamLocalBindUnlink=yes` clears stale remote socket**

On the dev VM, intentionally pre-create a stale file:

```bash
touch /tmp/claude-island.sock
```

Restart the bridge from Step 2. Expected: ssh starts cleanly (no `bind failed` in the `-v` output) — meaning the option is honored. If it fails, record this and add a `ssh ... 'rm -f /tmp/claude-island.sock'` pre-step to the bridge startup later.

- [ ] **Step 4: Spike Ghostty surface → SSH child detection**

While the user's normal Ghostty SSH tab to dev-vm is open and idle, run this from a Mac shell:

```bash
osascript -e 'tell application "Ghostty" to get tty of every terminal'
```

Expected: a list of `/dev/ttysNN` strings, one per Ghostty surface.

For each tty, walk the process tree:

```bash
TTY=ttys005   # one of the values returned above
ps -t "$TTY" -o pid,command
```

Expected: among the printed processes is at least one `ssh ... <sshTarget>` invocation (or its children). Record the `ps -t` output for one Ghostty SSH tab — this confirms that `ProcessTreeBuilder` walking from a Ghostty surface tty can reach a process whose command line contains the user's SSH target. This is the data we'll use in Phase 7.

If `ps -t` returns nothing useful (some shells fork into a session leader the kernel doesn't report under the tty), fall back to `lsof -t /dev/$TTY` followed by `ps -o command -p <pid>` per pid. Record which path worked.

- [ ] **Step 5: Write findings doc**

Create `docs/superpowers/spike-results-2026-04-26.md`:

```markdown
# SSH-remote spike findings — 2026-04-26

## OpenSSH client version
<paste `ssh -V` output>

## Reverse Unix-socket forwarding
- ✅ / ❌ Step 2 byte transit confirmed
- ✅ / ❌ `StreamLocalBindUnlink=yes` cleared stale remote socket
- (If ❌) Fallback chosen: `ssh <target> 'rm -f /tmp/claude-island.sock'` pre-step before tunnel

## Ghostty surface → SSH child
- AppleScript `tty of every terminal` returned: <example>
- `ps -t <tty>` showed: <example, redacted>
- Method that worked for finding SSH child: `ps -t` / `lsof -t` / both
- Concern (if any): <free text>

## Action items for Phase 7
- <e.g. "use lsof, not ps -t, on macOS Sonoma">
- <e.g. "Ghostty 1.4 still surfaces tty in sdef — good">
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/spike-results-2026-04-26.md
git commit -m "docs: spike findings for ssh-remote bridge and ghostty surface detection"
```

**Stop and review with the user.** If either spike answer is "no", revisit the design before continuing.

---

## Phase 1 — Data Model

### Task 2: Add `SessionHost` and `RemoteConnectionState`

**Files:**
- Create: `ClaudeIsland/Models/SessionHost.swift`

- [ ] **Step 1: Create the file**

```swift
//
//  SessionHost.swift
//  ClaudeIsland
//
//  Identifies which machine a Claude session lives on. Local is the Mac;
//  remote is a configured SSH host. The `name` in `.remote` is the
//  user-visible alias (RemoteHost.name), not the SSH target — the alias is
//  stable across user edits to ~/.ssh/config.
//

import Foundation

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
```

- [ ] **Step 2: Add to Xcode target**

The `.swift` file must be added to the `ClaudeIsland` Xcode target so it compiles. From a shell:

```bash
# Verify the file is detected by the project (xcodebuild lists added sources)
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -showBuildSettings 2>/dev/null | grep PROJECT_DIR
```

If your editor (VS Code etc.) didn't auto-add it, open `ClaudeIsland.xcodeproj` in Xcode and drag `SessionHost.swift` into the `Models` group; ensure target membership = `ClaudeIsland`.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Models/SessionHost.swift ClaudeIsland.xcodeproj
git commit -m "feat: add SessionHost and RemoteConnectionState enums"
```

---

### Task 3: Extend `SessionState` with host + connectionState

**Files:**
- Modify: `ClaudeIsland/Models/SessionState.swift`

- [ ] **Step 1: Add fields and update initializer**

In `SessionState`, after the `// MARK: - Instance Metadata` section (around line 24), add:

```swift
    // MARK: - Host

    /// Which machine this session is running on. Local sessions get .local;
    /// SSH-remote sessions are tagged at HookSocketServer ingress.
    var host: SessionHost

    /// Bridge connectivity overlay (only meaningful for .remote hosts).
    /// nil for local sessions.
    var connectionState: RemoteConnectionState?
```

Update the initializer signature and body. Replace the existing `nonisolated init(...)` block (lines 72–107) with:

```swift
    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        host: SessionHost = .local,
        connectionState: RemoteConnectionState? = nil,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date(),
        phaseBeforeCompacting: SessionPhase? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        let defaultName = URL(fileURLWithPath: cwd).lastPathComponent
        self.projectName = projectName ?? defaultName
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.host = host
        self.connectionState = connectionState
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
        self.phaseBeforeCompacting = phaseBeforeCompacting
    }
```

- [ ] **Step 2: Add a host-aware `displayProjectName` derived property**

After `var displayTitle: String { … }` (around line 137), add:

```swift
    /// Project name as shown in the session list. Remote sessions are
    /// prefixed with the host alias so users can tell "monorepo on dev-vm"
    /// apart from "monorepo locally".
    var displayProjectName: String {
        switch host {
        case .local:
            return projectName
        case .remote(let name):
            return "\(name):\(projectName)"
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`. (All existing call sites of `SessionState.init` use defaulted args, so adding host/connectionState as defaulted parameters is source-compatible.)

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Models/SessionState.swift
git commit -m "feat: add host and connectionState to SessionState"
```

---

### Task 4: Make `HookSocketServer` instantiable

**Files:**
- Modify: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`

The current class is a `static let shared` singleton with a fixed `static let socketPath`. We're switching to per-instance servers so we can run one for local and one per remote host. The singleton is removed; callers will be updated in Task 5.

- [ ] **Step 1: Replace singleton with instance fields**

In `HookSocketServer.swift`, replace the lines:

```swift
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/claude-island.sock"

    private var serverSocket: Int32 = -1
```

with:

```swift
class HookSocketServer {
    /// Path to the listening Unix domain socket (instance-scoped).
    let socketPath: String

    /// Host tag stamped onto every event accepted on this server before
    /// it reaches SessionStore. Local server: `.local`. Per-remote server:
    /// `.remote(name:)`.
    let host: SessionHost

    private var serverSocket: Int32 = -1
```

Replace the `private init() {}` (around line 128) with:

```swift
    init(socketPath: String, host: SessionHost) {
        self.socketPath = socketPath
        self.host = host
    }
```

- [ ] **Step 2: Replace every `Self.socketPath` use with `socketPath`**

In the same file, search for `Self.socketPath` and replace each occurrence with `socketPath`:

- Line ~143 (`unlink(Self.socketPath)`) → `unlink(socketPath)`
- Line ~156 (`Self.socketPath.withCString`) → `socketPath.withCString`
- Line ~177 (`chmod(Self.socketPath, 0o600)`) → `chmod(socketPath, 0o600)`
- Line ~186 (`logger.info("Listening on \(Self.socketPath...`) → `logger.info("Listening on \(socketPath, ...`
- Line ~205 (`unlink(Self.socketPath)`) → `unlink(socketPath)`

- [ ] **Step 3: Stamp host onto every accepted event**

Find the `private func handleClient(_ clientSocket: Int32)` method (around line 370). Locate the line:

```swift
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
```

After the `event` variable is decoded, **before** any use of it (i.e. before `logger.debug("Received: \(event.event...`), add a let-rebinding that injects host context. Since `HookEvent` from JSON has no `host` field, we route the host through a separate channel: change the event handler typealias and pass host alongside. Replace the typealias:

```swift
typealias HookEventHandler = @Sendable (HookEvent) -> Void
```

with:

```swift
typealias HookEventHandler = @Sendable (HookEvent, SessionHost) -> Void
```

Update every call to `eventHandler?(event)` and `eventHandler?(updatedEvent)` to pass `host` as the second argument:

- `eventHandler?(event)` at line ~433 → `eventHandler?(event, host)`
- `eventHandler?(updatedEvent)` at line ~464 → `eventHandler?(updatedEvent, host)`
- `eventHandler?(event)` at line ~470 → `eventHandler?(event, host)`

- [ ] **Step 4: Build (expected to fail at call sites)**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: build fails with errors at `HookSocketServer.shared` references in `ClaudeSessionMonitor.swift`. This is fine — Task 5 fixes them. Note the failing call sites for Task 5.

- [ ] **Step 5: Commit (broken build is OK with reason in message)**

```bash
git add ClaudeIsland/Services/Hooks/HookSocketServer.swift
git commit -m "refactor: make HookSocketServer instantiable per host

Drops the .shared singleton in favor of per-instance socketPath and
host tag. Callers will be migrated in the next commit; this commit
intentionally leaves ClaudeSessionMonitor unbuildable."
```

---

### Task 5: Update `ClaudeSessionMonitor` to manage multiple servers

**Files:**
- Modify: `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift`

- [ ] **Step 1: Read the current file to know its full surface**

Read `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift` end-to-end. Identify every use of `HookSocketServer.shared` (there are at least 5 per the grep in the spike).

- [ ] **Step 2: Add a host-keyed servers dictionary**

At the top of the class, add:

```swift
    /// One HookSocketServer per host. Local lives at `.local`; remote
    /// hosts live at `.remote(name:)`.
    private var servers: [SessionHost: HookSocketServer] = [:]

    private static let localSocketPath = "/tmp/claude-island.sock"

    static func remoteSocketPath(for hostName: String) -> String {
        "/tmp/claude-island-\(hostName).sock"
    }
```

- [ ] **Step 3: Rewrite `startMonitoring` to construct the local server**

Replace the body of `startMonitoring()` so that it builds a local `HookSocketServer` and starts it. The call to `start(onEvent:)` now takes a closure with two args (`HookEvent, SessionHost`):

```swift
    func startMonitoring() {
        startServer(host: .local, socketPath: Self.localSocketPath)
    }

    /// Spin up a HookSocketServer for one host. Idempotent — if a server
    /// already exists for that host, this is a no-op.
    func startServer(host: SessionHost, socketPath: String) {
        guard servers[host] == nil else { return }
        let server = HookSocketServer(socketPath: socketPath, host: host)
        server.start(
            onEvent: { event, eventHost in
                Task {
                    await SessionStore.shared.process(.hookReceived(event, host: eventHost))
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
```

- [ ] **Step 4: Replace every `HookSocketServer.shared.<method>` call**

In the same file:

- `HookSocketServer.shared.cancelPendingPermissions(...)` → loop over `servers.values` and call on each (the cache entry only exists on one of them)
- `HookSocketServer.shared.cancelPendingPermission(...)` → same
- `HookSocketServer.shared.respondToPermission(...)` → same
- `HookSocketServer.shared.stop()` (in teardown) → loop over `servers.values`, then `servers.removeAll()`

Concretely, find each site and replace with the loop pattern:

```swift
for server in servers.values {
    server.respondToPermission(toolUseId: toolUseId, decision: decision, reason: reason)
}
```

The `respondToPermission` implementation is host-agnostic — it's a no-op for servers that don't hold the matching `pendingPermission`. So the loop is correct and cheap.

- [ ] **Step 5: Update `SessionEvent.hookReceived` to carry host**

Open `ClaudeIsland/Services/State/SessionEvent.swift` (or wherever `enum SessionEvent` is defined — `grep -rn "case hookReceived" ClaudeIsland`).

Change:

```swift
case hookReceived(HookEvent)
```

to:

```swift
case hookReceived(HookEvent, host: SessionHost)
```

In `SessionStore.process(_:)`, update the matching case:

```swift
case .hookReceived(let hookEvent, let host):
    await processHookEvent(hookEvent, host: host)
```

In `processHookEvent`, change the signature to:

```swift
private func processHookEvent(_ event: HookEvent, host: SessionHost) async {
```

And pass `host` into `createSession`:

```swift
var session = sessions[sessionId] ?? createSession(from: event, host: host)
```

Update `createSession`:

```swift
private func createSession(from event: HookEvent, host: SessionHost) -> SessionState {
    SessionState(
        sessionId: event.sessionId,
        cwd: event.cwd,
        projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
        pid: event.pid,
        tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
        isInTmux: false,  // Will be updated for local; stays false for remote
        host: host,
        phase: .idle
    )
}
```

In the `processHookEvent` body, gate the local-only `ProcessTreeBuilder.isInTmux` call:

Replace:

```swift
session.pid = event.pid
if let pid = event.pid {
    let tree = ProcessTreeBuilder.shared.buildTree()
    session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
}
```

with:

```swift
session.pid = event.pid
if session.host == .local, let pid = event.pid {
    let tree = ProcessTreeBuilder.shared.buildTree()
    session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
}
```

- [ ] **Step 6: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Smoke test (local-only behavior unchanged)**

Launch the app. In a terminal:

```bash
claude --version
# start a tiny throw-away claude session in one project to fire some hook events
cd /tmp && mkdir -p plan-smoke && cd plan-smoke && claude
```

Type any prompt, watch Vibe Notch's island/menu populate. In Console.app filter `subsystem:com.claudeisland category:Hooks`. Expected: events flow as before; no new errors. Quit claude and confirm session leaves the list.

- [ ] **Step 8: Commit**

```bash
git add ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift \
        ClaudeIsland/Services/State/SessionStore.swift \
        ClaudeIsland/Services/State/SessionEvent.swift
git commit -m "refactor: route hook events through host-keyed servers"
```

---

## Phase 2 — Persistence

### Task 6: `RemoteHost` model + `RemoteHostRegistry`

**Files:**
- Create: `ClaudeIsland/Models/RemoteHost.swift`
- Create: `ClaudeIsland/Services/Remote/RemoteHostRegistry.swift`

- [ ] **Step 1: Create `RemoteHost.swift`**

```swift
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
```

- [ ] **Step 2: Create `RemoteHostRegistry.swift`**

```swift
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
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Models/RemoteHost.swift \
        ClaudeIsland/Services/Remote/RemoteHostRegistry.swift \
        ClaudeIsland.xcodeproj
git commit -m "feat: add RemoteHost model and persistent registry"
```

---

## Phase 3 — SSH transport primitives

### Task 7: `SSHCommandRunner` utility

**Files:**
- Create: `ClaudeIsland/Services/Remote/SSHCommandRunner.swift`

This is the only place we shell out to `ssh`/`scp`. Centralizing it lets us enforce `BatchMode=yes` and timeouts everywhere.

- [ ] **Step 1: Create the file**

```swift
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
                    let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let result = Result(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: stdoutData ?? Data(), encoding: .utf8) ?? "",
                        stderr: String(data: stderrData ?? Data(), encoding: .utf8) ?? ""
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
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke (manual one-liner)**

We can't unit-test this (no test target). Add a temporary debug entry point inside `AppDelegate.applicationDidFinishLaunching`, behind a `#if DEBUG` block, to fire one ssh command at app launch:

```swift
#if DEBUG
Task {
    do {
        let result = try await SSHCommandRunner.run(
            target: "<your-actual-sshTarget>",
            remoteCommand: "echo hello-from-vibe-notch"
        )
        NSLog("SSH smoke: ok=%@ stdout=%@ stderr=%@",
              "\(result.ok)", result.stdout, result.stderr)
    } catch {
        NSLog("SSH smoke failed: %@", "\(error)")
    }
}
#endif
```

Run the app once; check Console.app for the `SSH smoke:` line; expected `ok=true stdout=hello-from-vibe-notch`. **Remove the debug block before committing** — the app should not run unsolicited SSH at every launch.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Services/Remote/SSHCommandRunner.swift ClaudeIsland.xcodeproj
git commit -m "feat: add SSHCommandRunner with BatchMode and timeout"
```

---

### Task 8: `SSHBridge` actor (long-running tunnel + reconnect)

**Files:**
- Create: `ClaudeIsland/Services/Remote/SSHBridge.swift`

- [ ] **Step 1: Create the file**

```swift
//
//  SSHBridge.swift
//  ClaudeIsland
//
//  Owns one persistent `ssh -N -R` reverse-Unix-socket tunnel for one
//  RemoteHost. Auto-reconnects with exponential backoff. Reports state
//  changes via the closure passed to `start`.
//
//  This is intentionally NOT routed through SSHCommandRunner — that helper
//  is one-shot. The tunnel needs the long-running Process handle so we
//  can SIGTERM on stop and observe stderr.
//

import Foundation
import os.log

private let bridgeLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

actor SSHBridge {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(reason: String)
    }

    let host: RemoteHost

    private var process: Process?
    private(set) var state: State = .idle
    private var reconnectTask: Task<Void, Never>?

    /// Callback fires on every state change. Invoked on the actor; do
    /// any UI hop on the receiving side.
    private var onStateChange: ((State) -> Void)?

    private static let backoffSchedule: [UInt64] = [1, 2, 4, 8, 16, 30, 60]
    private static let backoffMaxNs: UInt64 = 60 * 1_000_000_000

    init(host: RemoteHost) {
        self.host = host
    }

    func start(onStateChange: @escaping (State) -> Void) {
        self.onStateChange = onStateChange
        Task { await self.connectLoop() }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        terminateProcess()
        Task { await cleanupRemoteSocket() }
        setState(.idle)
    }

    // MARK: - Internal

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }

    private func connectLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            let exitedCleanly = await runOnce()
            if Task.isCancelled || state == .idle { return }
            attempt += 1
            let waitNs = backoff(forAttempt: attempt)
            bridgeLogger.info(
                "SSH tunnel for \(self.host.name, privacy: .public) exited (clean=\(exitedCleanly, privacy: .public)); reconnecting in \(waitNs / 1_000_000_000, privacy: .public)s"
            )
            try? await Task.sleep(nanoseconds: waitNs)
        }
    }

    /// Runs one ssh -N -R subprocess to completion. Returns true on
    /// expected (clean) exit, false if it died unexpectedly.
    private func runOnce() async -> Bool {
        let socketPath = "/tmp/claude-island.sock"
        let macSocketPath = "/tmp/claude-island-\(host.name).sock"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = SSHCommandRunner.baseSSHArgs + [
            "-N",
            "-o", "ControlMaster=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-R", "\(socketPath):\(macSocketPath)",
            host.sshTarget,
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
        } catch {
            setState(.failed(reason: "launch ssh: \(error.localizedDescription)"))
            return false
        }
        process = proc

        // Switch state to connected only once ssh has had a moment to
        // establish forwarding. ExitOnForwardFailure=yes means ssh will
        // exit fast if the bind fails, so a 1s probe is sufficient.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if proc.isRunning {
            setState(.connected)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in continuation.resume() }
        }

        let stderr = (try? stderrPipe.fileHandleForReading.readToEnd()).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        if !stderr.isEmpty {
            bridgeLogger.error(
                "SSH tunnel for \(self.host.name, privacy: .public) stderr: \(stderr, privacy: .public)"
            )
        }
        process = nil
        return proc.terminationStatus == 0
    }

    private func terminateProcess() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    private func cleanupRemoteSocket() async {
        // Best-effort. If this fails we'll rely on StreamLocalBindUnlink
        // on the next start.
        _ = try? await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "rm -f /tmp/claude-island.sock",
            timeout: 5
        )
    }

    private func backoff(forAttempt attempt: Int) -> UInt64 {
        let idx = min(attempt - 1, Self.backoffSchedule.count - 1)
        let seconds = Self.backoffSchedule[max(idx, 0)]
        let ns = UInt64(seconds) * 1_000_000_000
        return min(ns, Self.backoffMaxNs)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/Services/Remote/SSHBridge.swift ClaudeIsland.xcodeproj
git commit -m "feat: add SSHBridge actor with reconnect loop"
```

---

### Task 9: `SSHBridgeController` orchestrator + sleep/wake

**Files:**
- Create: `ClaudeIsland/Services/Remote/SSHBridgeController.swift`
- Modify: `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift` (call site only)

- [ ] **Step 1: Create the file**

```swift
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
```

- [ ] **Step 2: Add `knownRemoteHostNames` and turn `ClaudeSessionMonitor` into `.shared`**

In `ClaudeSessionMonitor.swift`:

- Make it a `@MainActor final class ClaudeSessionMonitor` with `static let shared = ClaudeSessionMonitor()` (if it isn't already a singleton).
- Add a computed accessor:

```swift
    var knownRemoteHostNames: [String] {
        servers.keys.compactMap {
            if case .remote(let name) = $0 { return name }
            return nil
        }
    }
```

If `ClaudeSessionMonitor` is currently constructed by AppDelegate (`coreSessionMonitor = ClaudeSessionMonitor()`), keep that init too — make `shared` reach the same instance:

```swift
    private static var sharedInstance: ClaudeSessionMonitor?
    static var shared: ClaudeSessionMonitor {
        if let s = sharedInstance { return s }
        let new = ClaudeSessionMonitor()
        sharedInstance = new
        return new
    }
    init() { Self.sharedInstance = self }
```

- [ ] **Step 3: Add `bridgeStateChanged` event to `SessionEvent`**

In `ClaudeIsland/Services/State/SessionEvent.swift` add the case:

```swift
case bridgeStateChanged(host: SessionHost, state: RemoteConnectionState?)
```

In `SessionStore.process(_:)` add the matching branch:

```swift
case .bridgeStateChanged(let host, let state):
    await processBridgeStateChange(host: host, state: state)
```

Implement `processBridgeStateChange` in `SessionStore`:

```swift
private func processBridgeStateChange(host: SessionHost, state: RemoteConnectionState?) async {
    for (id, var session) in sessions where session.host == host {
        session.connectionState = state
        sessions[id] = session
    }
    publishState()
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/Services/Remote/SSHBridgeController.swift \
        ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift \
        ClaudeIsland/Services/State/SessionStore.swift \
        ClaudeIsland/Services/State/SessionEvent.swift \
        ClaudeIsland.xcodeproj
git commit -m "feat: add SSHBridgeController with sleep/wake reconciliation"
```

---

### Task 10: Boot the bridge controller from AppDelegate; patch 5-min idle rule

**Files:**
- Modify: `ClaudeIsland/App/AppDelegate.swift`
- Modify: `ClaudeIsland/Services/State/SessionStore.swift`

- [ ] **Step 1: Wire SSHBridgeController into app launch**

In `AppDelegate.swift`, after `coreSessionMonitor?.startMonitoring()` (around line 81), add:

```swift
SSHBridgeController.shared.start()
```

- [ ] **Step 2: Patch the 5-minute stale-active rule**

Find the periodic stale-check in `SessionStore.swift`. Search:

```bash
grep -n "staleActivePhaseThreshold\|5.*60\|forceIdle" ClaudeIsland/Services/State/SessionStore.swift
```

Wherever the rule iterates sessions and forces `.processing`/`.compacting` to `.idle` after `now - lastActivity > threshold`, add a guard at the top of the per-session check:

```swift
// Don't force-idle a session whose host bridge is mid-reconnect — the
// hook silence is the network's fault, not Claude's.
if case .reconnecting = session.connectionState { continue }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke (with no remote host configured yet)**

Launch the app. In Console.app filter `subsystem:com.claudeisland category:Remote`. Expected: a single line `Suspending 0 bridges` would NOT appear (it shouldn't fire spontaneously); however on Mac sleep/wake you'd see lifecycle logs. With no hosts configured, `start()` is a no-op — local sessions still work as before.

Verify a local session still flows through the menu/island normally.

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/App/AppDelegate.swift ClaudeIsland/Services/State/SessionStore.swift
git commit -m "feat: boot SSHBridgeController and skip stale-idle rule during reconnect"
```

---

## Phase 4 — Remote hook installation

### Task 11: `RemoteHookInstaller` — install/uninstall

**Files:**
- Create: `ClaudeIsland/Services/Remote/RemoteHookInstaller.swift`

The bundled hook script is `claude-island-state.py` (verified by Task 1 / `HookInstaller.swift:22`). We re-use it on the remote — it writes to `/tmp/claude-island.sock` regardless of host, which is exactly what we want (ssh -R forwards it).

- [ ] **Step 1: Confirm the bundled hook script is portable and self-invoking**

Read `ClaudeIsland/Resources/claude-island-state.py` (or wherever the bundled script lives — check the local `HookInstaller.swift:22` for the resource lookup name). Confirm:
1. First line is `#!/usr/bin/env python3` (or otherwise self-bootstrapping). The remote install relies on `chmod +x` + direct invocation; without a shebang, it won't run.
2. No hardcoded `/Users/`, no `Library/Application Support`, no `osascript`, no `pbcopy` or other Darwin-only commands.
3. The socket path it writes to is exactly `/tmp/claude-island.sock`. (If it computes the path from env or arg, the remote install needs to set that env var — not in the v1 plan; raise it here if you find it.)

If any of those fail, the spike (Task 1) didn't catch a Mac-specific assumption — stop and revisit. Otherwise continue.

- [ ] **Step 2: Create the file**

```swift
//
//  RemoteHookInstaller.swift
//  ClaudeIsland
//
//  Installs the Claude Code hook script on a remote host via SCP, and
//  merges hook entries into the remote ~/.claude/settings.json. The
//  hook script writes events to local /tmp/claude-island.sock on the
//  remote, which the SSH bridge forwards to Mac.
//

import Foundation
import os.log

private let installerLogger = Logger(subsystem: "com.claudeisland", category: "Remote")

enum RemoteHookInstaller {
    enum InstallError: Error, LocalizedError {
        case unreachable(stderr: String)
        case versionDetectionFailed
        case scpFailed(stderr: String)
        case settingsReadFailed(stderr: String)
        case settingsWriteFailed(stderr: String)
        case bundledScriptMissing

        var errorDescription: String? {
            switch self {
            case .unreachable(let s): return "Host unreachable: \(s)"
            case .versionDetectionFailed: return "Could not detect Claude Code on remote (PATH issue?)"
            case .scpFailed(let s): return "scp failed: \(s)"
            case .settingsReadFailed(let s): return "Read remote settings.json failed: \(s)"
            case .settingsWriteFailed(let s): return "Write remote settings.json failed: \(s)"
            case .bundledScriptMissing: return "Hook script not found in app bundle"
            }
        }
    }

    static func install(on host: RemoteHost) async throws {
        // 1. Reachability
        let probe = try await SSHCommandRunner.run(
            target: host.sshTarget, remoteCommand: "echo ok", timeout: 5
        )
        guard probe.ok, probe.stdout.contains("ok") else {
            throw InstallError.unreachable(stderr: probe.stderr)
        }
        installerLogger.info("Reachable: \(host.name, privacy: .public)")

        // 2. Claude version through a login shell so PATH includes
        //    nvm/asdf/~/.local/bin etc.
        let versionResult = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: #"bash -lc 'claude --version'"#,
            timeout: 10
        )
        guard versionResult.ok else {
            throw InstallError.versionDetectionFailed
        }
        installerLogger.info(
            "Remote claude version: \(versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)"
        )

        // 3. Ensure remote hooks dir exists
        _ = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "mkdir -p ~/.claude/hooks",
            timeout: 5
        )

        // 4. SCP the hook script
        guard let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") else {
            throw InstallError.bundledScriptMissing
        }
        let scp = try await SSHCommandRunner.scpUpload(
            localPath: bundled.path,
            target: host.sshTarget,
            remotePath: "~/.claude/hooks/claude-island-state.py",
            timeout: 30
        )
        guard scp.ok else { throw InstallError.scpFailed(stderr: scp.stderr) }

        _ = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "chmod +x ~/.claude/hooks/claude-island-state.py",
            timeout: 5
        )

        // 5. Merge ~/.claude/settings.json
        try await mergeSettings(on: host, claudeVersionOutput: versionResult.stdout)
    }

    static func uninstall(on host: RemoteHost) async throws {
        // 1. Read remote settings
        let read = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "cat ~/.claude/settings.json 2>/dev/null || echo '{}'",
            timeout: 5
        )
        guard read.ok else { throw InstallError.settingsReadFailed(stderr: read.stderr) }

        // 2. Strip Claude Island entries from ALL event types
        let stripped = stripAllClaudeIslandEntries(from: read.stdout)

        // 3. Write back
        try await writeRemoteSettings(host: host, jsonString: stripped)

        // 4. Remove hook script
        _ = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "rm -f ~/.claude/hooks/claude-island-state.py",
            timeout: 5
        )
    }

    // MARK: - Settings merge

    private static func mergeSettings(on host: RemoteHost, claudeVersionOutput: String) async throws {
        let read = try await SSHCommandRunner.run(
            target: host.sshTarget,
            remoteCommand: "cat ~/.claude/settings.json 2>/dev/null || echo '{}'",
            timeout: 5
        )
        guard read.ok else { throw InstallError.settingsReadFailed(stderr: read.stderr) }

        // Strip then re-add — same as local HookInstaller (CLAUDE.md "strip
        // ALL Claude Island entries from ALL event types").
        var json = parseJSON(read.stdout)
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let kept = entries.compactMap { removingClaudeIslandHooks(from: $0) }
                if !kept.isEmpty { cleaned[event] = kept }
            } else {
                cleaned[event] = value
            }
        }
        hooks = cleaned

        // Reuse local HookInstaller's version gating.
        let parsedVersion = parseClaudeVersion(claudeVersionOutput)

        // We don't assume any particular `python` on the remote — the
        // bundled script has a `#!/usr/bin/env python3` shebang and we
        // chmod +x it, so invoke it directly.
        let directCommand = "$HOME/.claude/hooks/claude-island-state.py"
        let hookEntry: [[String: Any]] = [["type": "command", "command": directCommand]]
        let hookEntryWithTimeout: [[String: Any]] = [
            ["type": "command", "command": directCommand, "timeout": 86400]
        ]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry],
        ]

        let events = HookInstaller.supportedHookEvents(
            for: parsedVersion,
            withMatcher: withMatcher,
            withMatcherAndTimeout: withMatcherAndTimeout,
            withoutMatcher: withoutMatcher,
            preCompactConfig: preCompactConfig
        )
        for (event, config) in events {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + config
        }

        json["hooks"] = hooks
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            throw InstallError.settingsWriteFailed(stderr: "JSON encode failed")
        }
        try await writeRemoteSettings(host: host, jsonString: jsonString)
    }

    private static func writeRemoteSettings(host: RemoteHost, jsonString: String) async throws {
        // Use base64 to avoid shell-quoting hazards in the JSON body.
        let b64 = Data(jsonString.utf8).base64EncodedString()
        let cmd = "echo \(b64) | base64 -d > ~/.claude/settings.json"
        let result = try await SSHCommandRunner.run(
            target: host.sshTarget, remoteCommand: cmd, timeout: 10
        )
        guard result.ok else { throw InstallError.settingsWriteFailed(stderr: result.stderr) }
    }

    // MARK: - JSON helpers

    private static func parseJSON(_ s: String) -> [String: Any] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func stripAllClaudeIslandEntries(from jsonStr: String) -> String {
        var json = parseJSON(jsonStr)
        guard var hooks = json["hooks"] as? [String: Any] else {
            return jsonStr
        }
        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let kept = entries.compactMap { removingClaudeIslandHooks(from: $0) }
                if !kept.isEmpty { cleaned[event] = kept }
            } else {
                cleaned[event] = value
            }
        }
        if cleaned.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = cleaned
        }
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: out, encoding: .utf8) else { return jsonStr }
        return str
    }

    private static func removingClaudeIslandHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
        entryHooks.removeAll { hook in
            (hook["command"] as? String ?? "").contains("claude-island-state")
        }
        if entryHooks.isEmpty { return nil }
        var out = entry
        out["hooks"] = entryHooks
        return out
    }

    private static func parseClaudeVersion(_ output: String) -> HookInstaller.ClaudeCodeVersion? {
        // Output format: "X.Y.Z (Claude Code)" or similar
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges >= 4 else {
            return nil
        }
        func num(_ idx: Int) -> Int {
            guard let r = Range(match.range(at: idx), in: output),
                  let n = Int(output[r]) else { return 0 }
            return n
        }
        return HookInstaller.ClaudeCodeVersion(major: num(1), minor: num(2), patch: num(3))
    }

}
```

- [ ] **Step 3: Make `HookInstaller.supportedHookEvents` and `ClaudeCodeVersion` accessible**

These are currently `private` / `fileprivate` in `HookInstaller.swift`. Open `HookInstaller.swift` and:

- Change `struct ClaudeCodeVersion: Comparable` to `internal struct ClaudeCodeVersion: Comparable`
- Change `static func supportedHookEvents(...)` declaration (around line 175 — find it via grep) from `private static` to `internal static`. Same for any helper it calls if needed.

Run grep:

```bash
grep -n "supportedHookEvents\|ClaudeCodeVersion" ClaudeIsland/Services/Hooks/HookInstaller.swift
```

Confirm visibility. Add `internal` (or remove `private`) on the listed declarations.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/Services/Remote/RemoteHookInstaller.swift \
        ClaudeIsland/Services/Hooks/HookInstaller.swift \
        ClaudeIsland.xcodeproj
git commit -m "feat: install/uninstall Claude Code hooks on a remote host"
```

---

## Phase 5 — Ghostty surface matching for remote sessions

### Task 12: `GhosttySurfaceMatcher` — find the surface owning an SSH child

**Files:**
- Create: `ClaudeIsland/Services/Injection/GhosttySurfaceMatcher.swift`

The matcher implements whatever Phase 0 (Task 1, Step 4) confirmed works (`ps -t`, `lsof`, or both). Use the spike findings — the snippet below assumes `ps -t` works; if Task 1 found `lsof` was needed, swap the helper.

- [ ] **Step 1: Create the file**

```swift
//
//  GhosttySurfaceMatcher.swift
//  ClaudeIsland
//
//  Maps a remote SessionState (host = .remote(name:)) to the Ghostty
//  surface tty that owns the SSH process talking to that host.
//
//  Local sessions don't go through this — they use the existing
//  GhosttyTtyCapability path with deterministic tty matching.
//

import Foundation
import os.log

private let matcherLogger = Logger(subsystem: "com.claudeisland", category: "Inject")

enum GhosttySurfaceMatcher {
    /// For a remote session, return the local Ghostty surface tty (e.g.
    /// "ttys005" — no /dev/ prefix) that owns an `ssh` child whose
    /// command line contains `host.sshTarget` or `host.name`.
    /// Returns nil if no match.
    static func matchingTty(for session: SessionState, host: RemoteHost) -> String? {
        guard session.host == .remote(name: host.name) else { return nil }

        let ghosttyTtys = listGhosttyTtys()
        for tty in ghosttyTtys {
            if hasSSHChild(tty: tty, target: host.sshTarget, alias: host.name) {
                return tty
            }
        }
        return nil
    }

    // MARK: - AppleScript: enumerate Ghostty surfaces

    private static func listGhosttyTtys() -> [String] {
        let script = #"""
        tell application "Ghostty"
            set ttys to {}
            repeat with t in (every terminal)
                try
                    set end of ttys to (tty of t as string)
                end try
            end repeat
            set AppleScript's text item delimiters to ","
            return ttys as string
        end tell
        """#
        do {
            let result = try AppleScriptRunner.run(script)
            let raw = result.stringValue ?? ""
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/dev/", with: "") }
                .filter { !$0.isEmpty }
        } catch {
            matcherLogger.warning("Ghostty tty enumeration failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Process tree probe

    private static func hasSSHChild(tty: String, target: String, alias: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", tty, "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let out = String(data: data ?? Data(), encoding: .utf8) ?? ""

        for line in out.split(separator: "\n") {
            let s = String(line)
            // Crude but effective: a line that starts with "ssh " or
            // contains " ssh " (skipping tools like "rsync" or paths
            // that incidentally contain "ssh") and references the
            // target or alias.
            let isSSH = s.hasPrefix("ssh ") || s.contains(" ssh ") || s.contains("/ssh ")
            guard isSSH else { continue }
            if s.contains(target) || s.contains(alias) {
                return true
            }
        }
        return false
    }
}
```

If the Phase 0 spike found `ps -t` insufficient, replace `hasSSHChild` with an `lsof`-based equivalent:

```swift
// Alternative: lsof-based pid enumeration
let lsof = Process()
lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
lsof.arguments = ["-t", "/dev/\(tty)"]
// then for each pid, ps -o command= -p <pid>
```

Pick whichever the spike validated.

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`. (`AppleScriptRunner` is already used by `GhosttyInjector.swift`.)

- [ ] **Step 3: Commit**

```bash
git add ClaudeIsland/Services/Injection/GhosttySurfaceMatcher.swift ClaudeIsland.xcodeproj
git commit -m "feat: add GhosttySurfaceMatcher for remote-session injection"
```

---

### Task 13: Wire `GhosttyInjector` to use the matcher for remote sessions

**Files:**
- Modify: `ClaudeIsland/Services/Injection/GhosttyInjector.swift`

- [ ] **Step 1: Branch on `session.host` in `canInject`**

In `GhosttyInjector.canInject(into:)`, locate the `if GhosttyTtyCapability.isSupported, let ttyPath = Self.ttyPath(for: session)` branch (around line 58). Above it, insert:

```swift
        if case .remote(let hostName) = session.host {
            guard let host = await MainActor.run(body: { RemoteHostRegistry.shared.hosts.first(where: { $0.name == hostName }) }) else {
                return false
            }
            guard let tty = GhosttySurfaceMatcher.matchingTty(for: session, host: host) else {
                injectLogger.info("ghostty canInject \(prefix, privacy: .public): no Ghostty surface owns an ssh to \(hostName, privacy: .public)")
                return false
            }
            let ttyPath = "/dev/\(tty)"
            do {
                let matched = try probeByTty(ttyPath)
                injectLogger.info(
                    "ghostty canInject \(prefix, privacy: .public): remote=\(hostName, privacy: .public) tty=\(ttyPath, privacy: .public) match=\(matched, privacy: .public)"
                )
                return matched
            } catch {
                injectLogger.error("ghostty canInject \(prefix, privacy: .public): remote tty probe failed \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
```

This must run inside the same `await MainActor.run { … }` block as the existing logic — adjust placement so it executes before `GhosttyTtyCapability.probeIfNeeded`.

- [ ] **Step 2: Same branching in `inject`**

Find `func inject(_ text: String, into session: SessionState) async -> Bool` (around line 86). Before computing `script` and `pathName`, add the remote branch:

```swift
        if case .remote(let hostName) = session.host {
            guard let host = await MainActor.run(body: { RemoteHostRegistry.shared.hosts.first(where: { $0.name == hostName }) }),
                  let tty = await MainActor.run(body: { GhosttySurfaceMatcher.matchingTty(for: session, host: host) }) else {
                injectLogger.warning("ghostty inject \(session.sessionId.prefix(8), privacy: .public): no remote tty match")
                return false
            }
            let ttyPath = "/dev/\(tty)"
            let script = injectScriptByTty(ttyPath: ttyPath, escapedText: escapedText)
            let started = Date()
            do {
                let result = try await MainActor.run { try AppleScriptRunner.run(script) }
                let ok = result.booleanValue
                let dur = Date().timeIntervalSince(started)
                injectLogger.info(
                    "ghostty inject \(session.sessionId.prefix(8), privacy: .public) via=remote-tty \(text.count, privacy: .public)b ok=\(ok, privacy: .public) \(String(format: "%.2f", dur), privacy: .public)s"
                )
                return ok
            } catch {
                injectLogger.error("ghostty inject \(session.sessionId.prefix(8), privacy: .public) remote error: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
```

This sits before the existing `let script: String` / `let pathName: String` block.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeIsland/Services/Injection/GhosttyInjector.swift
git commit -m "feat: route remote-session injection via GhosttySurfaceMatcher"
```

---

## Phase 6 — UI

### Task 14: `RemoteHostsSection` view

**Files:**
- Create: `ClaudeIsland/UI/Views/RemoteHostsSection.swift`

We embed this as a section inside `NotchMenuView` (consistent with the existing inline-settings pattern; the app has no separate Settings window).

- [ ] **Step 1: Create the view**

```swift
//
//  RemoteHostsSection.swift
//  ClaudeIsland
//
//  Inline section in NotchMenuView for managing remote SSH hosts.
//

import SwiftUI

struct RemoteHostsSection: View {
    @ObservedObject private var registry = RemoteHostRegistry.shared

    @State private var showAdd = false
    @State private var newName: String = ""
    @State private var newSSHTarget: String = ""
    @State private var inProgress = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote Hosts").font(.headline)
                Spacer()
                Button(showAdd ? "Cancel" : "Add") {
                    showAdd.toggle()
                    lastError = nil
                }
                .disabled(inProgress)
            }

            ForEach(registry.hosts) { host in
                hostRow(host)
            }

            if showAdd {
                addForm()
            }

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func hostRow(_ host: RemoteHost) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(host.name).font(.body)
                Text(host.sshTarget).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { host.enabled },
                set: { newValue in
                    var updated = host
                    updated.enabled = newValue
                    registry.update(updated)
                }
            ))
            .labelsHidden()

            Button("Remove") {
                Task { await uninstallAndRemove(host) }
            }
            .disabled(inProgress)
        }
    }

    @ViewBuilder
    private func addForm() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (e.g. dev-vm)", text: $newName)
            TextField("SSH target (e.g. user@host or ~/.ssh/config alias)", text: $newSSHTarget)
            HStack {
                Spacer()
                Button("Install") {
                    Task { await install() }
                }
                .disabled(inProgress || newName.isEmpty || newSSHTarget.isEmpty)
            }
        }
        .padding(8)
        .background(.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    private func install() async {
        inProgress = true
        lastError = nil
        defer { inProgress = false }

        let host = RemoteHost(name: newName, sshTarget: newSSHTarget)
        do {
            try await RemoteHookInstaller.install(on: host)
            registry.add(host)
            newName = ""
            newSSHTarget = ""
            showAdd = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func uninstallAndRemove(_ host: RemoteHost) async {
        inProgress = true
        lastError = nil
        defer { inProgress = false }
        do {
            try await RemoteHookInstaller.uninstall(on: host)
        } catch {
            // Continue removing even if uninstall failed — user is
            // explicitly asking to remove. Surface the error.
            lastError = "Uninstall: \(error.localizedDescription)"
        }
        registry.remove(id: host.id)
    }
}
```

- [ ] **Step 2: Embed in NotchMenuView**

Open `ClaudeIsland/UI/Views/NotchMenuView.swift`. Find the "System settings" section comment (around line 51). After the existing settings group, insert:

```swift
                Divider()
                RemoteHostsSection()
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke (UI exists, install end-to-end)**

Launch the app. Open the Notch menu → scroll to "Remote Hosts" → click Add → enter your real dev VM info → Install. Expected:

- Install button shows progress disabled state for ~5–30s
- On success: row appears, no error text
- In Console.app filter `category:Remote`, see `Reachable: <name>`, `Remote claude version: …`, then bridge state transitions

If install fails, the error is shown inline. Verify the error message is human-readable (not just a stack trace).

- [ ] **Step 5: Commit**

```bash
git add ClaudeIsland/UI/Views/RemoteHostsSection.swift \
        ClaudeIsland/UI/Views/NotchMenuView.swift \
        ClaudeIsland.xcodeproj
git commit -m "feat: add Remote Hosts section to notch menu"
```

---

### Task 15: Session list visuals — host prefix + reconnecting overlay

**Files:**
- Modify: any view that renders `session.projectName` (typically `NotchView.swift`, `StatusBarPopoverView.swift`, `ChatView.swift`)

- [ ] **Step 1: Find every site that renders `session.projectName`**

Run:

```bash
grep -rn "\.projectName" ClaudeIsland/
```

Two known sites confirmed during Task 3 code review (don't miss them):
- `ClaudeIsland/UI/Views/StatusBarPopoverView.swift` line ~91 — status-bar title.
- `ClaudeIsland/Services/State/SessionStore.swift` line ~1173 — sort key for the session list. **This one is in a service file, not UI**, so a `grep` restricted to `UI/` would miss it.

For each hit, decide whether the user-facing label should be `displayProjectName` (host-prefixed) or `projectName` (raw). Default: switch to `displayProjectName`. Sort keys: switch too — list ordering should be by the displayed name.

- [ ] **Step 2: Replace `session.projectName` with `session.displayProjectName` at user-facing sites**

For each grep hit, replace `session.projectName` with `session.displayProjectName`. Skip cases where `projectName` is used as a path / lookup key (those need the raw value).

- [ ] **Step 3: Visualize `connectionState`**

In the same views, where a session row is rendered, add an opacity modifier and a tooltip:

```swift
.opacity({
    if case .reconnecting = session.connectionState { return 0.5 }
    return 1.0
}())
.help({
    if case .reconnecting(let attempt) = session.connectionState {
        return "Reconnecting (attempt \(attempt))…"
    }
    if case .failed(let r) = session.connectionState {
        return "Bridge failed: \(r)"
    }
    return ""
}())
```

Apply at minimum to whatever wrapper view holds an entire session row in `NotchView.swift` and `StatusBarPopoverView.swift`.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme ClaudeIsland -configuration Debug build -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Smoke**

With a remote host configured and connected, run a remote claude session. Expected: list row shows `dev-vm:project-name` (or whatever your host name is).

Then kill connectivity (turn off Wi-Fi or `kill` the ssh subprocess) — within ~1 second the row should fade to 50% opacity. Hover → tooltip "Reconnecting (attempt N)…". Restore connectivity — row returns to full opacity within the next backoff window.

- [ ] **Step 6: Commit**

```bash
git add ClaudeIsland/UI/Views/
git commit -m "feat: show host prefix and reconnecting state in session list"
```

---

## Phase 7 — QA pass

### Task 16: Run the smoke matrix from the spec

**Files:**
- Create: `docs/superpowers/qa-2026-04-26-ssh-remote.md` (record results)

This is the explicit gate before declaring the feature shipped. The matrix is from the spec § Testing.

- [ ] **Step 1: Set up the test environment**

- One Mac with the new build installed
- One dev VM you control, password-less SSH from Mac, OpenSSH 6.7+
- A throwaway repo on the dev VM (`mkdir ~/qa && cd ~/qa && git init`)

- [ ] **Step 2: Run the matrix and record results**

Create `docs/superpowers/qa-2026-04-26-ssh-remote.md` and tick each box with notes. The matrix:

```markdown
# QA pass — SSH remote sessions, 2026-04-26

Build: <commit sha>
Mac: <macOS version>
Ghostty: <version>
Dev VM: <distro/sshd version, claude version>

- [ ] Add host → install succeeds → bridge `connected`
- [ ] Open Ghostty SSH tab to dev-vm → run `claude` → session appears in menu/island
      Expected display: `dev-vm:<project>`
- [ ] Remote claude calls Bash tool → Mac panel shows Approval card
- [ ] Click Allow → remote claude proceeds
- [ ] Click Deny → remote claude reports denial (or tries alternative)
- [ ] Type message in Mac chat panel → arrives in remote claude as user prompt
- [ ] Multi-line text + `/` + Chinese + emoji preserved correctly
- [ ] Remote claude finishes turn → session goes `.idle`
- [ ] `/clear` on remote → session list keeps the entry (history clears, sessionId stays)
- [ ] Remote claude `/exit` → row disappears
- [ ] Wi-Fi off → row fades, tooltip "Reconnecting"
- [ ] Wi-Fi on → row recovers; can still approve next request
- [ ] Mac sleep → wake → bridge re-establishes; sessions still tracked
- [ ] Two Ghostty tabs each with their own remote claude on same dev-vm → both shown, no cross-talk
- [ ] Local session + remote session at the same time → both work, no interference
- [ ] Uninstall host → bridge stops, hooks removed from remote `~/.claude/settings.json`,
      remote claude no longer fires events to Mac
```

For any FAIL, file an issue in the repo (or note the gap). Don't tick a box you didn't actually exercise.

- [ ] **Step 3: Commit the results**

```bash
git add docs/superpowers/qa-2026-04-26-ssh-remote.md
git commit -m "docs: QA smoke matrix for ssh-remote support"
```

---

## Self-Review

After writing this plan, the following spec areas are covered:

| Spec section | Task |
|---|---|
| § 问题 (motivation) | Goal/Architecture in header |
| § 目标 v1: status, approval, inject, reconnect | Phase 4–6 |
| § 非目标 | Header note + omitted by design |
| § 架构 (data model + ingress tagging) | Tasks 2, 3, 4, 5 |
| § 组件 · RemoteHost / Registry | Task 6 |
| § 组件 · SSHBridgeController / SSHBridge | Tasks 7, 8, 9 |
| § 组件 · RemoteHookInstaller | Task 11 |
| § 组件 · HookSocketServer 改动 | Task 4 |
| § 组件 · MessageInjector 改动 + GhosttySurfaceMatcher | Tasks 12, 13 |
| § 数据流 路径 A/B/C | Implicit across Phases 1, 4, 5 |
| § 数据流 · 不做 JSONL 远端访问 | Task 5 (host gate on isInTmux/JSONL features) |
| § 生命周期 · 启动 / sleep-wake / 5 分钟 idle 跳过 | Tasks 9, 10 |
| § 生命周期 · 桥断开 reconnect | Task 8 |
| § UI · Settings 入口 | Task 14 |
| § UI · Session list 显示 | Task 15 |
| § Spike & 风险 | Task 1 |
| § 测试 smoke matrix | Task 16 |

Coverage looks complete. No placeholder text, no "TBD", no `Similar to Task N`. Type names are consistent across tasks (`SessionHost`, `RemoteConnectionState`, `RemoteHost`, `SSHBridge`, `SSHBridge.State`, `SSHBridgeController`, `RemoteHookInstaller`, `GhosttySurfaceMatcher`).
