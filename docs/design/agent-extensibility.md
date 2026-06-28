---
title: 可扩展 Agent —— 配置化定义 + 配置化 Hook
status: draft
type: rfc
updated: 2026-06-28
related:
  - vibe-island-status.md
---

# RFC：可扩展 Agent —— 配置化定义 + 配置化 Hook

> 状态：草案（Draft）· 作者：—— · 关联：[`vibe-island-status.md`](./vibe-island-status.md)（hook 状态层的前置设计）
>
> 目标：让 termio 支持任意 CLI coding agent，且用户能**用配置（而非改 Swift、发版本）**新增一个 agent 及其状态 hook。

## 一、摘要（TL;DR）

termio 当前把 agent 写死成一个**闭合枚举** `AgentPreset`（`Models.swift:18-78`），新增一个
agent = 改 Swift + 发版。而 2026 年的 agent 榜单换得比发版还快（Gemini CLI 2026-06-18 起停服
个人用户、转向闭源 Antigravity；Claw Code 空降第一；Roo Code 自我归档）。结论：**不该用枚举追长尾，
应该把 agent 做成数据。**

本 RFC 提议：

1. `AgentPreset` 枚举 → `AgentDefinition` 值类型；内置 agent 仍在代码里（保留矢量品牌图标），
   用户 agent 从磁盘加载、与内置合并。
2. 采用 **一 agent 一目录** 的打包方式（VSCode extension 的*文件夹*模型，但**只取文件夹，
   不取 manifest / API / 市场**）：`~/.termio/agents/<id>/agent.json`。
3. Hook 也配置化：`agent.json` 里一个 `hooks` 块即可声明该 agent 的状态集成；常见情形是**纯声明
   数据**（event→state 映射），复杂情形提供 **shell 逃生舱**。
4. **明确否决**：内嵌 Lua 运行时、完整插件平台（manifest/activation/API/marketplace）、
   "termio 进程内执行 agent 代码"的 smart-receive 变体。

不变量保持不变：统一的 wire format（`{termio_session,state,cwd}` 经 `nc -U` 进一个 socket）、
**termio 自身从不执行 agent 提供的代码**（hook 始终跑在 agent 进程里）。

## 二、动机

### 2.1 枚举是闭合的

今天一个 agent 是 `AgentPreset` 的一个 case，硬编码 `displayName` / `command` /
`permissionBypassFlag` / `icon`。但设置层（`agentCommandOverrides`、`bypassPermissionAgents`、
`disabledAgents`，见 `Settings.swift`）**已经按 `rawValue`（字符串）寻址**，`Session` 也把
`agent` 以 rawValue 字符串持久化（`Models.swift:226-248`）。也就是说——数据模型其实已经*几乎*是
数据驱动的，唯一闭合的就是那个枚举。

### 2.2 长尾 + 高频换血

按 GitHub star（2026-06）：OpenCode ~176k（已内置）、Claude ~131k（已内置）、Gemini CLI ~105k
（**转 Antigravity**）、Codex ~90k（已内置）、OpenHands ~78k、Pi ~64k（已内置）、Cline ~63k、
Goose ~48k、Aider ~46k、Crush、Amp……缺口里大多数是**没有 hook 系统**的 agent。用枚举一个个补，
既追不上换血，也撑爆"小而专"的产品边界。

### 2.3 每个 agent 是一座"岛"

hook 配置散落在各 agent 自己的家里：`~/.claude`、`~/.codex`、`~/.config/opencode`、`~/.pi`，
事件词表也各不相同。要支持任意 agent 的 hook，就得让**岛主（用户）在配置里声明这座岛的 hook 入口
和事件词表**——只有他知道。

## 三、非目标（Non-goals）

- **不**做完整插件平台：没有 manifest schema、activation events、暴露给插件的 API、版本协商、市场。
  那些是为第三方生态服务的；termio 是单一用途工具，不是平台。除非明确要做 marketplace，否则属于
  "宏大架构"陷阱。
- **不**内嵌 Lua / JS 运行时（理由见 §六）。
- **不**在 termio 进程内执行 agent 提供的脚本（保留"termio 从不跑 agent 代码"这一安全/简单性属性）。
- **不**改 wire format、不改 `HookListener` 的 socket 传输层。

## 四、设计

### 4.1 数据模型：`AgentDefinition`

内置与用户 agent 流经同一个值类型：

```swift
struct AgentDefinition: Identifiable, Hashable, Codable {
    var id: String                    // 稳定 slug，与今天的 rawValue 对齐："claudeCode" / "codex" / "aider" …
    var name: String                  // "Aider"
    var command: String?              // "aider"；nil = 纯 shell（即今天的 .terminal）
    var permissionBypassFlag: String? // 可选；启用 bypass 时追加
    var icon: AgentIcon               // 内置用 .brand 矢量；用户 agent 用 .systemSymbol 或 .brandImage(path)
    var hooks: HookSpec?              // 见 §4.4；nil = 无 hook，退化到铃/OSC
}
```

