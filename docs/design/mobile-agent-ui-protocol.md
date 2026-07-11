---
title: 移动端 Agent UI 协议 —— PTY 之上的旁路结构面（ACP 词汇）
status: draft
type: design
created: 2026-07-11
updated: 2026-07-11
related:
  - remote-access-relay-strategy.md
  - session-share.md
  - session-daemon-architecture.md
  - ios-terminal-input.md
---

# 设计：移动端 Agent UI 协议 —— PTY 之上的旁路结构面

> 不改变 agent 的任何运行行为，基于 agent 自己落盘的 JSON（transcript）和 hooks 做一条旁路信号，
> 归一化成 ACP 词汇的事件流供移动端（iOS 现在、Android 将来）渲染原生 chat UI；
> PTY session 是唯一的 session 原语，Mac 是 PTY host，所有 UI 都只是应用层。

## 1. 背景与问题

手机上渲染 raw terminal 不是 agent 交互的好界面：字太小、触控没有原生审批、
且 iOS 端的 VT 网格模拟带来了一连串只因"手机在模拟终端"才存在的工程成本
（libghostty 死锁、IO-thread panic、resize reflow、PROMPT_SP 等，见相关 docs）。

2026-07-10/11 调研了四个同类产品（详见 §11 Prior Art），结论一致：
**没有人把 TUI 字节流转译成 GUI —— 都是绕过终端，去上游拿结构化数据**
（JSONL transcript / stream-json / SDK），在 host 侧归一化成统一 schema，客户端原生渲染。

termio 与它们的差别：termio 是终端产品，agent 的 TUI 本身就是产品承诺，
所以不能走 headless/适配器路线 —— 结构面必须是 PTY 之上的**旁路**（sidecar），
而不是替代运行时。

## 2. 核心原则（已定，不再重开）

1. **PTY session 是唯一的 session 原语。** Mac = headless PTY host；
   macOS 窗口、iOS、Android、`termio sessions` CLI 全部是对等的应用层客户端，
   谁都不拥有 session。
2. **零行为改变。** agent 原样跑在 PTY 里（真 TUI，非 headless、非 ACP 适配器、非 SDK 包装）。
   结构面从 transcript + hooks **推导**，agent 感知不到自己被投影。
3. **iOS/macOS 复用同一个 live session。** 两端是同一 PTY 的两种镜头，随时互相接管。
4. **手机可以创建 session，但只是 relay。** 真正的 spawn（worktree、PTY、agent 进程）
   全部发生在 Mac；创建者无特权。
5. **协议站在 AG-UI 的位置，说 ACP 的语言。** 栈位置 = frontend↔agent 的 UI 事件缝
   （AG-UI 的角色）；载荷词汇 = ACP 的 coding-agent 语义（diff、tool kind、permission option）。

## 3. 分层架构

```
L0  PTY Host（Mac，唯一的 session 所有者）
    PTYProcess(forkpty) · ring buffer/replay · transcript 发现 · hooks · 状态机
    ← session 在这里活着，不依赖任何 viewer

L1  三个 host 派生的 plane（同一 PTY session 的投影）
    · 字节面   raw PTY 流（terminal 渲染；随进程死）
    · 结构面   ACP session/update（transcript+hooks 归一化；随磁盘活）★本设计新增
    · 控制面   prompt/answer→键击注入 · roster · 文件面（已存在）

L2  应用层（全部对等，均为 L1 的订阅者）
    · macOS 窗口       进程内订阅（1 号客户端）
    · iOS app          companion WebSocket
    · Android（将来）   companion WebSocket + 官方 ACP Kotlin SDK
    · termio sessions CLI   unix socket（headless 可驱动的既有证明）
```

纪律：**新代码不允许绕过 L1 直接摸 PTY。** 这条边界同时是将来（如果需要）
daemon 化的现成切割线 —— 但 daemon 化本设计**不做**（见 §10 非目标）。

## 4. 两层 session 模型

