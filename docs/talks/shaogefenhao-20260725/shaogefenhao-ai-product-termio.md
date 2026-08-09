---
marp: true
theme: default
paginate: true
size: 16:9
style: |
  section {
    font-family: "PingFang SC", "Helvetica Neue", system-ui, sans-serif;
    font-size: 28px;
  }
  h1 { font-size: 42px; }
  h2 { font-size: 34px; }
  code { font-size: 0.85em; }
  table { font-size: 22px; }
  footer { font-size: 14px; color: #888; }
  section.lead h1 { font-size: 48px; }
  section.lead p { font-size: 26px; color: #444; }
  section.section-title h1 { font-size: 40px; }
  ul { line-height: 1.45; }
  blockquote { font-size: 26px; border-left: 4px solid #333; padding-left: 1em; }
footer: 少个分号 · AI 编程范式下产品开发全过程 · termio.sh
---

<!-- _class: lead -->

# AI 编程范式下产品开发全过程
## termio.sh

Terminal-first Agentic Development Environment

袁继伟 · 40–60 min · [termio.sh](https://termio.sh)

---

# 大纲

1. **序章** — Demo 演示
2. **缘起** — 问题驱动：为什么做 Terminal-first ADE？
3. **产品设计** — 用户画像、核心场景、MVP
4. **技术实现** — 架构总览 + 三个关键难点
5. **Agentic Engineering** — skills · workflow
6. **迭代优化** — 从可用到好用
7. **未来展望**
8. **总结与启示**

---

<!-- _class: section-title -->

# 序章：Demo 演示

先看产品，再听故事。

---

# Demo 建议脚本（3 段 × ~1 min）

| 段 | 看什么 | 证明什么 |
| --- | --- | --- |
| 1 | 同一项目里并排跑 Claude Code / Codex / OpenCode | 多 agent 编排，不是又一个 IDE |
| 2 | 侧栏状态点 + 菜单栏 tray | idle / working / needsAttention / done |
| 3 | iPhone 扫码 → 看会话 / 发消息 / 读文件 | 本地 PTY 主机 + 移动端 companion |

> 现场可打开：`termio` 主窗 + 菜单栏 + TestFlight / 模拟器

---

# 一句话定位

> **Stop babysitting terminals.**  
> 在真实原生终端里，编排你已经在用的 coding agent。

- 不是 Cursor 插件
- 不是 Electron 套壳
- 不是云端托管 agent
- **是**：macOS 原生 · libghostty · 本地 PTY · 可选 iOS 远程

---

<!-- _class: section-title -->

# 缘起 —— 问题驱动

为什么做 Terminal-first 的 Agentic Coding Environment？

---

# 亲历痛点（2025–2026）

Agent 时代，最慢的一环变了：

1. **窗口 babysitting** — 十几个 terminal，不知道谁在跑、谁卡权限
2. **状态不可见** — agent 在思考还是在等你？离开工位就断线
3. **工具碎片** — Claude Code / Codex / OpenCode / Pi … 各是一套 CLI
4. **桌面 ↔ 手机断层** — 路上没法续上正在跑的会话

> 问题不是「不会写代码」，是 **编排与注意力**。

---

# 为什么是 Terminal-first？

Coding agent 的「家」天然在终端：

- CLI agent 已是主流工作方式（Claude Code、Codex、OpenCode…）
- TUI 就是 agent 的 UI —— 再包一层 Web IDE 是重复劳动
- 终端 = 真实 PTY = 真实权限 / 真实 shell / 真实工具链

**IDE 在帮人写代码；ADE 在帮人管 agent。**

（延伸阅读：仓库博客 *从 IDE 到 ADE*）

---

# 关键产品判断（做了什么、不做什么）

| 做 | 不做 |
| --- | --- |
| 原生 macOS（Swift + AppKit/SwiftUI） | Electron / 纯 Web 壳 |
| 拥有 PTY（libghostty / Metal） | 只 tail 日志、不拥有运行时 |
| 多 agent 侧栏 + 状态 tray | 做成完整 IDE（重编辑器） |
| 本地优先、无账号 | 强制云同步 / 订阅门禁 |
| 配置驱动适配 agent | 每加一个 agent 改一堆 Swift |

---

# 赛道里的位置（2026-07）

同桌面位置的产品：Unpeel · cmux · Conductor · herdr · Warp Oz …

**Termio 押注的差异：**

1. **原生 + libghostty + 零配置状态 + 菜单栏 ambient**
2. **first-class worktree / 会话编排**（不是「建议你自己用 git」）
3. **iOS companion**（手机不是第二套 TUI，是监督面）
4. **小而意见化** —— 不和 cmux 拼 breadth

> 文档：`docs/competitive-analysis/09-differentiation-and-gaps.md`

---

<!-- _class: section-title -->

# 产品设计

用户画像 · 核心场景 · MVP

---

# 用户画像（只打一个核心）

**重度 CLI agent 用户**

- 已经付费 / 日常用 Claude Code、Codex、OpenCode 等
- 同时跑多个 session，靠自己记「谁在干活」
- 在乎：本地、隐私、原生手感、键盘流
- 不在乎：再学一个云 IDE、再开一个账号

次要：小团队 TechLead、想远程瞟一眼 agent 的移动用户。

---

# 核心场景（3 个就够）

1. **启动与并行**  
   一个 project → 多个 session → 一键起不同 agent
2. **盯状态**  
   侧栏点 + 菜单栏铃：working / needs you / done  
   人不需要一直盯着 TUI
3. **离开工位仍在线**  
   iOS 扫码配对 → 看 roster、读文件、补一句 prompt

其余功能都服务这三条。

---

# MVP 怎么裁

**必须有**

- Projects → Sessions 侧栏
- 真 PTY 终端（会话切换不杀进程）
- Agent 预设启动（Claude / Codex / …）
- 状态可见（至少 needsAttention）
- 本机免费可用、无账号

**故意后置 / 克制**

- 不做「第二个 Cursor」（不以代码面板为中心）
- 早期不做 never-die host / 重云同步
- 沙箱先 Seatbelt 再 VM —— 后来甚至 **拆掉自研沙箱**，把隔离交给 agent 自己

> 裁剪比堆功能更难；AI 时代尤其如此。

---

# 关键产品决策（真实做过的）

| 决策 | 为什么 |
| --- | --- |
| 2026-06-26 从 Zed fork **推倒重来** → Swift + libghostty | fork 成本 > 自建 PTY 壳 |
| Agent = **配置文件**，不是枚举 | 加 Grok 曾改 6 个文件；现在 drop JSON 即可 |
| 状态三层：OSC/铃 → hooks → title 规则 | 零配置兜底 + 精确 busy |
| Git 面板从「有」做到 **TextKit 级 diff** | 用户反馈 + JetBrains / GitHub Desktop 对照 |
| iOS：**有终端，但不把 TUI 当唯一监督面** | 手机上看 raw TUI 体验差 → 结构面协议在演进 |

---

<!-- _class: section-title -->

# 技术实现

架构总览 · 三个关键难点

---

# 端到端架构（一图）

```
┌─────────────────────────────────────────────────────────┐
│  macOS termio (Swift + AppKit/SwiftUI)                  │
│  Sidebar · TermioStore · MenuBar · Git · Editor         │
│         │                                               │
│         ▼                                               │
│  libghostty (Metal)  ←→  PTY  ←→  shell / agent CLI     │
│         │                                               │
│  HookListener  ←  termio agent report (unix socket)     │
│  AgentCatalog  ←  Resources/agents/*.json + ~/.termio/  │
│         │                                               │
│  CompanionServer (WebSocket)                            │
└─────────┼───────────────────────────────────────────────┘
          │  Shared WireProtocol (TermioShared)
          ▼
┌─────────────────────┐     ┌──────────────────┐
│  iOS TermioMobile   │     │  Landing / Docs  │
│  roster · PTY view  │     │  Next.js · R2    │
└─────────────────────┘     └──────────────────┘
```

---

# 仓库长什么样（实现层）

| 路径 | 职责 |
| --- | --- |
| `Sources/termio/` | macOS 主应用 |
| `Shared/` | Mac ↔ iOS 线协议与共享模型 |
| `ios/` | TermioMobile |
| `companion/` | 配套 companion 进程 |
| `Resources/agents/*.json` | 内置 agent 清单（10+） |
| `.claude/skills/` | 工程化 skills |
| `docs/design/` · `docs/bug/` | 设计与事故档案 |
| `web/landing/` | 官网 + fumadocs |

**数字感（量级）**：主仓数百次提交的近三周迭代；Swift 源码贯穿 Mac / iOS / Shared。

---

# 难点 1：终端设计

**目标**：原生、快、会话可切换、agent TUI 全屏可用。

**关键实现**

- **libghostty** 渲染（Metal），非 WebView
- **SurfaceCache**：按 session id 缓存 `TerminalController`  
  侧栏切换 = 重挂 surface，不重 spawn
- **PTY 生命周期** 与窗口 focus / resize 强相关

**近三周真实坑（对话 + bug 文档）**

- 打开会话时 **窄 grid → banner 冻住**（先布局再 spawn）
- **resize 不 reflow**（上游 libghostty / fork 修复）
- focus 丢失（新 session / sibling render / window key）
- 链接 hover、主题与 Ghostty 兼容性

> 终端不是「嵌个 view」，是一整条 **布局 → PTY → 渲染** 链路。

---

# 难点 2：Agent 适配

**目标**：加 agent 不改 Swift；状态可信；/clear 后身份不漂。

**抽象（`AgentDefinition`）**

```
id · command · resumeSpec · icon · tint
hookSpec | statusRules | titleRules
→ 同一条加载路径：bundled JSON + 用户 manifest
```

**状态机**

`idle → working → needsAttention | done`

权威来源（仲裁）：

1. **Hooks**：`termio agent report working|attention|done|idle`
2. **OSC 铃 / 通知**（零配置 needs you）
3. **Title 规则**（Claude spinner / Codex Action Required…）

**近三周演进**

- 配置驱动 resume · conversation rotation（`/clear` 后 trace 对得上）
- Grok 状态点颜色、hook 装错 channel（dev 盖写 release）
- Add Agent 菜单、availability 检测

---

# 难点 2 续：一个 public contract

```bash
termio agent report <working|attention|done|idle>
```

- 读 `TERMIO_SESSION` + `PWD`
- 打到 **channel-scoped** unix socket（dev / release 隔离）
- 各 agent 的 JSON/TOML/plugin installer 只调这一句

**教训**：曾经 worktree 里的 dev app 把 **bundle 内绝对路径** 写进全局 hook → 全机状态串台。  
修复 = **路径 + channel** 一起设计，而不是「hooks 能跑就行」。

---

# 难点 3：iOS 移动端

**目标**：离开 Mac 仍能监督 agent，而不是在手机上硬看 TUI。

**架构**

- Mac = **PTY host**（唯一真相源）
- iOS = **companion client**
- `TermioShared.WireProtocol`：auth · attach · start · resize · files · trace…

**近三周在做的**

- Chats / Projects 信息架构（默认 agent、FAB 添加）
- worktree 分支、Markdown preview 同步到手机
- Ghostty iOS renderer panic / teardown UAF
- TestFlight 上架路径
- 更远：`mobile-agent-ui-protocol` —— PTY 旁路结构面（ACP 词汇）

> 判断：**手机需要终端能力，但不该把 agent TUI 当唯一 UI。**

---

# 技术小结：三个难点的共性

| 难点 | 核心矛盾 | Termio 的解法 |
| --- | --- | --- |
| 终端 | 真 PTY vs 易嵌入 | 拥有 surface + 缓存 + 修上游 |
| Agent | 多 CLI 碎片 vs 统一体验 | Manifest + hook contract + 多层状态 |
| iOS | 远程可见 vs 本地真相 | Mac host + 薄 wire + 逐步结构化 |

**共同原则**：本地优先、零配置兜底、配置驱动扩展、先可用再精确。

---

<!-- _class: section-title -->

# Agentic Engineering

skills · workflow

---

# 我们不是「用 AI 聊天写代码」

而是把协作固化成 **可重复的工程资产**：

```
人设目标 / 取舍
    ↓
docs/design|bug|rfc   ← 单一事实源（front matter 状态机）
    ↓
skills / prompts      ← 可调用的动作
    ↓
worktree + agent 并行
    ↓
conventional commit · rebuild · 验证
    ↓
用户反馈 → 下一轮 doc
```

---

# Skills（仓库里真实存在的）

| Skill | 干什么 |
| --- | --- |
| `macos-rebuild-dev` | 杀进程 → SwiftPM 构建 → 拉起 dev app |
| `ios-rebuild-dev` | 装到真机 / 模拟器，指到本机 companion |
| `bump-version` | 打 tag、走发版 |
| `conventional-commit` | 规范提交信息 |
| `doc` | 建/改设计文档 + 维护 docs 索引 |
| `app-screenshot-debug` | AppleScript 点 UI + 截窗调试 |
| `og-generation` | 官网 OG 图 |

**原则**：高频、易错、跨会话要一致的步骤 → skill；一次性探索 → 普通对话。

---

# Workflow：一条真实闭环

**例子：状态点不对 / `/clear` 后 trace 旧数据**

1. 现象截图进会话（用户投诉）
2. 写 / 改 design doc（`clear-conversation-rotation.md`）
3. worktree 实现 → PR
4. hooks + title 规则回归
5. `conventional-commit` → review → merge
6. 若发版：`bump-version`

**例子：Git 面板「不像 2026」**

- 对照 GitHub Desktop / JetBrains → TextKit diff → 多轮视觉反馈  
- 不是一次 prompt 生成完，是 **设计文档 + 多 agent 接力 + 截图验收**

---

# AI 编程工程化：可带走的清单

**值得固化成 skill / doc 的**

- 构建与重装路径（Mac / iOS 不一致会要命）
- 发版、commit 规范
- 设计决策与事故（bug handoff）
- 带验收标准的任务（「先读 doc，再改代码」）

**不要过度自动化的**

- 还在摇摆的产品取舍
- 需要你看一眼 UI 的审美判断
- 权限 / 公证 / 证书类一次性操作（可 runbook，慎全自动）

> AI 加速的是回路；**判断仍在人。**

---

<!-- _class: section-title -->

# 迭代优化

从可用到好用：用户反馈驱动演进

---

# 近三周在真实发生什么

（来自本仓库 Claude Code 会话 + git 主线，压缩后）

| 主题 | 用户/自我信号 | 演进 |
| --- | --- | --- |
| Agent 状态 | 转完还在转；Grok 黄点不是绿点 | hooks · title · done 仲裁 |
| `/clear` | OSC 标题 / trace 旧数据 | conversation rotation |
| Git | 「和 WebStorm / Desktop 差太多」 | TextKit diff · History · avatars |
| Agent 扩展 | 加一个 agent 改一堆文件 | `agents/*.json` catalog |
| iOS | FAB、Chats、TestFlight | companion parity |
| Landing | 文档搜索、changelog、OG | fumadocs · llms.txt |
| 终端细节 | 换行、空白行、focus | 上游 + 布局时序 |

**节奏**：能感知的问题 > 想象中的 roadmap。

---

# 从「能跑」到「好用」的几条规律

1. **状态可信是 ADE 的生命线**  
   点错颜色 = 用户失去信任，比少一个功能更致命
2. **原生手感是付费意愿的前置**  
   Liquid glass、间距、图标描边……对话里大量是「像素级」反馈
3. **移动端是监督，不是缩小版桌面**
4. **删掉错误抽象也是进度**  
   例如移除自研 sandbox，把复杂度还回去
5. **文档是异步团队协议**  
   一个人 + 多 agent = 也需要 design / bug handoff

---

# 反馈从哪来

- 自己每天用（dogfood）—— 状态点、快捷键、focus
- 截图进 agent（「这里空白太多」「图标白边」）
- 竞品对照（otty / Conductor / Ghostty / Desktop）
- 社区与上架路径（Discord、TestFlight、Homebrew 意向）

**方法**：反馈 → 是否改定位？→ 否：进 bug/design → 并行 agent 修 → 当日可装的 dev app 验证。

---

<!-- _class: section-title -->

# AI 编程的未来展望

---

# 几个可讨论的判断

1. **瓶颈从「写代码」迁到「编排与确认」**  
   队伍掉头：人排队等机器 → agent 排队等人
2. **ADE 会与 IDE 长期并存**  
   IDE 管代码真相；ADE 管 agent 舰队
3. **拥有运行时的人赢监督**  
   只做看板、不拥有 PTY 的工具容易死（竞品已有先例）
4. **本地 + 移动监督** 会是专业用户的默认形态  
   云 ADE 服务另一群人
5. **Agent 会编排 agent**  
   Sessions MCP / 结构化协议是下一层（Termio 路线图上的 moat 位）

---

# Termio 还在爬的坡

| 方向 | 状态感 |
| --- | --- |
| 状态层打磨 | 已可用，边界 case 仍在修 |
| 会话跨 app 存活（daemon） | 设计中 |
| Sessions MCP | 差距项 / 高价值 |
| 移动端结构面（非纯 TUI） | 设计 + 部分落地 |
| 远程项目 / relay | 设计中 |
| 分屏树 | 设计 / 进行中 |

分享的重点不是路线图本身，而是：**怎么用 AI 编程把坡爬下去。**

---

<!-- _class: section-title -->

# 总结与启示

如何用 AI 编程，快速把产品想法变成用户喜欢的产品

---

# 启示（可执行）

1. **从自己的痛点出发，场景压到 3 个以内**  
   MVP 是裁，不是堆
2. **先选对形态，再堆功能**  
   Terminal-first / 原生 / 本地 —— 是定位，不是实现细节
3. **为 AI 协作修路**  
   design doc · skills · worktree · 验收标准
4. **用反馈打磨「信任相关」体验**  
   状态、性能、像素 —— 比新功能列表更优先
5. **保持删的勇气**  
   错误抽象、过早平台化、抄竞品 breadth

---

# 一张图收束

```
痛点 → 定位 → MVP 裁剪
              ↓
        架构三个难点
              ↓
   skills / docs / 并行 agent
              ↓
     用户反馈 → 再裁 / 再磨
              ↓
        用户愿意每天打开
```

**产品能力 × 工程能力 × AI 回路 = 从想法到喜爱**

---

# 谢谢

**Termio** — the terminal home for your AI coding agents  
https://termio.sh

- Demo / 下载：官网  
- 问题欢迎现场砸：架构 · agent 适配 · iOS · 怎么用 AI 做产品  

Q & A

---

# 附录 A · Demo 检查清单

- [ ] 主窗：至少 2 个 agent 会话 live
- [ ] 侧栏 status 点会动
- [ ] 菜单栏 tray 能点回 session
- [ ] Settings 里 agent 列表 / Add Agent
- [ ] iOS 已配对（或录屏备用）
- [ ] 一个「修 bug」小任务 ready（现场 /clear 或 status 演示）

---

# 附录 B · 关键代码入口

| 主题 | 从这里读 |
| --- | --- |
| Agent 模型 | `Sources/termio/AgentDefinition.swift` |
| 状态与 hooks | `TermioStore` · `HookListener` · `docs/design/vibe-island-status.md` |
| Agent 配置 | `Sources/termio/Resources/agents/*.json` |
| 设计：Agent 抽象 | `docs/design/agent-abstraction-and-configuration.md` |
| Companion 协议 | `Shared/.../WireProtocol.swift` |
| 竞品与差异 | `docs/competitive-analysis/09-*.md` |
| Skills | `.claude/skills/*/SKILL.md` |

---

# 附录 C · 近三周对话主题词云（主持备用）

`status hooks` · `/clear` rotation · **Git TextKit diff** · agent.json catalog ·  
Grok icon / 状态色 · **iOS FAB & TestFlight** · markdown preview ·  
landing fumadocs · resize/reflow · focus · worktree · Homebrew ·  
split pane · command palette · sandbox 拆除 · dogfood 截图反馈

> 整场分享的「血肉」大多来自这些真实回路，而不是虚构 roadmap。