- **内置**：代码里 `static let builtin: [AgentDefinition]`，保留 `BrandIcons.swift` 的矢量品牌图标。
- **用户**：从磁盘加载、追加合并。
- 全 app **一律按 `id: String` 寻址**——设置层三个字典本就如此，零改动。

### 4.2 打包：一 agent 一目录

```
~/.termio/agents/
  aider/
    agent.json          # 声明式定义（"主题"那一半）
  myagent/
    agent.json          # 含 hooks 块
    plugin.js           # 仅当是 tier-2 插件型 agent 时才有
```

- 卸载 = 删目录；分享 = 打包目录。与 `state.json` 同一套目录解析（`TermioStore.swift:979` 的
  Application Support / `~/.termio` fallback）。
- 这是"像 VSCode"里**唯一该取的部分**：文件夹模型。manifest / API / 市场一概不取。
- VSCode 的教训其实反向：**theme 是纯声明数据、不带代码**。agent 定义就是 theme 形状的——是数据，
  不是计算。所以常见情形保持声明式，只为罕见情形留代码逃生舱。

`agent.json` 示例（tier-1 声明式）：

```json
{
  "id": "aider",
  "name": "Aider",
  "command": "aider",
  "icon": { "symbol": "wand.and.stars", "tint": "#14B8A6" },
  "hooks": {
    "kind": "jsonHookFile",
    "path": "~/.aider/hooks.json",
    "events": [
      { "event": "PreToolUse",        "state": "working",   "matcher": "*" },
      { "event": "PermissionRequest", "state": "attention" },
      { "event": "Stop",              "state": "done" }
    ]
  }
}
```

### 4.3 图标

用户 agent 只暴露两种用户*能*提供的模式：**SF Symbol 名 + tint 十六进制**，或 **指向 PNG/SVG
的路径**（复用 `AgentIcon.systemSymbol` / `.brandImage`）。矢量品牌 logo 仍是内置 agent 的代码特权。
保证配置易写，同时内置依旧一等公民。

### 4.4 Hook：三档现实 + shell 逃生舱

现有 hook 层（`HookListener.swift`）的精髓：**wire format 统一、termio 不做按-agent 解析**，
所有按-agent 知识都被隔离在 *installer* 里，而 installer 只有两种形状：

- `JSONHookFile`（`HookListener.swift:238`）—— Claude 形状 JSON 文件；全部可变性 = `url` + `events`。
- `PluginFile`（`HookListener.swift:382`）—— 往 agent 插件目录丢一个 JS；可变性 = `url` + `contents`。

agent 按 hook 能力分三档，这是"任意岛都能配 hook"无法一键化的根因：

| 档 | 机制 | 例 | 配置能否描述 |
|---|---|---|---|
| **1. JSON hook 文件** | Claude 形状 `{hooks:{Event:[…]}}` | Claude, Codex | **能——纯数据**（path + event→state） |
| **2. 插件丢入** | 用该 agent 自己的插件 API 写 JS | OpenCode, Pi | 部分——需 agent 专属 JS，非数据 |
| **3. 无 hook** | 无 | Aider, Goose, Cline, Crush, 长尾 | **不能**——退化到铃/OSC |

设计动作：

- **Tier-1 配置化（最高杠杆）**：`HookSpec.jsonHookFile(path, events)` 直接构造现有
  `JSONHookFile` struct——**零新 installer 代码**，把静态工厂换成"从配置喂"。
  `AgentStatusHooks.installers`（`HookListener.swift:206`）变成 内置 + 每个声明
  `kind:jsonHookFile` 的配置 agent。
- **Shell 逃生舱**：hook 命令本就是 shell 字符串（`reportCommand`，`HookListener.swift:219`）。
  允许某 event 用自带 shell 片段替代固定的 `printf|nc`，即可在 agent 进程里做分支（按 exit code /
  tool 名 / payload 判 state）——这正是大家想用 Lua 拿到的能力，而 shell 已经在那、零新依赖。

  ```json
  { "event": "PostToolUse",
    "shell": "test \"$EXIT\" = 0 && S=working || S=attention; printf '{\"termio_session\":\"%s\",\"state\":\"%s\"}' \"$TERMIO_SESSION\" \"$S\" | nc -U $TERMIO_SOCK" }
  ```

- **Tier-2 插件**：`PluginFile` 已是通用（`url`+`contents`）。可让配置指 `kind:pluginFile`
  + `path` + 目录内 `plugin.js`，termio 仅负责带 marker 丢入/安全卸载。**但**几乎没人会照某 agent
  的私有 API 手写插件——**暂缓，不投机**。
- **Tier-3 无 hook**：无可安装，且没关系——已优雅退化。唯一要做的是**诚实**：设置里按 agent 标注
  "实时状态" vs "仅完成（铃）"，免得用户困惑 Aider 为何永不转圈。

