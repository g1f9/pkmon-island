# MessageInjector — 让 pkmon-island 真正能从面板回复 CLI agent

**Date:** 2026-04-26
**Status:** Draft, awaiting review

## 问题

面板里的 *Allow / Deny* 工作正常，但 `inputBar.sendMessage()` 在很多场景下不工作或工作错误。两条回路本质上完全不同：

- **审批**走 `HookSocketServer` 上保持打开的 Unix domain socket，是带内 RPC：不依赖 tmux、不依赖 tty。
- **发消息**走 `tmux send-keys -l <text>; tmux send-keys Enter`，是带外按键模拟：依赖 (a) Claude 在 tmux 里跑、(b) tmux 把字符正确喂给 PTY、(c) Claude TUI 当前接受文本输入。

两个独立缺陷：

1. **必须 tmux**：`canSendMessages = session.isInTmux && session.tty != nil`（`ChatView.swift:358`）。Claude 直接在 Ghostty / iTerm / Terminal.app 标签里跑时输入框 disabled。
2. **send-keys -l 没有 bracketed paste**：字符逐个被 ink TUI 解析，第一字符 `/` `!` `#` `?` 触发 mode 切换；多行 `\n` 被当 submit 截断；包含特殊字符的文本不可靠。审批的 `1` `2` `n` 不撞这些坑是因为审批弹出时 TUI 在 modal prompt 等单字符决策。

## 目标 & 非目标

**目标**

- 用户在面板里输入 → 文本作为新一轮 user message 出现在 Claude session 里，无论 Claude 是在 tmux 还是 Ghostty 标签里跑。
- 多行、含 `/` / `!` / `#` / 中文 / emoji 的内容也能正确送达。
- Ghostty 用户开箱即用，不强制 tmux。

**非目标**

- 不做 Kitty / iTerm2 / WezTerm / Alacritty backend（留接口，后续做）。
- 不解决 Linux / Windows（pkmon-island 当前只 ship macOS）。
- 不接管 Claude 的启动方式（不会把 Claude 进程拉进 pkmon-island 自己的 PTY，也不写 terminal emulator）。
- 不替换审批通道（审批继续走 `HookSocketServer`）。

## 架构

新增一层 `MessageInjector` 协议，把"把文本送到一个 Claude session"这件事抽出来：

```swift
protocol MessageInjector: Sendable {
    /// 这个 backend 当前能不能把文本发到这个 session
    func canInject(into session: SessionState) async -> Bool

    /// 实际把 text 注入。返回 true 代表 backend 接受了请求；
    /// 不代表 Claude 一定看到了（Claude 是否成功 dispatch 由 JSONL UserPromptSubmit 事件确认）
    func inject(_ text: String, into session: SessionState) async -> Bool

    /// 用来 UI 上展示"通过 X 发送" / 调试日志
    var displayName: String { get }
}
```

调度器：

```swift
@MainActor
final class MessageInjectorRegistry {
    static let shared = MessageInjectorRegistry()

    /// 优先级从高到低
    private let injectors: [MessageInjector] = [
        GhosttyInjector(),
        TmuxInjector(),
    ]

    func resolve(for session: SessionState) async -> MessageInjector? {
        for injector in injectors {
            if await injector.canInject(into: session) { return injector }
        }
        return nil
    }
}
```

`ChatView.canSendMessages` 不再写死 `session.isInTmux`，改成 *"是否有任意 injector 能 handle 这个 session"*。

```
┌──────────────────────┐
│ ChatView.sendMessage │
└──────────┬───────────┘
           ▼
┌─────────────────────────────────┐
│ MessageInjectorRegistry.resolve │
└──────────┬──────────────────────┘
           ▼
   ┌───────┴────────┐
   │                │
   ▼                ▼
┌─────────────┐  ┌──────────────┐
│ Ghostty     │  │ Tmux         │
│ AppleScript │  │ load-buffer  │
└─────────────┘  └──────────────┘
```

## Backend 1: GhosttyInjector

### 寻址

Ghostty 1.3.0+ 的 AppleScript 字典支持 `every terminal whose working directory contains <path>`。`SessionState` 里已经有 `cwd`，所以 cwd 匹配是首选。

```applescript
tell application "Ghostty"
    set targets to every terminal whose working directory is equal to "<normalized_cwd>"
    if (count of targets) is 0 then
        return missing value -- 让 Swift 端 fallback
    end if
    -- 多匹配时取第一个；后续可以加更精确的 disambiguation
    input text "<text>" to item 1 of targets
end tell
```

实现层细节：