| 层 | 内容 | 生命周期 |
|---|---|---|
| Session 记录（持久） | UUID、agent 类型、worktree、resumeID、transcript 路径 | 跨 app 重启存活 |
| 活进程（短暂） | PTY + agent 进程 | app 退出即死 |

关键不对称：**字节面随进程死**（scrollback 是进程内存），
**结构面随磁盘活**（transcript 落盘）。推论：

- 死（dormant）session 用 terminal 视图打开是空白；用 chat lens 打开是**完整历史 + Resume**。
  这是 chat lens 在移动端最强的单条论据。
- **Resume 是协议一等操作**：用户在 dormant session 里输入 → host 以 resumeID
  起 `claude --resume` → session 转活，三个 plane 点亮。
- roster 状态需增加正交维度：`live | dormant`（现有 idle/working/done/needsAttention
  都是 live 内的子状态）。

## 5. 协议选型：为什么是 ACP 词汇、为什么不是 ACP 运行时、为什么不是 AG-UI

**采纳：ACP（agentclientprotocol.com）v1 的 session 层词汇**，
理由：coding-agent 语义一等公民（`session/update` 的 11 种变体、
ToolCall 的 `kind/status/content(diff|terminal)/locations`、
`session/request_permission` 的 option kinds、`usage_update`）；
`session/load` = 全量历史回放，天然匹配 attach 时的 catch-up；
显式允许自定义 transport、`_` 前缀扩展方法、全类型 `_meta`；
**Android 有官方 Kotlin SDK**；schema 带 `x-deserialize-default-on-error` 类
向前兼容技巧。锁定 protocolVersion 1（v2 unstable 在向编辑器方向漂移：document sync、NES）。

**不采纳：ACP 作为运行时**（即跑 claude-code-acp 之类适配器）。
对 ACP 的实质批评全部指向这个用法：适配器是二等公民且可被 vendor 掐掉
（Claude 的 ACP 支持是 Zed 维护的 SDK 包装而非官方；Amp 把 ACP 锁在付费额度后）；
最小公分母抽象丢 agent 特性；stdio/1:1/本地假设没有重连与多客户端。
herdr（同架构竞品）与 vibe-kanban（编排器）都因此绕开了 ACP。
termio 只借它的 schema：最坏情况 ACP 标准死掉，我们手里仍是一套形状良好的私有
schema（vibe-kanban 的 NormalizedEntry 就是自己发明了一遍）；
若它活下来，原生 ACP agent（Gemini CLI、Goose）可免费直通。

**不采纳：AG-UI 作为载荷 schema。** 它是通用 chat+state 协议，
无 diff/file/terminal/permission 原语，coding 语义全要自造。
借鉴其两个点：interrupt 的 `expiresAt`、恢复前先发快照的规则。

## 6. Wire 映射

载体：现有 companion WebSocket（tunnel + 配对 token 不变），
在 `CompanionControl` 上新增文本帧消息；ACP 载荷为 JSON-RPC 形状的 payload。

**手机 → Mac（标准 ACP client→agent 方法，Mac 扮演 "agent" 端）**

| 方法 | termio 语义 |
|---|---|
| `session/list` | roster 的 ACP 视图（live + dormant，含 updatedAt） |
| `session/new` | relay 创建：host 建 worktree → spawn PTY → 记录 → roster 广播 |
| `session/load` | attach + 全量历史回放（数据源 transcript，**对 dormant 同样有效**） |
| `session/prompt` | composer 文本 → bracketed-paste + ⏎ 键击注入 |
| `session/cancel` | 注入中断（Esc/ctrl-c，按 agent 分档定义） |
| `session/resume`（v1 已有） | dormant → live：以 resumeID 重启 agent |

**Mac → 手机（`session/update` 通知 + permission 请求）**

使用的 update 变体：`user_message_chunk`、`agent_message_chunk`、`agent_thought_chunk`、
`tool_call`、`tool_call_update`（含 diff content、locations）、`plan`、
`available_commands_update`、`current_mode_update`、`session_info_update`、`usage_update`。
`session/request_permission`：携带被 gate 的 toolCall + options（kind:
allow_once/allow_always/reject_once/reject_always）。

