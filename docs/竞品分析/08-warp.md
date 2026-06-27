# Warp（替代范式）

> AI 原生**通用终端**，强在单终端内的 Agent；但不做多 Agent 会话盘，且绑账号/云。

## 一句话定位

Rust 写的、自研 GPU 渲染的现代终端，把 AI 补全 / Agent 直接做进终端体验。

## 厂商 / 开源 / 链接

- 厂商：Warp（商业公司）。站点：https://www.warp.dev
- 闭源；订阅制（有免费额度 + 付费档）；需账号登录。

## 核心能力

- 块状（blocks）命令历史、AI 命令补全、内建 Agent 可在终端里执行任务。
- 单终端体验打磨精良（自研渲染、工作流、团队协作）。

## 优势

- 终端基础体验现代、流畅；AI 补全/Agent 集成度高。
- 公司规模与生态远超独立工具。

## 劣势 / 与 termio 的关系

- **不做多 Agent 会话盘**：核心是"一个好终端 + AI"，不是"把 N 个 Agent 编排在一处看状态"。
- **绑账号 + 云**：与 termio "本地优先、无账号、无遥测"正相反——这是 termio 面向隐私/内网用户的硬卖点。
- **范式不同**：termio 更专、更轻、更本地；Warp 更通用、更重、更云。
- **风险提示**：若 Warp 把"多 Agent 会话盘 + 状态"做进主产品，会压缩独立工具空间——
  termio 的对冲正是"原生轻量 + 不绑账号 + 不做 IDE"。

## 参考链接

- https://www.warp.dev

---

## 旁注：其它替代范式

- **Cursor / VS Code + 扩展**：IDE 内建 Agent，重 diff/代码面板——**与 termio 相反哲学**。
  termio 赌"Agent 已在代码里，人只需对话"。
- **Ghostty / WezTerm / iTerm2**：通用终端，是 termio 的**基底**而非对手。
  其中 **WezTerm 的 mux-server** 是 termio 做 never-die 宿主的最佳工程参考。
- **纯 tmux + worktree 手搓**：免费 DIY 基线，但无状态盘、无一眼概览、无品牌质感——
  正是 termio 要替代的体验。
