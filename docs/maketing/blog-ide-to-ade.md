---
title: 从 IDE 到 ADE：开发环境六十年，以及它为什么正在终结
status: draft
type: marketing
created: 2026-07-11
updated: 2026-07-11
---

# 从 IDE 到 ADE：开发环境六十年，以及它为什么正在终结

> Blog 草稿：用六十年 IDE 演化史推出一个底层规律——每一代开发环境集成的都是当时的瓶颈，价值永远流向拥有瓶颈的那一层。今天的瓶颈不再是"写代码"，是"指挥写代码的 agent"。技术与商业双视角论证：Agentic Development Environment 是这一代的入口级机会。

2026 年 7 月 8 日，InfoWorld 刊出一篇文章，标题毫不客气：**《The IDE is dead, long live the ADE》**。作者 Nick Hodges 的论断是：统治了软件开发四十年的集成开发环境，在 agentic coding 面前正在变成一个"越用越少的工具"。

这听起来像标题党。但把 IDE 六十年的历史摊开看，你会发现这不是一次意外，而是同一条规律的第六次重演：

**每一代开发环境，集成的都是那个时代最大的瓶颈；而每一次瓶颈迁移，都重新分配了一次整个工具产业的价值。**

先讲历史，再讲为什么这一次的重新分配，比前五次加起来都大。

## 第一幕：六十年，五次瓶颈迁移

### 1950s–60s：代码离机器很远

在"开发环境"这个词存在之前，写程序是物理劳动：编码纸上手写，穿孔员打卡，交机房，等几个小时甚至隔天，拿回一叠打印纸——上面可能只有一行编译错误。