### 4.5 持久化与迁移

- `Session.agent: AgentPreset` → `Session.agentID: String`。**只要内置 id 与今日 rawValue 一致**
  （`claudeCode`/`codex`/`opencode`/`pi`/`terminal`），现存 `state.json` 原样反序列化——会话树**零迁移**。
- 设置三字典本就按字符串寻址，零改动。
- **未知 id**（用户删了某 agent 但会话仍引用）：退化为纯 terminal + 用原始 id 作标题，**不丢会话、
  不 trap**——符合 CLAUDE.md "surface failures rather than crashing"。
- 加载时机：启动时扫 `~/.termio/agents/`；可选 file-watch 热加载（nice-to-have，v1 不强求）。

## 五、被否决的方案

### 5.1 内嵌 Lua 运行时 —— 否

决定性事实：**hook 不跑在 termio 里，跑在 agent 进程里**。termio 把命令装进 agent 的配置，由
*agent* 执行，termio 只从 socket 读 JSON。那 Lua 跑哪？

- **agent 进程内** → hook 变 `lua x.lua | nc`，但 macOS 不带 Lua，得 bundle 一个 `lua` 二进制；
  而 shell 已能干这活、零依赖。Lua 只多给"更好的解析语言"。
- **termio 进程内** → 收原始 payload 后跑 per-agent Lua 归一化。这是**唯一**有意思的变体，但要内嵌
  Lua VM、设计暴露给 Lua 的 API、做沙箱，并**放弃"termio 从不跑 agent 代码"**。为罕见情形背永久的
  大面积 surface area，违背"小而专"。

Lua 相对 shell 只多"复杂 payload 解析更顺手"，这场景稀少到不值一个内嵌解释器。**用 shell 逃生舱替代。**

### 5.2 完整插件平台（manifest/API/marketplace）—— 否（除非要做生态）

那套基础设施是为第三方生态存在的。没有 marketplace 意图时，"文件夹 + 声明式 `agent.json` +
shell 逃生舱"以 5% 成本拿到 95% 收益。

### 5.3 Smart-receive（termio 跑归一化脚本）—— 否

今天是 smart-install / dumb-receive（装 N 条 per-event 入口，各自硬编码 state）。插件式替代是
dumb-install / smart-receive（装一条转发原始 payload，termio 跑 per-agent 脚本归一）。它能把
per-agent 逻辑集中到一个文件（很"插件"），**但**正是要在 termio 内跑 agent 代码的那个变体，且只对
"单一 catch-all hook + 全 payload"的 agent 成立（Claude 仍需 per-event matcher）。集中化的收益
不抵丢失隔离的代价。

## 六、风险

- **声明了事件 ≠ agent 真会触发**。代码自己都不确定 Codex 是否真发 hook（`HookListener.swift:150-167`
  的 `TERMIO_HOOK_TRACE` 诊断就在查"Codex TUI 到底发不发、`termio_session` 是否活着进到 hook"）。
  → 把 trace 作为"测试你 agent 的 hook"的文档化步骤，别假设声明即生效。
- **shell 逃生舱 = 任意代码执行**。但用户在自己配置里写自己的 shell，信任级别等同其 shell rc；且仍跑在
  agent 进程，不在 termio。可接受。
- **路径/解析健壮性**：拒绝改写无法解析的文件（现有 `JSONHookFile` 已如此）；`agent.json` 解析失败应
  跳过该 agent 并记日志，不影响其余。

## 七、实现切分

- **Cut 1（小、价值高）**：`AgentPreset` → `AgentDefinition` + 内置静态数组；`Session` 改
  `agentID: String`；扫 `~/.termio/agents/*/agent.json` 合并。**仅此**就让用户用 SF Symbol 图标
  自助加 Aider/Goose/Cline/Amp/Gemini。无需新 UI（设置页本就遍历列表）。
- **Cut 2（hook 配置化）**：`HookSpec.jsonHookFile` 从配置构造现有 `JSONHookFile`；加 `shell`
  per-event 覆盖字段。让任意 Claude/Codex 形状的岛**零 Swift 改动**可加。
- **Cut 3（打磨）**：设置里 per-agent "实时状态 / 仅完成" 徽标；"编辑 agents 目录"按钮；可选 file-watch；
  可选补 2–3 个带真品牌图标的内置（Gemini/Antigravity、Aider、Cline）。

## 八、待定问题

1. Gemini 正处 CLI→Antigravity 过渡，要不要现在就内置，还是等 Antigravity 稳定？
2. 一目录一 agent 是否同时取代扁平设置，还是 `agent.json` 仅承载定义、用户偏好仍留 UserDefaults？
3. tier-3 agent 的"死感"——除诚实标注外，是否值得做一个轻量推断（如基于 PTY 输出节流的"疑似在忙"）？
4. shell 逃生舱是否需要一个 `$TERMIO_SOCK` / `$TERMIO_SESSION` 的稳定契约文档？
