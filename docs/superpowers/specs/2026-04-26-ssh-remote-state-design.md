# SSH 远端 Claude session 的状态采集与扭转

**Date:** 2026-04-26
**Status:** Draft, awaiting review

## 问题

Vibe Notch 当前只看到 Mac 本机的 Claude Code session：菜单栏的 idle/working/approval、岛屿的实时状态、面板里的审批和发消息，全部假设事件来自本机的 `/tmp/claude-island.sock`、文件来自本机 `~/.claude/projects/`、注入目标是本机的 Ghostty surface 或 tmux pane。

实际工作流里，开发者经常在 Ghostty 里 `ssh dev-vm` 然后直接跑 `claude`——这种 session 当前完全不可见。我们要让 Mac 像看本地 session 一样看远端 session：状态实时刷新、审批能从面板点 Allow、面板里发的文字能送达远端 claude TUI。

## 目标 & 非目标

**目标 (v1)**

- 用户在 Vibe Notch 设置里加一台 dev VM（直连 SSH，password-less），点 Install 后，远端跑 `claude` 时 session 自动出现在菜单栏/岛屿/面板里。
- 远端 session 的状态（idle / processing / waitingForApproval / waitingForInput / compacting / ended）像本地 session 一样实时更新。
- 面板里点 Allow / Deny / Reject 能正确响应远端的 PermissionRequest。
- 面板里发文字能作为新一轮 user message 送达远端 claude。
- SSH 桥断开/恢复对用户体感是"那台 host 暂时不可达"，恢复后 session 继续。

**非目标 (v1)**

- **多台 host**：底层架构支持 N 台，但 UI 第一版只允许配置 1 台。
- **跳板/代理**：不在 app 里做 ProxyJump UI，但 `~/.ssh/config` 里手动配的 ProxyJump 用户可以在 `sshTarget` 字段直接填别名，应该能工作（不重点保证）。
- **password / OTP / device-cert**：只支持 password-less 认证——公钥直登，或 ssh-agent 持有解锁的私钥（不是 SSH agent forwarding `-A`，是 Mac 上 `ssh-add` 加进 agent 的本地 key）。所有 SSH 子命令都带 `-o BatchMode=yes`，绝不交互式弹密码。
- **远端 JSONL chat 历史**：远端 session 的对话内容比本地 session 信息少，历史展示是降级的。
- **远端 tmux 模式**：本设计假定远端 claude 跑在 Mac Ghostty 的裸 SSH pty 里。如果用户在远端开 tmux 跑 claude，注入路径会断（不在本设计范围内）。
- **离线 buffer**：Mac 不在线时不缓存 hook 事件。Hook 协议本身要求同步响应，buffer 没意义。
- **Linux/Windows 客户端**：和 pkmon-island 主体一致，只 ship macOS。

## 架构

**核心原则**：`SessionStore` 不区分本地 / 远程。事件在进入 store 之前就已经被 ingress 打上 `host` 标签，从此以后状态机、审批、UI 一视同仁。

### 文字版架构图

```
[Mac]                                       [dev-vm]

HookSocketServer(local)                     hook script
  ← /tmp/claude-island.sock                   ↓
                                            /tmp/claude-island.sock
HookSocketServer(remote, host=dev-vm)       ↑↑↑ (ssh -R 反向 unix socket 转发)
  ← /tmp/claude-island-dev-vm.sock
       ↑↑↑
       | (透传字节)
       |
SSHBridgeController                          claude (跑在 Ghostty 的 SSH pty 里)
  spawns: ssh -N -R \
    /tmp/claude-island.sock:\
    /tmp/claude-island-dev-vm.sock \
    dev-vm

  ↓ tags every accepted connection with host=.remote("dev-vm")

SessionStore (host-agnostic)
  ↓
UI (status bar / 岛屿 / chat panel)
```

### 数据模型变化

`Models/SessionState.swift`：

