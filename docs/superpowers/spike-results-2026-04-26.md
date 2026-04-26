# SSH-remote spike findings — 2026-04-26

Run by Claude on the user's primary Mac, against the user's `ssh dev` alias
(actual host `chendaxin.tk@10.37.107.27`).

## OpenSSH versions

- **Mac client**: OpenSSH_9.9p2 (LibreSSL 3.3.6) — well above the 6.7
  threshold for `StreamLocalBindUnlink` / Unix-socket forwarding.
- **Remote sshd**: `OpenSSH_7.9p1 Debian-10+deb10u4` — also ≥ 6.7. Remote
  is Debian Linux 5.4 kernel. `python3` and traditional `nc 1.10` available
  (the latter does NOT support `-U` for Unix sockets — install/script paths
  must NOT depend on remote `nc -U`).

## Step 2 — Reverse Unix-socket forwarding (byte transit)

**Result: ✅ PASS.**

Setup:
```
mac: nc -lU /tmp/claude-island-spike.sock > /tmp/spike-output.txt
mac: ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
         -o StreamLocalBindUnlink=yes \
         -R /tmp/claude-island.sock:/tmp/claude-island-spike.sock dev
remote (via separate ssh): python3 -c "
    import socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect('/tmp/claude-island.sock')
    s.sendall(b'{\"hello\":\"py-attempt-2\"}\\n')
    s.shutdown(socket.SHUT_WR)
    s.close()"
```

Mac listener captured: `{"hello":"py-attempt-2"}` (25 bytes, byte-for-byte).

Implication for the implementation: the `ssh -R` reverse-Unix-socket
forwarding model the design depends on works end-to-end on this dev VM.
The byte path `remote hook script → remote /tmp/claude-island.sock →
ssh tunnel → Mac /tmp/claude-island-<host>.sock → HookSocketServer` is
viable.

## Step 3 — `StreamLocalBindUnlink=yes` stale-socket recovery

**Result: ❌ FAIL.**

Test 1: pre-create a regular file at `/tmp/claude-island.sock` on remote.
Start tunnel with `StreamLocalBindUnlink=yes`. Expected the option to
unlink + rebind. Actual: `Error: remote port forwarding failed for listen
path /tmp/claude-island.sock`.

Test 2: leave a stale Unix socket from a dirty-killed prior `ssh -R`.
Restart the tunnel with `StreamLocalBindUnlink=yes`. Same failure mode.

The remote sshd is OpenSSH 7.9p1. The man page says
`StreamLocalBindUnlink yes` should make sshd unlink existing socket
files. Empirically it does not on this VM — likely the sshd config
disables it, or 7.9p1 honors it only for local forwards, not `-R`.

**Action item for Phase 4 (`SSHBridge`)**: the explicit
`ssh <target> 'rm -f /tmp/claude-island.sock'` fallback in
`SSHBridge.cleanupRemoteSocket()` is **mandatory**, not optional.
Furthermore, the cleanup must happen **before** every fresh tunnel
attempt, not only on stop. Concretely: `runOnce()` should pre-clean the
remote socket (best-effort) before launching ssh.

Implementation note for Task 8 follow-up: add a pre-cleanup step at
the top of `runOnce()` analogous to `cleanupRemoteSocket()` but
synchronously awaited. Since `SSHCommandRunner.run` is `async throws`,
it can be `_ = try? await SSHCommandRunner.run(...)` in the actor
context.

## Step 4 — Ghostty surface → SSH-child detection

**Result: ✅ PASS (mechanism verified).**

`osascript -e 'tell application "Ghostty" to get tty of every terminal'`
returned `/dev/ttys001, /dev/ttys000, /dev/ttys006`. Ghostty's AppleScript
sdef exposes `tty` per-surface as expected (post-1.3.1 behavior).

`ps -t ttysNNN -o pid,ppid,command` walks the entire descendant tree
under the given tty:

```
=== ttys000 ===
70824 68850 /usr/bin/login -flp ...
70825 70824 -/bin/zsh
72329 70825 claude
94745 72329 /Applications/Xcode.app/.../sourcekit-lsp
=== ttys001 ===
68997 68850 /usr/bin/login ...
68998 68997 -/bin/zsh
80584 68998 claude
82794 80584 /Applications/Xcode.app/.../sourcekit-lsp
99308 80584 caffeinate -i -t 300
```

Note: even processes 2-3 levels deep (`sourcekit-lsp`, `caffeinate`) are
listed. That confirms `ps -t` will find an `ssh dev` process spawned
inside any descendant of a Ghostty surface's shell.

No live `ssh` was open at spike time, so a positive detection wasn't
exercised end-to-end. But: the mechanism is correct (claude /
sourcekit-lsp / caffeinate were all detected as descendants of their
respective ttys), so an `ssh` running there would be reported the same
way. No `lsof` fallback needed.

A bash-tool spawned `ssh -N dev` (no controlling tty) showed up in `ps`
with `TTY=??` and would NOT be listed by any `ps -t`. That's expected
and irrelevant — the production scenario is a user-typed `ssh dev` in a
Ghostty pty, which always has a tty.

## Action items for the implementation

1. **Task 8 (`SSHBridge.runOnce`)**: add explicit pre-cleanup of the
   remote socket before each `ssh -R` launch. Cannot rely on
   `StreamLocalBindUnlink=yes`. Concretely insert at the top of `runOnce`
   (after `Process()` is constructed but before `proc.run()`):
   ```swift
   _ = try? await SSHCommandRunner.run(
       target: host.sshTarget,
       remoteCommand: "rm -f /tmp/claude-island.sock",
       timeout: 5
   )
   ```
   This adds ~one-RTT to every tunnel-establish, but reconnects are rare
   and the alternative is a wedged `remote port forwarding failed` loop.

2. **Task 12 (`GhosttySurfaceMatcher`)**: implement using `ps -t <tty>
   -o command=`. The plan's primary path (`ps -t`) is confirmed working;
   no `lsof` fallback needed. Match each line with `(s.hasPrefix("ssh ")
   || s.contains(" ssh ") || s.contains("/ssh ")) && (s.contains(target)
   || s.contains(alias))`.

3. **Task 11 (`RemoteHookInstaller`)**: do NOT depend on remote `nc`
   for any install-time check or smoke test. The remote `nc` lacks
   `-U`. Use `python3 -c "import socket; ..."` if a Unix-socket round
   trip is needed for verification.