**`_termio/*` 扩展（ACP 之外、termio envelope 所有）**

| 扩展 | 内容 |
|---|---|
| `_termio/pty` | 字节面（现有二进制帧,terminal fallback 视图） |
| `_termio/roster` | 现有 roster 广播（项目树、live/dormant、状态点） |
| `_termio/files` | 现有文件面（listFiles/readFile/writeFile/upload/search） |
| `_termio/presence` | 轻量在场通知（"📱 已连接" / Mac 前台查看中） |
| `_termio/capabilities` | 每 session 的细粒度能力 flags（§7），客户端据此定默认视图 |

## 7. Per-agent adapter（单一方案，无分档）

方案只有一个：**每个 session = PTY（必有）+ 至多一个 AgentAdapter（可无）**。
adapter 是唯一抽象,所有 agent 走同一接口、同一 host 管线、同一协议 —— 不存在
"模式"或"档位"这个设计维度:

```swift
protocol AgentAdapter {
    var agentID: String { get }
    // 信号源皆为可选实现;实现了什么,能力就有什么
    func transcriptURL(for session: Session) -> URL?          // 内容信号
    func events(tailing url: URL) -> AsyncStream<SessionUpdate>
    func handleHookEvent(_ event: HookEvent) -> [SessionUpdate]?  // 生命周期/审批信号
    func resumeArgv(for session: Session) -> [String]?        // resume 能力
}
```

- **能力是细粒度 flags,不是档位枚举**（LSP 的教训:capability 协商必须按特性,
  不能按等级）:`streamsTranscript`、`emitsApprovals`、`supportsResume`、`reportsUsage`…
  由 adapter 实际接了哪些信号源**推导**,不手工声明,经 `_termio/capabilities` 下发,
  客户端按 flag 决定点亮哪些 UI。
- **没有 adapter 不是一个"档"**,只是 adapter 缺席:字节面对每个 session 无条件存在,
  裸 shell / 未知 agent 的手机视图自然就是 terminal。降级是**涌现性质**,不是设计分支。
- adapter 单调生长:新 agent 第零天零代码即可用(纯字节面);之后接 transcript、
  接 hooks,每接一个信号源多亮一批 flag —— 管线与客户端零改动。
- 现状对应:Claude adapter 信号最全(hooks+transcript 均已有);Codex/OpenCode
  有 transcript 发现;normalizer 从 `SessionTraceRenderer` 的解析循环重构而来
  (一次性 HTML → 增量 tail → update 事件),提升到 host 层(TermioStore),
  macOS UI 是它的 1 号进程内订阅者。

## 8. 多客户端 envelope 三规则（ACP 缺失、termio 补齐）

ACP 假设 1:1 本地连接；共享 session 需要 envelope 层规定：

1. **Permission 广播与先答者赢。** 请求广播给所有客户端（Mac TUI 本身也在显示同一菜单）；
   任一端回答后，host 从 hook/transcript 观察到放行，向其余客户端发 `tool_call_update`
   使过期卡片消失。手机答 → 注入 "1" → Mac TUI 菜单当场收起；Mac 在 TUI 里答 →
   手机卡片消失。最终都是同一个 TUI 菜单收到一次按键，不可能答出两个结果。
2. **每客户端独立 attach/replay 游标。** 断线重连各自做 `session/load` 式回放再接直播，
   互不影响（PTY 层 ring-buffer + catch-up 的同构模式）。
3. **Presence（可选）。** `_termio/presence` 通知，不影响正确性，影响接管体验。

已解决、不需新机制：PTY 尺寸归属（tmux 式最后活跃客户端持有 + jiggle 回收）。
chat lens 不依赖网格尺寸，进一步缩小了尺寸竞争面。