- 新增 `host: SessionHost`，enum：`.local` / `.remote(name: String)`
- 新增 `connectionState: RemoteConnectionState?`，仅 remote 用：`.connected` / `.reconnecting(attempt: Int)`。**不进 `SessionPhase` 主状态机**——重连只是 UI 覆盖，不影响审批/inject 的逻辑模型
- `pid` / `tty` / `isInTmux` 保留字段，但**远端只存不验**：
  - `kill(pid, 0)` 验活只对 `.local` 跑
  - `ProcessTreeBuilder.isInTmux` 只对 `.local` 跑；远端裸 SSH 模式下永远填 `false`
- 项目名渲染：`host == .local ? cwd basename : "<host>:<cwd basename>"`

`Models/SessionPhase.swift`：**零改动**。

`Services/State/SessionStore.swift`：

- `createSession(from event:)` 入参带 host
- "5 分钟 hook 静默 → 强制 idle" 那条规则需要打补丁：判定时跳过 `connectionState == .reconnecting` 的 session，否则桥重连期间会被错误降级

## 组件

### 新增

#### `Services/Remote/RemoteHost.swift`

```swift
struct RemoteHost: Codable, Identifiable {
    let id: UUID
    var name: String          // 用户可见别名："dev-vm"
    var sshTarget: String     // ssh 命令行参数：可以是 "user@host"、~/.ssh/config 里的别名
    var enabled: Bool
}
```

持久化到 `UserDefaults` 的 `remoteHosts` key，JSON 序列化。

#### `Services/Remote/SSHBridgeController.swift`

Actor，单例。职责：

- 维护一个 `[UUID: SSHBridge]` 表，每个 enabled host 对应一个
- `start(host:)` / `stop(host:)` / `restartAll()`
- 监听 `NSWorkspace.willSleepNotification` → `suspendAll()`；`didWakeNotification` → `resumeAll()`
- App 启动时由 AppDelegate 触发 `startEnabledHosts()`

#### `Services/Remote/SSHBridge.swift`

单个 host 的 SSH 连接状态机。内部状态：`.idle / .connecting / .connected / .reconnecting(attempt: Int) / .failed(error)`。

启动时跑：

```
ssh -N \
    -o BatchMode=yes \
    -o ControlMaster=no \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StreamLocalBindUnlink=yes \
    -R /tmp/claude-island.sock:/tmp/claude-island-<host>.sock \
    <sshTarget>
```

`-R remote:local` 的语义：**远端**绑定 `/tmp/claude-island.sock`（hook 脚本写它），**Mac 端**target 是 `/tmp/claude-island-<host>.sock`（`HookSocketServer(remote)` 监听它）。

监控子进程 stderr/退出码。断了走指数退避（1s/2s/4s/…/封顶 60s）。状态变化通过 `SessionStore.bridgeStateChanged(host:, connected:)` 同步给 store，由 store 给所有 `host == self.host` 的 session 更新 `connectionState`。

`stop()`：SIGTERM ssh 子进程；best-effort `ssh -o BatchMode=yes <target> 'rm -f /tmp/claude-island.sock'` 清**远端**残留 socket（避免下次启动 `StreamLocalBindUnlink` 不可用时撞到旧文件）。本地的 `/tmp/claude-island-<host>.sock` 由 `HookSocketServer(remote)` 自己负责 cleanup。

#### `Services/Remote/RemoteHookInstaller.swift`

`install(on host: RemoteHost) async throws`：

所有 SSH/SCP 子命令都带 `-o BatchMode=yes`。

1. 连通性探测：`ssh -o BatchMode=yes <target> echo ok`（5s timeout）
2. Claude 版本探测：`ssh -o BatchMode=yes <target> 'bash -lc "claude --version"'`——必须走 login shell，否则 PATH 不包含 nvm/asdf/`~/.local/bin` 之类装 claude 的目录时会 `command not found`。复用 `HookInstaller` 现有版本判定逻辑——CLAUDE.md 里强调过 PreCompact 等事件要按版本注册，不然会 silent break 用户的 hook config。
3. `ssh -o BatchMode=yes <target> 'mkdir -p ~/.claude/hooks'`
4. `scp -o BatchMode=yes` 现有 hook 脚本（已 bundle 在 app `Resources/`）→ `~/.claude/hooks/claude-island-hook` + `chmod +x`
5. 读取远端 `~/.claude/settings.json`，本地 merge hook 注册（**严格按 CLAUDE.md 那条铁律：strip ALL Claude Island entries from ALL event types before writing**），写回

