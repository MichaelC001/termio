# Unpeel

> termio 的**设计原型**与直接对标。理念完整，四大差异化齐全；闭源、单人维护。

## 一句话定位

原生 macOS 终端，"把每个 AI 编码 Agent 当队友放在一处"，自带 **Sessions MCP**
让一个 Agent 读取/驱动另一个 Agent 的会话。

## 厂商 / 开源 / 链接

- 作者：Tommy Vedvik（独立开发者，@tommyvedvik）
- 开源：否（闭源商业产品）
- 价格：**$59 一次买断**（7 天试用，无需账号），首年更新含、续费半价
- 站点：https://unpeel.com

## 技术栈与形态

- **Swift + libghostty**（与 termio、cmux 同源的终端核），Metal 渲染，原生非 Electron。
- 仅 Apple Silicon、macOS 原生 App；本地优先，**无遥测、无云、无账号**。

## 核心能力

- **项目 → 会话侧栏**：会话从首个 prompt 自动起标题，按项目分组；侧栏读起来像仪表盘
  （谁忙、谁完成、谁需要你）。
- **Sessions MCP**（招牌）：本地 MCP server，让任一会话安全地"看见并驱动"兄弟会话——
  读输出、输入 prompt、替它回答菜单、甚至启停会话。默认按项目作用域隔离，可整体关闭。
  这是其"Agent 编排 Agent，人不在每个按键的回路里"的核心。
- **永不消亡**：每个会话跑在独立宿主进程，**退出/崩溃/重开窗口后 Agent 仍在工作**；
  菜单栏小图标常驻——有人在干活就转，有人需要你就响，点击把窗口拉回该会话。
- **内建 git worktree**：每个 Agent 一分支一 checkout，按项目分组，互不踩踏。
- **快速预设**：Claude / Codex / Gemini 等，带正确 flag 与项目，一键起。
- **刻意不做 diff / 代码面板**："Agent 已经活在代码里"，Unpeel 只留对话。

## 优势

- 理念完整：never-die / 状态盘 / Sessions MCP / worktree 四件套齐全，定位清晰。
- 本地优先、隐私友好；一次买断、定价克制。
- 与 termio 哲学高度一致——是 termio 最好的"北极星"。

## 劣势

- 闭源、单人维护，迭代与生态速度受限。
- 仅 Apple Silicon / macOS。
- 声量与社区远小于开源的 cmux（见 [02](02-cmux.md)）。

## 与 termio 的异同 / 启示

- **同源同philosophy**：Swift+libghostty、项目/会话侧栏、菜单栏脉冲、worktree、不做 diff、本地优先。
  termio 基本是 Unpeel 的"开源可定制"再实现。
- **termio 已补齐**：状态盘（零配置，且因自有 PTY 比外挂更省心）、worktree、菜单栏托盘、设置。
- **仍缺的两项护城河**：
  1. **Sessions MCP**——价值高、成本中等（有官方 `modelcontextprotocol/swift-sdk`），应作下一阶段 P0；
  2. **never-die 宿主进程**——价值最高但改造量最大，建议 MCP 稳定后再啃。
- **termio 可超越 Unpeel 的点**：开源/可定制、更广的 Agent 预设面（OpenCode/Pi…）。

## 参考链接

- 产品站：https://unpeel.com
- 作者：https://x.com/tommyvedvik