- 用 `NSAppleScript` 执行，模板拼装时对 `<text>` 做 AppleScript 字符串转义（`"` → `\"`，`\` → `\\`，换行保留）。
- **cwd normalization**：`SessionState.cwd` 与 Ghostty 暴露的 `working directory` 都先 `URL(fileURLWithPath:).standardizedFileURL.path` 一遍，去掉 trailing slash、解析 `..`、保留 symlink 原样（Ghostty 那边怎么存我们就怎么比 — 它本身也不 resolve symlink）。`is equal to` 在 normalized 之后是稳妥的；不用 `contains`，避免 `/Users/me/foo` 误匹配 `/Users/me/foobar`。
- 不在 AppleScript 里 hardcode app name `"Ghostty"` — 检查 Ghostty bundle id `com.mitchellh.ghostty` 是否安装；没安装直接返回 `canInject = false`。

### `canInject` 判定

`true` 当且仅当：

1. `session.cwd` 不为空。
2. Ghostty.app 安装且当前在跑（`NSWorkspace.shared.runningApplications` 里有 `com.mitchellh.ghostty`）。
3. 存在至少一个 `working directory == session.cwd` 的 terminal（用 `count of (every terminal whose working directory is equal to <cwd>)` 探测）。

判定本身要走 AppleScript，需要 throttle / cache 一下，不然每次 keypress 都跑一遍 osascript 太重。缓存键 `(sessionId, cwd)`，TTL 2s。

### bracketed paste 已确认

源码追踪（2026-04-26 verified at commit `67b5783b`）：

```
input text                                       [AppleScript]
  → ScriptInputTextCommand.performDefaultImplementation
  → surface.sendText(text)                        [Swift]
  → ghostty_surface_text(surface, ptr, len)       [FFI]
  → surface.textCallback(text)                    [Zig]
  → self.completeClipboardPaste(text, true)       ← Cmd+V 路径