`uninstall(on:)`：移除 hook script + 清掉 settings.json 里 Claude Island 的所有事件 entry（同样的 strip-all 规则）。

### 改动

#### `Services/Hooks/HookSocketServer.swift`

当前是单例监听 `/tmp/claude-island.sock`。改造：

- 改为可实例化：`init(socketPath: String, host: SessionHost)`
- App 启动时实例化两个：
  - `HookSocketServer(socketPath: "/tmp/claude-island.sock", host: .local)`
  - 每个 enabled remote host：`HookSocketServer(socketPath: "/tmp/claude-island-\(host.name).sock", host: .remote(host.name))`
- 在每个 ingress 给 `HookEvent` 注入 host 后再交给 `SessionStore`
- `respondToPermission` 写回原 connection 的逻辑不变——审批 RPC 自动走对的桥
- `pendingPermissions` 缓存（`(sessionId:toolName:serializedInput)` FIFO，CLAUDE.md 里的关键不变量）按 server 实例隔离即可，跨 host 不共享 cache

#### `Models/SessionState.swift`

如上：加 `host`、`connectionState`，调整 `createSession`。

#### `Services/Injection/MessageInjectorRegistry.swift` + `Services/Injection/GhosttyInjector.swift`

注入路径**逻辑上不变**：`GhosttyInjector` 优先，`TmuxInjector` 回退。但 surface 匹配规则要扩展。

当前 surface 匹配（`Services/Injection/GhosttyInjector.swift`）：
- post-Ghostty 1.3.1：用 `tty` 严格匹配 surface
- pre-Ghostty 1.3.1：用 `working directory` + 可选 `name` 摘要匹配

远端 session 的问题：`session.tty` 是远端 pty（`pts/N`），Mac Ghostty surface 的 tty 是本地（`ttys00N`），永远对不上。

新增 `Services/Injection/GhosttySurfaceMatcher.swift`，针对 `host == .remote(name)` 走分支：

1. 枚举 Ghostty 所有 surface
2. 对每个 surface 拿到本地 tty
3. 用 `ProcessTreeBuilder` 拿该 tty 下的子进程链
4. 检查链里是否有 `ssh` 进程，且命令行包含 `host.sshTarget` 或 `host.name`
5. 找到匹配 surface → AppleScript `input text` + 双 Enter（**完全复用现有 Ghostty 注入路径**，包括 CLAUDE.md 里强调的双 Enter 解决 IME 吞 Enter 的问题）

**Spike 任务（Phase 0，写实现前先做）**：验证 Ghostty AppleScript sdef + `ProcessTreeBuilder` 在 Ghostty 子进程是 `ssh` 的情况下能否稳定拿到命令行参数。如果 sdef 不暴露足够信息，fallback 到 `ps -o command -p <pid>` 抓 ssh 命令行。

## 数据流

### 路径 A：远端 hook 事件上报

```
1. 远端 claude 触发 hook event
2. ~/.claude/hooks/claude-island-hook 写 JSON 到远端 /tmp/claude-island.sock
3. ssh -R 把字节透到 Mac /tmp/claude-island-dev-vm.sock
4. HookSocketServer(host: .remote("dev-vm")) accept connection
5. 解析 HookEvent, 注入 host, 调 SessionStore.process(.hookReceived(event))
6. SessionStore.processHookEvent: 不存在则 createSession, 存在则 event.determinePhase() 决定 transition
```

状态机零改动。

### 路径 B：审批回写

