# CLAUDE.md

Working notes for future sessions. Architecture, file layout, and state-machine
shapes are not duplicated here — read the code. This file only captures things
that are easy to break and not obvious from a single file.

## Build & release

- Local dev build: `xcodebuild -scheme ClaudeIsland -configuration Release build`.
- Don't ship a release straight from `xcodebuild`. Use `scripts/create-release.sh`
  — it handles notarization, DMG packaging, Sparkle EdDSA signing, GitHub
  upload, and the appcast at `https://vibenotch.app/appcast.xml`. Skipping it
  ships an unsigned-by-Sparkle build that auto-update will reject.
- Sparkle public key lives in `ClaudeIsland/Info.plist`; private key generation
  is `scripts/generate-keys.sh`.

## Hook installation footguns (`Services/Hooks/HookInstaller.swift`)

- **Version-gate every event**. `PreCompact` only exists on Claude Code v1.3+.
  Always probe `claude --version` and only register events the installed CLI
  supports — registering an unknown event silently breaks the user's hook
  config.
- **When migrating, strip Claude Island entries from ALL event types**, not
  just the ones you're about to write. Issue #85 was caused by leftovers in
  events the new version no longer uses.

## IPC contract (`Services/Hooks/HookSocketServer.swift`)

- Unix socket at `/tmp/claude-island.sock`. Hook protocol is JSON-per-connection.
- **`PermissionRequest` events from Claude Code do not carry `tool_use_id`.**
  The server reconstructs it via a FIFO cache keyed by
  `"sessionId:toolName:serializedInput"`, populated from the preceding
  `PreToolUse`. If you change `HookEvent` shape, tool input serialization,
  or the `PreToolUse → PermissionRequest` ordering assumption, the approval
  flow breaks and there is no loud failure — requests just hang for 5
  minutes and time out.
- Permission responses are written back on the same socket connection.

## Approval keystrokes (`Services/Tmux/ToolApprovalHandler.swift`)

- Approve / always-approve / reject are sent to Claude's tmux pane as the
  literal characters `1`, `2`, `n` plus Enter. This is hard-coupled to
  Claude CLI's prompt format. **If approvals stop working after a Claude CLI
  upgrade, check this file first** — the CLI may have changed prompt wording.

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

### Ghostty user prerequisite: `keybind = enter=text:\r`

Ghostty 1.3's `send key "enter"` AppleScript event encodes Enter via
the active keyboard mode. When the running TUI has Kitty keyboard
protocol on (Claude Code's React Ink does), Ghostty produces a CSI u
sequence that Ink doesn't recognize as submit — text lands in the
input buffer but never gets sent. Same upstream bug as Ghostty
Discussion #9264 (Copilot CLI).

Workaround that the user must add to `~/.config/ghostty/config`:

```
keybind = enter=text:\r
```

Ghostty must be **fully quit and relaunched** for this to take effect
on existing terminals (Cmd+Shift+, reload doesn't propagate to
already-open surfaces). Surface this in user-facing setup docs.

Also note: `Info.plist` declares `NSAppleEventsUsageDescription` so
macOS actually shows the Automation permission prompt; without that
key the request is silently denied.

## JSONL parsing invariants

- `~/.claude/projects/{cwd}/*.jsonl` is parsed incrementally; `lastSyncOffset`
  on `ToolTracker` must be preserved across updates. A full re-parse on every
  hook event is expensive and was deliberately removed.
- `ChatHistoryManager.isLoaded` requires a non-empty parsed history (commit
  7bb535c). Don't flip it true just because parsing ran.
- Switching sessions must force-recreate `ChatView` (commit ba4af87) — SwiftUI
  state will otherwise leak from the previous session.

## Testing reality

- There is no test target. `xcodebuild test` will not find anything.
- Do not claim a change is "tested" or "verified" without launching the app
  and exercising the affected flow (hook install, permission approval, chat
  rendering). Say so explicitly when reporting work.

## Intentional choices — don't "fix" without asking

- The Mixpanel token in `App/AppDelegate.swift` is hardcoded on purpose. Don't
  refactor it to an env var or strip it.
- `nonisolated(unsafe)` on `SessionStore.sessionsSubject` is the deliberate
  bridge between the actor and Combine. Don't "fix" the warning without
  designing a replacement for the Combine publishing.