```

**`input text` 与 Cmd+V 是同一条路径**。Claude CLI 已开启 bracketed paste（DECSET 2004），文本会被 `\x1b[200~ … \x1b[201~` 包裹，`/`/`!`/`#`/换行均不再触发 mode 切换或 submit。

### TCC 权限

AppleScript 控制别的 app 第一次会触发 *"Claude Island 想要控制 Ghostty"* 的 TCC 弹窗。处理：

- 失败时 `NSAppleScript.executeAndReturnError` 返回的 error dict 含 `NSAppleScriptErrorNumber = -1743`（`errAEEventNotPermitted`）。
- 第一次失败时 UI 弹一个 sheet 解释为什么需要、引导到 *系统设置 → 隐私与安全 → 自动化* 勾选 Ghostty。
- 后续 fallback 到 tmux 路径（如果 session 也在 tmux 里）。

### 失败模式 & fallback

| 现象 | 处理 |
|---|---|
| Ghostty 没装 | `canInject = false`，registry 跳到下一个 |
| Ghostty 没在跑 | 同上 |
| `cwd` 没匹配到 terminal | 同上 |
| TCC 拒绝 | 第一次弹引导 sheet；记录 5 分钟的 grace period，期内 `canInject = false` |
| AppleScript 执行错（其他错）| 记录到 logger，单次失败不污染缓存，下次重试 |

## Backend 2: TmuxInjector（修复版）

替换 `ToolApprovalHandler.sendMessage` 当前的 `send-keys -l` 实现：

```swift
// 旧：
//   tmux send-keys -t <target> -l <text>
//   tmux send-keys -t <target> Enter

// 新：
//   tmux load-buffer -b __pkmon_inject -                     <stdin: text>
//   tmux paste-buffer -p -b __pkmon_inject -t <target> -d
//   tmux send-keys -t <target> Enter
```

关键点：

- `load-buffer -` 从 stdin 读，避免 shell quoting 地狱。
- `paste-buffer -p` 启用 bracketed paste，与 Ghostty 路径行为一致。
- `paste-buffer -d` 粘贴后删除 buffer，不污染 tmux 用户的 buffer 栈。
- `-b __pkmon_inject` 命名 buffer 避免和别的 buffer 冲突。

`Enter` 仍然单独发，因为 bracketed paste 里的换行只是文本，不会 submit。我们要的是粘贴完之后明确按 Enter。

`canInject` 判定不变：`session.isInTmux && session.tty != nil` 且能找到对应 pane。

### 注意：审批通道**不动**

`approveOnce / approveAlways / reject` 还是 `send-keys -l`。这些是单字符送给 modal prompt，不需要 paste 语义。本设计只动 `sendMessage` 那条路径。

## ChatView 改动

```swift
// 旧
private var canSendMessages: Bool { session.isInTmux && session.tty != nil }

// 新
@State private var resolvedInjector: MessageInjector?

private var canSendMessages: Bool { resolvedInjector != nil }

.task(id: session.id) {
    resolvedInjector = await MessageInjectorRegistry.shared.resolve(for: session)
}
.onReceive(sessionMonitor.$instances) { _ in
    Task { resolvedInjector = await MessageInjectorRegistry.shared.resolve(for: session) }
}
```

`sendToSession`:

```swift
private func sendToSession(_ text: String) async {
    guard let injector = resolvedInjector else { return }
    let ok = await injector.inject(text, into: session)
    if !ok {
        // resolvedInjector 在过去几秒可能已 stale，强制重 resolve 再试一次
        if let fresh = await MessageInjectorRegistry.shared.resolve(for: session),
           fresh.displayName != injector.displayName {
            _ = await fresh.inject(text, into: session)
        }
    }
}
```

placeholder 文案：

| 状态 | 文案 |
|---|---|
| `resolvedInjector != nil` | `Message Claude...` |
| 解析中 | `Connecting...` |
| Ghostty 装了但 cwd 没匹配 | `Open this project in Ghostty or tmux to enable messaging` |
| 都不可用 | `Open Claude Code in Ghostty or tmux to enable messaging` |

不要把 placeholder 写成 *"Open Claude Code in tmux"* — Ghostty 现在是头等公民。

## 错误处理 & 日志

新建 `Logger(subsystem: "com.claudeisland", category: "Inject")`。每次 inject 记录 `displayName + sessionId 前缀 + 字节数 + duration + 结果`。

不要静默失败：用户按 Send 后等 ≥ 500ms 还没看到 Claude pane 状态变化（JSONL UserPromptSubmit 事件），UI 上把发送按钮变成红色 `!` 并 toast 一行 *"Send via Ghostty failed (TCC denied?). Try again or open Ghostty automation permission."*。这个检测放在 ChatView 层，不在 Injector 层。

## 测试

项目没有 test target（CLAUDE.md 已注明）。落地前的 manual checklist：

- [ ] **G1**：Claude 在 Ghostty 里跑。面板发"hello"，Claude 收到 hello 作为 user turn。
- [ ] **G2**：Claude 在 Ghostty 里跑。面板发 `/help`，Claude **不**触发 slash command 模式，把 `/help` 当字面文本。
- [ ] **G3**：Claude 在 Ghostty 里跑。面板发多行（含 `\n`）的 prompt，Claude 看到完整多行（不被截断为多次 submit）。
- [ ] **G4**：Ghostty 没装的机器，面板优雅降级到 tmux（如果 Claude 在 tmux 里）。
- [ ] **G5**：Ghostty 装了但 Claude 不在 Ghostty 里（在 iTerm 里），且不在 tmux 里：输入框 disabled，placeholder 引导用户。
- [ ] **G6**：第一次发送触发 TCC 弹窗；用户拒绝；UI 显示引导。
- [ ] **T1**：Claude 在 tmux 里。面板发 `/help`，Claude **不**触发 slash 模式（旧版会触发 — 这是回归测试）。
- [ ] **T2**：Claude 在 tmux 里。面板发多行 prompt，Claude 看到完整多行。
- [ ] **T3**：审批回路完全不变 — Allow / Deny / Reject 依然工作。
- [ ] **T4**：审批走的还是 `send-keys -l "1"`（不是 paste），单元层面验证 `ToolApprovalHandler.approveOnce` 没被波及。

报告时明确说"已通过 manual checklist"，不要说 "tested" — 没有 xcodebuild test 跑这些。

## Rollout

一次发布。没有 feature flag — 这是个修 bug + 加能力，不是 A/B。

CLAUDE.md 加一段 *"Message injection: 见 `Services/Injection/`"*，把 ToolApprovalHandler 与 MessageInjector 的边界写清楚（审批走前者，发送走后者）。

## 文件布局

```
ClaudeIsland/Services/Injection/
  MessageInjector.swift           # protocol + Registry
  GhosttyInjector.swift
  TmuxInjector.swift
  AppleScriptRunner.swift         # NSAppleScript 包装，转义、错误处理
```

`ToolApprovalHandler.sendMessage` 删除（或保留但内部 delegate 给 Registry — 倾向直接删，让 ChatView 直接调 Registry）。

## 已知不做（YAGNI）

- 不做 KittyInjector / WezTermInjector / ITerm2Injector — 等有用户反馈再加。接口已预留。
- 不做"自动启动 Claude in Ghostty"按钮 — 用户自己开。
- 不做"在哪个 Ghostty 标签发"的消歧 UI — 当前 `cwd` 匹配多个时取第一个；如果实际遇到歧义再加。
- 不动审批回路。
