# Vibe Island 系（状态监控类）

> 不接管终端，只解决"Agent 现在啥状态"。是 termio **状态检测方法论的来源**；
> 但 termio 因自有 PTY，能做到它们做不到的零配置。

## 一句话定位

刘海 / Dynamic-Island 或菜单栏托盘风格的 macOS 小工具，**监控 Claude Code 等 Agent 状态**
（忙 / 等你输入 / 完成）。

## 厂商 / 开源 / 链接

- 本体闭源：https://vibeisland.app
- **关键开源参考**：
  - **`Octane0411/open-vibe-island`**（GPL，Swift）——最佳蓝图：
    `hook → unix socket → SessionState.apply reducer → 刘海 UI`；
  - `farouqaldori/vibe-notch`；
  - `gmr/claude-status`（status file + Darwin 通知 + FSEvents + 5s 轮询，多通道冗余）；
  - `sooink/claude-watch`（**无 hook**，直接 tail `~/.claude/projects/*.jsonl` 推断状态）。

## 检测机制（最可靠 → 最脆弱）

1. **Claude Code hooks**（`UserPromptSubmit`/`PreToolUse`→忙，`Notification`+`permission_prompt`→
   等你，`Stop`→完成）经本地 IPC 上报——**最准**。
2. **tail JSONL transcript** 推断——无需 hook，但 schema 不稳定。
3. OTLP 遥测 / Codex app-server JSON-RPC——协议干净但偏粗。
4. 进程树仅用于**校验**；无人靠屏幕抓取 / CPU 判忙闲。

## "等你输入"是最难的状态

Claude Code 只有 `Notification` 一个信号，且把"等权限审批（可靠、即时）"与
"等自由文本回答（~60s 定时器近似）"混在一起。要精确区分需 hook + JSONL 结合。

## 优势 / 劣势

- 优势：零侵入、装上就能盯状态；开源克隆多、方法论成熟。
- 劣势：**只做状态**，不接管会话/终端；多为外挂，靠 hook/JSONL 间接拿信号。

## 与 termio 的异同 / 启示

- **termio 的结构性优势**：因为**自己拥有 PTY**，已用 libghostty 直出的 bell / OSC 9·99 通知
  做到**零配置**"需要你"——这是 Vibe Island 那类外挂做不到的。
- **要拿到逐轮"思考中 / 在用哪个工具"的精度**，仍需补 **Claude Code hooks 层**：
  本地 listener + 按 `cwd`/worktree 唯一路径关联会话（termio 的每会话 worktree 正好给了唯一 cwd）。
  最佳实现蓝图就是 `open-vibe-island` 的 `hook → socket → reducer`。
- **形态选择**：termio 选**菜单栏托盘**（已做）而非刘海——更克制、不挡内容。

## 参考链接

- https://vibeisland.app
- https://github.com/Octane0411/open-vibe-island ｜ https://github.com/gmr/claude-status
- https://github.com/sooink/claude-watch
- Claude Code Hooks：https://code.claude.com/docs/en/hooks-guide