输入竞态唯一残留：人在 TUI 打半句话时手机注入 prompt 会交错。
bracketed-paste 原子注入已把窗口压到极小；性质同 tmux 双人，不做协议级锁。

## 9. 实施阶段（每步独立可用）

1. **Normalizer + wire 新 case。** TraceRenderer 解析循环 → 增量、可订阅的 AgentAdapter 管线；
   `CompanionControl` 增加 session/update 等 case（编解码各约 20 行）；Claude adapter
   打通全部信号源（transcript+hooks），只发不收。
2. **只读 chat 视图（iOS）。** 消息/tool 卡/diff 渲染（消息模型参考 sarea 的
   `ChatMessageContent` 判别联合 + tool-call 连续折叠 + 手势跟随）；composer 沿用；
   terminal 一键切换。dormant session 历史即刻可看 —— 已强于现 trace HTML 一代。
   （2026-07-03 备份 `~/termio-chatview-backup-20260703/` 可作脚手架。）
3. **审批卡。** hook PreToolUse 驱动 + `answer` 键击注入 + 三规则广播。
4. **Resume 一等公民 + Codex adapter（transcript 信号）+ `_termio/capabilities`。**

不动的东西：PTY 层、libghostty 渲染、tunnel/配对、agent 本身、Mac 终端 UI。

## 10. 非目标与诚实边界

- **不做 daemon。** 现架构（host 住 app 进程）满足全部需求；唯一需要 daemon 的场景是
  "Mac 上 app 已退出、手机还想连"。等它成为真实诉求再抽,L1 边界即切割线。
  另见 session-daemon-architecture.md。
- **不跑 ACP/headless 运行时,不做 relay server。**（BYO-tunnel 策略见
  remote-access-relay-strategy.md。）
- **延迟不对称**：结构面隔 transcript 落盘,滞后数百 ms～1s;不承诺与字节面逐帧同步。
- **结构面覆盖不到 TUI 全部**：TUI 内的菜单滚动、/help、ctrl-r 不产生事件 ——
  chat lens 呈现对话而非屏幕;要屏幕就切字节面。
- **TUI permission 菜单 → PermissionOption 的映射是启发式**（hook payload + 菜单解析）,
  偶尔退化为通用 "Option 1/2/3" 标签,可接受。
- **transcript 格式是各 vendor 的非契约实现细节**,可能随版本变化;
  adapter 解析必须宽容（沿用 TraceRenderer 的 lenient 风格）,破坏时降级不崩溃。
  可借鉴 herdr 的热更新 manifest 思路,把解析规则做成可下发数据。

## 11. Prior Art（2026-07-10/11 调研）

| 产品 | 架构 | 对 termio 的启示 |
|---|---|---|
| Happy (slopus/happy) | CLI 包装 + E2EE relay + RN app;tail JSONL / 包 SDK | mapper 放 host、app 保持哑;permission 是 tool call 的元数据 |
| vibe-kanban (BloopAI) | 编排器;各家原生 stream-json → 自有 NormalizedEntry | 跨 agent 统一 schema 的词汇;resume token 模型;拒绝 ACP 的理由 |
| sarea（本机 repo） | 原生 SwiftUI chat-first;stream-json headless | iOS 视图层蓝本:ChatMessageContent、内联审批卡、tool 折叠 |
| herdr.dev | **同架构竞品**:PTY host + 真 TUI + 读屏 manifest + hooks | 验证 PTY 路线;其空档（无移动端/结构面）= termio 差异化;热更新 manifest 可偷 |

SDK 资产：iOS 参考 wiedymi/swift-acp（MIT,iOS 15+,ACPModel 与 transport 分离）——
建议 **vendor 其 ACPModel 类型进 TermioShared** 而非引依赖（测试薄、单次发布;
另避 Bundle.module 前科）;Android 用官方 agentclientprotocol/kotlin-sdk。
ACP schema 快照:调研时存于 /tmp/acp-schema-v1.json（正式来源:
agentclientprotocol/agent-client-protocol 的 schema/v1/schema.json）。