![一张 FORTRAN 穿孔卡](https://upload.wikimedia.org/wikipedia/commons/5/58/FortranCardPROJ039.agr.jpg)
*一张 FORTRAN 程序穿孔卡。一行代码，一张卡。（Arnold Reinhold, Wikimedia Commons, CC BY-SA）*

瓶颈：**反馈周期**。写下代码和看到结果之间，隔着一个官僚系统。

### 1964：Dartmouth BASIC，第一次"坐在终端前编程"

达特茅斯学院的分时系统和 BASIC 语言，第一次把语言、编辑器、执行环境长在同一个系统里。程序员第一次坐在"终端"前写代码、跑代码——尽管那台终端是哐哐作响的电传打字机。反馈周期从隔天变成几秒。

![ASR-33 电传打字机](https://upload.wikimedia.org/wikipedia/commons/d/df/ASR-33_at_CHM.agr.jpg)
*Teletype ASR-33，分时时代的标准"显示器"。（Computer History Museum 藏品，Arnold Reinhold 摄, CC BY-SA）*

### 1975：Maestro I，第一个商业 IDE

第一个作为商品出售的 IDE 不是来自硅谷，而是慕尼黑。Softlab 的 **Maestro I** 给小型机配上专用编程工作站，全球供 22,000 名程序员使用。"为编程单独造一台机器"在当时是个激进的想法——也是第一次有人证明：**开发环境本身是一门生意。**

![Maestro I 专用键盘](https://upload.wikimedia.org/wikipedia/commons/c/cc/Maestro-I-Keyboard.JPG)
*Maestro I 的专用键盘。（Wikimedia Commons, CC BY-SA 4.0）*

### 1983：Turbo Pascal，$49.95 的革命

Borland 把编辑器和编译器塞进同一个程序、塞进个人电脑，编译以秒计，卖 $49.95——同类工具当时卖几百上千美元。"改一行，按 F9，两秒看到结果"重新定义了编程的节奏。瓶颈从"等机器"变成"编辑-编译-运行的切换成本"，Borland 消灭了它，也吃掉了那个年代的开发工具市场。

![Turbo Pascal 6 的界面](https://upload.wikimedia.org/wikipedia/commons/8/84/Turbopascal_6.png)
*Turbo Pascal 的字符界面 IDE：编辑、编译、运行、调试，第一次全在一块屏幕里。（Wikimedia Commons）*

### 1991–2001：企业级 IDE 的黄金年代

这十年，IDE 完成了从"工具"到"产业"的跨越，四个名字各占一块里程碑。

**1991，Visual Basic**：把 GUI 构建器和代码写作缝在一起——拖控件、双击、写事件处理，一代企业软件由此诞生。"可视化编程"第一次让百万级人群跨过了编程的门槛。

![Visual Basic 6.0](https://upload.wikimedia.org/wikipedia/en/0/0e/Visual_Basic_6.0_on_Windows_XP.png)
*Visual Basic 6.0：左边控件箱，中间画窗体，双击写事件——无数企业内部系统的出生地。（Wikipedia, 合理使用）*

**1997，Visual Studio**：微软把所有语言和工具收进一个屋檐，此后统治 Windows 开发二十年。"开发环境"从单个产品变成了平台战略。

![Visual Studio .NET](https://upload.wikimedia.org/wikipedia/en/f/f2/Visual_Studio_.NET_2002_EN.png)
*Visual Studio .NET（2002）——初代 VS 97 已难觅可引用的截图，这是它血统最近的后代：解决方案树 + 属性面板 + 设计器的三件套定型于此。（Wikipedia, 合理使用）*

**2001，Eclipse**：IBM 出资、随后开源，第一个正面击败商业产品的开源 IDE，插件体系成为后来所有"平台型 IDE"的模板。

![Eclipse 的 Java 开发界面](https://upload.wikimedia.org/wikipedia/commons/e/e3/Eclipse_Java_Development_GTK.png)
*Eclipse 的经典解剖结构：项目树、编辑器、Outline、Problems 面板。（Wikimedia Commons, EPL）*

**2001，IntelliJ IDEA**：JetBrains 把"把代码当语法树而不是文本"做成信仰——重构、语义补全、意图检测，语言级智能的金标准从此姓 J。

![IntelliJ IDEA](https://upload.wikimedia.org/wikipedia/commons/8/89/IntelliJ_IDEA_14.1.3.png)
*IntelliJ IDEA：深度语义理解的代表作，也是后来 Android Studio 等一整族 IDE 的地基。（Wikimedia Commons）*

这十年的共同瓶颈：**人对大型代码库的认知负担**——当项目从一个文件涨到一万个文件，IDE 替你记住全部结构。

### 2015：VS Code 与 LSP，编辑器成为平台

微软发布 VS Code，并定义了 **Language Server Protocol**：语言智能从 IDE 本体剥离成独立进程和开放协议，N 种编辑器 × M 种语言的适配矩阵坍缩成 N + M。IDE 从巨型单体变成轻内核 + 生态，VS Code 免费，却借此吃下了半个世界的开发者入口。

![早期版本的 VS Code](https://upload.wikimedia.org/wikipedia/commons/8/80/Visual_Studio_Code_0.10.1_on_Windows_7%2C_with_search.png)
*2015 年的 VS Code 0.10.1——后来统治十年的编辑器，最初长这样。（Wikimedia Commons, MIT）*

记住 VS Code 这一课，后面要考：**编辑器本体免费化了，但拥有入口的公司（微软/GitHub）拿走了整个时代的分发权。**

## 第二幕：AI 住进 IDE（2021–2024），以及为什么这还不是终局

2021 年 GitHub Copilot 把补全从语法级推到意图级。2023 年 Cursor 干脆 fork 了 VS Code，把对话和 agent 塞进编辑器。资本市场的反应是史诗级的：

![Cursor](https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/og/opengraph-default.png)
*Cursor：AI-IDE 时代最大的赢家。（图：Cursor 官方）*

- Cursor 的 ARR 从 2025 年 1 月的 **$1 亿**涨到 2026 年 6 月的 **$40 亿**年化——18 个月 40 倍，B2B 软件史上最快之一；
- 2025 年 11 月以 **$293 亿**估值完成 $23 亿 Series D；
- 2026 年 6 月，SpaceX 宣布以 **$600 亿**全股票收购 Cursor 母公司 Anysphere。

一个 fork 的编辑器，三年，$600 亿。这就是"开发环境入口"四个字的定价。

但同一时期还有一个反面样本：**Windsurf**。2025 年年中 OpenAI 的 $30 亿收购流产，随后核心团队被 Google 以授权交易的方式带走，2025 年 12 月残余部分以约 **$2.5 亿**卖给 Cognition。六个月，估值蒸发 90% 以上。

同一个品类里，为什么一个 $600 亿、一个 $2.5 亿？因为断层线已经出现了，而两家公司站在了断层线的两侧。断层线就是下一节。

## 第三幕：Agent 离开编辑器（2025–2026）

2025 年 2 月，Anthropic 发布 Claude Code——不是插件，不是编辑器，是一个跑在**终端**里的 agent。然后发生了软件工具史上最陡的一条增长曲线：

![Claude Code](https://cdn.sanity.io/images/4zrzovbb/claude-com/6c36adaaf60ecdde313a93ad255eef573ea4de97-1200x630.jpg?w=1200&h=630&fit=crop)
*Claude Code：跑在终端里，而不是编辑器里。（图：Anthropic 官方）*

- 年化收入：2025 年 9 月 $5 亿 → 11 月 $10 亿 → 2026 年 2 月 $25 亿 → **2026 年 5 月约 $80 亿**；
- 平均每个开发者**每周使用 20 小时**（Anthropic CEO Dario Amodei，2026 Q1 财报口径）；
- SemiAnalysis 估计公开 commit 中由 Claude Code 生成的比例：2026 年 2 月 4% → Q1 末 10% → **年底预计超过 20%**；
- Pragmatic Engineer 2026 年 2 月对 15,000 名开发者的调查：73% 的团队每天使用 AI 编程工具（2025 年为 41%），Claude Code 以 46% 当选"最受喜爱"。

关键不是数字，是**形态**：agent 不再是"提示-响应"的问答机，而是能连续运行几十分钟、自己读代码、跑测试、改错误的工作单元。OpenAI 的 Codex CLI、Google 的 Gemini CLI 跟进——**最强的 agent 全部生在终端里，没有一个生在 IDE 里。**

这不是巧合，是技术底层决定的（第五节细讲）。而它直接导致了 IDE 核心假设的全面崩塌：

| IDE 的假设 | Agentic 时代的现实 |
|---|---|
| 一个人，一个光标 | 一个人，N 个并行 agent |
| 核心动作是打字 | 核心动作是派活、审查、仲裁 |
| 一个工作区，一个分支 | 每个 agent 一个 worktree、一个分支 |
| 界面为"读写代码"优化 | 界面为"监督进程"优化：谁在跑？谁卡住？谁在等我拍板？ |

## 第四幕：卡位战已经开始——ADE 竞品图鉴

"人类指挥 agent 舰队"需要一个新环境。过去十二个月，几乎每一类玩家都推出了自己的 ADE 答卷。

**Warp → Oz**（2026 年 2 月）：终端厂商向上做编排，本地 agent + 云端 Docker agent 双模式，入选 TIME 2025 年度最佳发明。终端公司做 ADE，是"从下往上"的路线。

![Warp](https://www.warp.dev/og/default.png)
*Warp：从"更好的终端"转身为 Agentic Development Environment。（图：Warp 官方）*

**JetBrains → Air**：IDE 巨头的自我革命，官方定义原文就是 "agentic development environment"——开发者把任务委托给并行 agent，用 IDE 级的代码审查界面验收。当卖了二十五年 IDE 的公司开始给新品类起名，这个品类就成立了。

**GitKraken → Kepler**：Git 工具厂商从"分支管理"切入多 agent 编排。CEO Matt Johnston 的一句话可以当作本文的题眼：

> "The IDE was built for the age of one human typing. The ADE is built for the age of humans orchestrating fleets of agents."

![GitKraken Kepler](https://www.gitkraken.com/wp-content/uploads/2026/06/ADE_product_OG-1024x538.png)
*GitKraken Kepler：官方 OG 图直接印上了 "ADE" 三个字母。（图：GitKraken 官方）*

**Conductor**（Melty Labs）：Mac 原生 app，每个 agent 一个独立 git worktree 并行跑 Claude Code/Codex。产品免费、自带订阅（BYO subscription）——典型的"先抢占工作流，暂缓变现"打法。

![Conductor](https://www.conductor.build/opengraph-image?f984893ec97162f4)
*Conductor：Mac 上并行跑一队 coding agent。（图：Conductor 官方）*

**herdr**：开源的 agent-aware 终端复用器（"tmux for agents"），1.5 万+ GitHub star，持久工作区 + agent 状态检测。开源社区验证了同一个需求，但只覆盖了终端侧，没有移动端和结构化监督面。

![herdr](https://opengraph.githubassets.com/1/ogulcancelik/herdr)
*herdr：one terminal for the whole herd。（图：GitHub）*

**vibe-kanban**（Bloop）：给 agent 的看板——卡片拖到 In Progress，agent 领任务开分支。Apache 协议、社区庞大，然后 **2026 年 4 月宣布关停**，代码交给社区维护。

![vibe-kanban](https://vibekanban.com/images/cta-product-desktop.webp)
*vibe-kanban：品类里第一个阵亡者，教训比成功更值钱。（图：vibe-kanban 官方）*

vibe-kanban 之死值得单独一段：它证明了**需求真实存在**（大量用户），也证明了**两件事不成立**——纯"看板"抽象太薄（agent 的真实界面是终端和 diff，不是卡片），以及没有商业引擎的免费编排工具撑不起持续投入。这两条教训直接框定了这个品类的正确解法：**产品必须拥有运行时（终端本体），而不只是调度视图；必须从第一天就有收入模型。**

## 第五幕：底层分析 I——技术视角

把六十年压缩成一句话：**开发环境的本质，是"人的意图"与"机器状态"之间的回路；每一代环境的使命，是消灭回路里最慢的那一环。**

排队时代环境替你排队，分时时代替你等待，Turbo 时代替你编译，Eclipse 时代替你记忆，VS Code 时代替你连接生态。到 2026 年，打字、编译、导航全都不再是慢的那一环了——**回路里最慢的一环，第一次变成了人本身**：人的注意力带宽，决定了 N 个 agent 能被有效监督多少个。

由此推出三个技术判断：

**1. 终端赢不是复古，是必然。** Agent 的原生形态是"进程 + 文件系统"，不是"GUI 里的光标"。终端天生可组合（管道）、可无头运行（CI/服务器）、可远程（字节流走任何隧道）、可脚本化。IDE 的整个交互模型——buffer、光标、面板——服务于"人手写字符"；agent 不需要其中任何一件。所以最强的 agent 全部生在终端：这是基底（substrate）之争，GUI 输给了进程模型。

**2. 环境层的新原语已经定型。** 上一代环境的原语是 file、buffer、project；这一代是：**session**（一个长时运行的 agent 进程）、**worktree**（每个 agent 的隔离宇宙）、**attention routing**（谁在等我拍板——working/idle/attention 状态机）、**验收面**（diff 审查，而非代码编辑）、**在场性**（人离开桌面时监督权随身走）。谁把这五个原语做成肌肉记忆，谁就是这一代的 VS Code。

**3. 协议层正在重演 LSP。** LSP 把"语言智能"抽成协议，坍缩了适配矩阵；今天 MCP 之于工具、ACP 之于 agent↔环境通信，在做同样的事。历史经验是：**协议本身不赚钱，但定义协议的入口赚走了一切**（LSP 免费，VS Code 拿走了世界）。环境层是协议的落地点，也是标准的话语权所在。

## 第六幕：底层分析 II——商业视角

技术判断只回答"往哪去"，投资判断要回答"钱在哪一层沉淀"。把 AI 编程栈拆成三层看：

**模型层**——Anthropic 年化收入冲到 $300 亿量级、estimates 到 5 月已近 $470 亿，但这是巨头的资本游戏（Series G 一轮融 $300 亿），毛利被算力吞噬，创业公司无位置。

**Agent 层**——Claude Code $80 亿 run-rate 证明了价值巨大，但这一层正在被模型厂商垂直整合：模型厂商送 agent，就像运营商送手机。独立 agent 公司（参考 Windsurf 的 $30 亿 → $2.5 亿）会被上下两层挤压。

**环境层**——**唯一尚未定局、且结构上不会被模型厂商拿走的一层。** 理由有三：

1. **中立性是结构性护城河。** 开发者同时用 Claude Code、Codex、Gemini CLI（调查显示多数团队并用 2 种以上）。Anthropic 的环境不会好好承载 Codex，反之亦然——就像 Google 做不好 iOS 的启动器。多 agent 编排层天然属于第三方，这是"瑞士位置"。
2. **单位经济学翻转了。** 座位制（per-seat）让位于用量制（usage）：一个开发者从"一个座位"变成"N 个 agent 的用量路由器"。**环境层就是那个路由器**——它决定任务流向哪个模型、token 花在哪家。历史类比：浏览器之于互联网、应用商店之于移动。路由器不需要拥有模型，就能聚合需求侧。
3. **入口更替的窗口每 15–20 年才开一次。** IDE 四十年只发生过一次世代性入口更替（VS Code，2015）。Cursor 用三年从 0 到 $600 亿卖出，本质是资本对"下一个入口"的定价——而 Cursor 押的还是旧形态（编辑器）。如果本文的技术判断成立（回路的中心已从 buffer 移到 session），**真正的入口还没有被造出来**。窗口开着，且不会开太久：SpaceX 收购 Cursor、JetBrains 发 Air、Warp 转身 Oz，都是窗口正在关闭的声音。

风险也要说透：最大的威胁是模型厂商把环境层也做了（Anthropic 已在桌面 app 上做并行 agent 界面）。对冲这个风险靠三样：**中立性**（上文）、**本地信任**（代码不出本机——企业采购的硬约束，云端编排永远绕不过去）、以及**工作流数据**（谁看见了"人如何仲裁 agent"，谁就拥有下一代训练数据里最稀缺的部分）。

一句话给投资人：**模型层是巨头的军备竞赛，agent 层是模型的赠品，环境层是这一代唯一的入口生意——而入口生意的历史回报是 Borland、Microsoft、GitHub、Cursor。**

## 尾声：环境替你盯着

这场革命的载体，讽刺地，是被 IDE"取代"了四十年的老东西——终端。Agent 生在终端里，ADE 的自然形态就是一个为编排 agent 而重新发明的终端。

这也是我们做 [termio](https://termio.sh) 的原因：一个原生 macOS 的 agent 终端——多个 CLI agent 并行运行，菜单栏一眼看清谁在干活、谁在等你拍板，人不在桌前时手机接管监督权。不做编辑器的 AI 插件，不做云端的调度面板：拥有运行时，站在中立位，把"人监督 agent 舰队"这一件事做到肌肉记忆。

穿孔卡的时代，环境替你排队；分时的时代，环境替你等待；Turbo 的时代，环境替你编译；Eclipse 的时代，环境替你记忆；VS Code 的时代，环境替你连接。

Agent 的时代，环境替你**盯着**。

---

## 参考资料

**历史**

- [Integrated development environment — Wikipedia](https://en.wikipedia.org/wiki/Integrated_development_environment)
- [The evolution to integrated development environments (IDE) — Computerworld](https://www.computerworld.com/article/1341391/the-evolution-to-integrated-development-environments-ide.html)
- [A Bird's View on Language Servers — itemis](https://blogs.itemis.com/en/a-birds-view-on-language-servers) · [LSP — Eclipse Foundation](https://www.eclipse.org/community/eclipse_newsletter/2017/may/article1.php)

**ADE 论述**

- [The IDE is dead, long live the ADE — Nick Hodges, InfoWorld, 2026-07-08](https://www.infoworld.com/article/4193975/the-ide-is-dead-long-live-the-ade.html)
- [What Is an Agentic Development Environment? — Augment Code](https://www.augmentcode.com/guides/what-is-an-agentic-development-environment)
- [Is the IDE Dead? — Coder](https://coder.com/blog/is-the-ide-dead-the-rise-of-agentic-ai-in-software-development)
- [2026 Agentic Coding Trends Report — Anthropic](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf)

**市场与融资**

- [Cursor in talks / $2B ARR & valuation — TNW](https://thenextweb.com/news/cursor-anysphere-2-billion-funding-50-billion-valuation-ai-coding) · [Cursor (company) — Wikipedia](https://en.wikipedia.org/wiki/Cursor_(company)) · [SpaceX × Cursor $60B — Digital Applied](https://www.digitalapplied.com/blog/spacex-acquires-cursor-anysphere-60b-ai-coding-2026) · [Crunchbase News](https://news.crunchbase.com/venture/cursor-financing-ai-coding-automation/)
- [Claude Code usage statistics — SerpSculpt](https://serpsculpt.com/claude-code-usage-statistics/) · [Anthropic $30B run rate — VentureBeat](https://venturebeat.com/technology/anthropic-says-it-hit-a-30-billion-revenue-run-rate-after-crazy-80x-growth) · [Anthropic Series G](https://www.anthropic.com/news/anthropic-raises-30-billion-series-g-funding-380-billion-post-money-valuation) · [Sacra: Anthropic](https://sacra.com/c/anthropic/)

**竞品**

- [Warp ADE — TIME Best Inventions 2025](https://time.com/collections/best-inventions-2025/7318249/warp-agentic-development-environment/) · [JetBrains Air](https://rywalker.com/research/air-jetbrains) · [Conductor](https://www.conductor.build/) · [herdr](https://herdr.dev/) · [vibe-kanban — GitHub](https://github.com/BloopAI/vibe-kanban) · [多 agent 管理工具盘点 — Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/) · [开源 agent 编排器 — Augment Code](https://www.augmentcode.com/tools/open-source-agent-orchestrators)

**配图授权**：历史图片来自 [Wikimedia Commons](https://commons.wikimedia.org/)（CC BY-SA / EPL / MIT，见各图说明）；Visual Basic 6.0 与 Visual Studio .NET 两张截图来自英文 Wikipedia，属合理使用（fair use）素材，正式发布前建议替换为自行运行旧版软件截取的画面或确认使用场景符合合理使用；近期产品图为各公司官方网站公开的 OG/宣传资产，仅作评论性引用并注明出处。