```
1. 远端 hook 发 PermissionRequest, 保持 socket 连接 keep-alive
2. Mac SessionStore 收事件, HookSocketServer 把 (toolUseId, clientSocket) 进 pendingPermissions
3. 用户点 Allow → respondToPermission(toolUseId:, decision:) 写 JSON 回那条 client socket
4. 字节通过 ssh 反向隧道原路返回远端 hook 进程
5. 远端 hook 解析响应 → 喂 Claude
```

不变量：`pendingPermissions` 缓存、`(sessionId:toolName:serializedInput)` FIFO 重建 toolUseId 的逻辑、5 分钟 hook 超时——全部对 local/remote 同构。

### 路径 C：消息注入与审批按键

**审批按键 1/2/n**：方案 A 下远端 claude 跑在 Mac Ghostty 的 SSH pty 里，按键路径 `Ghostty AppleScript → 本地 pty → SSH → 远端 claude TUI` 完全透明。`ToolApprovalHandler` 走 Ghostty 分支时**完全免费**。

**面板回复 (chat send)**：同路径，`GhosttyInjector.inject` 找到对应 surface 后 `input text "..."` + 双 Enter。

**远端 surface 匹配**：见上 `GhosttySurfaceMatcher`。

### 不做的：JSONL 远端访问

`ConversationParser` / `JSONLInterruptWatcher` 只对 `host == .local` 启用。远端 session：
- 对话历史靠 hook 事件流（`UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop`）重建——粒度比 JSONL 粗，已知 limitation
- "Interrupted by user" 检测：远端只能靠 hook 的 `Stop` 事件，失去 JSONL watcher 的细粒度中断检测——可接受降级
- v2 可加 `tail -f` over SSH 的远端 JSONL watcher，不进 v1

## 生命周期与错误处理

### 启动

App launch（`App/AppDelegate.swift`）:
1. `RemoteHostRegistry.load()` 从 UserDefaults 读 hosts
2. `HookSocketServer(local).start()`
3. 对每个 `enabled` host:
   - `HookSocketServer(remote: host).start()`
   - `SSHBridgeController.start(host: host)`

### 桥断开

`SSHBridge.processDidExit`:
1. 通知 `SessionStore`：所有 `host == self.host` 的 session 设 `connectionState = .reconnecting(attempt: 0)`
2. UI：那些 session 行加灰、tooltip 显示 "Reconnecting..."；**SessionPhase 不变**——重连后还想接着审批
3. 指数退避重试：1s, 2s, 4s, 8s, 16s, 30s, 60s, 60s...（封顶 60s）。每次重试更新 `attempt`
4. 重连成功：清掉 `connectionState`。Pending permission 在远端 hook 那边等了多久就接着等多久，直到 hook 自身 5 分钟 timeout（Claude Code 内置）

### Sleep / Wake

- `NSWorkspace.willSleepNotification` → `SSHBridgeController.suspendAll()`：SIGTERM 所有 ssh 子进程，UI 显示"主机已断开"
- `NSWorkspace.didWakeNotification` → `resumeAll()`：重新跑启动序列
- 唤醒后远端 PermissionRequest 可能已 timeout 死掉——这是 Claude Code hook 协议本身的限制，不可恢复，可接受

### 已有的"5 分钟 hook 静默 → 强制 idle"

- 对远端 session 同样适用，但要补丁：判定时跳过 `connectionState == .reconnecting` 的 session，否则桥重连期间 `.processing` session 会被错误降级到 `.idle`
- 实现位置：`SessionStore` 的相应判定函数（`fe9a069` commit 引入的那段）

### Session 何时变 `.ended`

- 远端 hook 发 `Stop` event：正常结束
- 用户关 Ghostty SSH tab：远端 claude 被 SIGHUP，hook 触发 `Stop` → 走正常路径
- 用户 Ctrl-C 杀本地 ssh：远端 claude 死了但 hook 不一定来得及发 `Stop`——这种 session 会变成"5 分钟无活动 → 强制 idle"，不会被标记为 ended。**可接受降级**

### 远端 socket 残留

启动 `ssh -R` 时若远端 `/tmp/claude-island.sock` 已存在（上次异常退出残留），靠 `StreamLocalBindUnlink=yes` 让 ssh 自己 unlink 重建。该选项远端 sshd 不许时 fallback：先 `ssh -o BatchMode=yes <target> 'rm -f /tmp/claude-island.sock'` 再起隧道。

## UI

### 配置入口

Settings 窗口加一个 "Remote Hosts" tab：

- 列表：每行 `[name] [sshTarget] [enabled toggle] [status: connected/reconnecting/error] […]`
- "Add Host" 按钮 → 弹窗收集 `name`、`sshTarget` → Save 时按顺序：
  1. 连通性探测
  2. 版本探测
  3. `RemoteHookInstaller.install`
  4. 启动桥
  5. 任一失败：弹错文案，回滚（unlink remote files、不写本地 settings）
- 每行 "Uninstall" 按钮：跑 `uninstall` + 删 host 配置

### Session 列表展示

- 项目名渲染：`<host>:<projectName>` 当 `host != .local`
- 行首加小标识区分（具体视觉语言由 cat-rebrand 决定）
- `connectionState == .reconnecting` 的 session：整行加 50% 灰；hover tooltip：`Reconnecting (attempt N)…`
- 状态栏 / 岛屿聚合状态计算时（idle/working/approval）远端 session 与本地一视同仁

## Spike & 风险

写实现前必须做的验证（按依赖顺序）：

1. **Ghostty surface 子进程匹配**：能否从 Ghostty AppleScript（或 fallback `ps`）稳定拿到 surface 内 `ssh` 子进程的命令行参数，用来匹配远端 host
2. **SSH 反向 Unix socket 转发**：在用户的实际 dev VM 上确认 `StreamLocalBindUnlink=yes` 可用、`/tmp/` 写权限正常、sshd 不会主动断 idle 反向转发
3. **Hook 事件透过 ssh -R 的延迟**：典型 LAN 延迟 < 50ms 的话 hook 5 分钟超时绰绰有余，但跨地域 dev VM 要确认

## 测试

pkmon-island 没有测试 target（CLAUDE.md 明文）。验收靠人工跑：

**Smoke matrix**（每个 release 至少跑一遍）：

- [ ] 加 host → install 成功 → 桥 connected
- [ ] 远端开 Ghostty SSH → 跑 `claude` → session 出现在 Mac 菜单栏
- [ ] 远端 claude 用 Bash tool → Mac 弹 Approval → 点 Allow → 远端继续执行
- [ ] 面板里发文字 → 远端 claude 收到作为 user message
- [ ] 远端 claude 完成 → session 进 `.idle`
- [ ] 远端 claude `/clear` → session 历史清掉但保留 sessionId
- [ ] 远端 claude `Stop` → session `.ended` → 从列表清掉
- [ ] 网络切换 / wifi 短暂断开 → session UI 进 reconnecting 灰态 → 恢复后仍能审批
- [ ] Mac sleep → wake → 桥重连 → session 状态正确
- [ ] 多个远端 session（同一 host 多个 Ghostty SSH tab）并发不打架
- [ ] 本地 session 和远端 session 同时存在不互相干扰

不能声称"已验证"如果没真的跑过对应路径——CLAUDE.md 那条铁律对这次改动同样适用。

## 实现阶段建议（不绑定，仅供 plan 阶段参考）

1. **Phase 0 · Spike**：Ghostty surface 子进程匹配 + SSH 反向 unix socket 在目标 dev VM 的可行性
2. **Phase 1 · 数据模型**：`SessionHost` enum + `SessionState.host` 字段 + `HookSocketServer` 可实例化（先不接 SSH，本地双 server 跑通）
3. **Phase 2 · SSH 桥**：`SSHBridge` + `SSHBridgeController` + 重连/sleep-wake，但 hook 安装还手动
4. **Phase 3 · 远端安装**：`RemoteHookInstaller`
5. **Phase 4 · 注入**：`GhosttySurfaceMatcher` 远端分支
6. **Phase 5 · UI**：Settings 的 Remote Hosts tab + session 列表的 host 标识
7. **Phase 6 · QA pass**：跑 smoke matrix
