---
title: 从 IDE 到 ADE：开发环境六十年，以及它为什么正在终结
status: done
type: marketing
created: 2026-07-11
updated: 2026-07-11
---

> 成品已定稿并交付：中文版 `web/blog/from-ide-to-ade.zh.md`，英文版 `web/blog/from-ide-to-ade.en.md`。本文件保留为工作草稿。

# 从 IDE 到 ADE：开发环境六十年，以及它为什么正在终结

> Blog 草稿：对开发环境这个行业的一次完整认知——六十年里，每一次换代都是回路里"最慢的一环"迁移的结果。今天瓶颈第一次挪到了人身上，编程的含义随之改变，IDE 让位给 ADE。

2026 年 7 月 8 日，InfoWorld 刊出一篇文章，标题毫不客气：**《The IDE is dead, long live the ADE》**。作者 Nick Hodges 的论断是：统治了软件开发四十年的集成开发环境，在 agentic coding 面前正在变成一个"越用越少的工具"。

这听起来像标题党。但把 IDE 六十年的历史摊开看，你会发现这不是一次意外，而是同一条规律的第六次重演。这条规律只有两句话：

**每一代开发环境，消灭的都是当时回路里最慢的一环；每一次瓶颈迁移，都把整个工具产业重新洗了一次牌。**

先讲历史。历史讲完，你会发现现在正在发生的事情几乎是照着剧本演的。

## 六十年，五次迁移

### 1950s–60s：代码离机器很远

在"开发环境"这个词存在之前，写程序是物理劳动：编码纸上手写，穿孔员打卡，交机房，等几个小时甚至隔天，拿回一叠打印纸——上面可能只有一行编译错误。

![一张 FORTRAN 穿孔卡](https://upload.wikimedia.org/wikipedia/commons/5/58/FortranCardPROJ039.agr.jpg)
*一张 FORTRAN 程序穿孔卡。一行代码，一张卡。（Arnold Reinhold, Wikimedia Commons, CC BY-SA）*

最慢的一环是**反馈周期**：写下代码和看到结果之间，隔着一个官僚系统。

### 1964：Dartmouth BASIC，第一次"坐在终端前编程"

达特茅斯学院的分时系统和 BASIC 语言，第一次把语言、编辑器、执行环境长在同一个系统里。程序员第一次坐在"终端"前写代码、跑代码——尽管那台终端是哐哐作响的电传打字机。反馈周期从隔天变成几秒。

![ASR-33 电传打字机](https://upload.wikimedia.org/wikipedia/commons/d/df/ASR-33_at_CHM.agr.jpg)
*Teletype ASR-33，分时时代的标准"显示器"。（Computer History Museum 藏品，Arnold Reinhold 摄, CC BY-SA）*

### 1975：Maestro I，第一个商业 IDE

第一个作为商品出售的 IDE 不是来自硅谷，而是慕尼黑。Softlab 的 **Maestro I** 给小型机配上专用编程工作站，全球供 22,000 名程序员使用。"为编程单独造一台机器"在当时是个激进的想法——也是第一次有人证明：**开发环境本身是一门生意。**

![Maestro I 专用键盘](https://upload.wikimedia.org/wikipedia/commons/c/cc/Maestro-I-Keyboard.JPG)
*Maestro I 的专用键盘。（Wikimedia Commons, CC BY-SA 4.0）*

### 1983：Turbo Pascal，$49.95 的革命

Borland 把编辑器和编译器塞进同一个程序、塞进个人电脑，编译以秒计，卖 $49.95——同类工具当时卖几百上千美元。"改一行，按 F9，两秒看到结果"重新定义了编程的节奏。最慢的一环从"等机器"变成了"编辑-编译-运行的切换"，Borland 消灭了它，也顺手吃掉了那个年代的开发工具市场。

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

这十年，最慢的一环是**人对大型代码库的认知负担**——当项目从一个文件涨到一万个文件，IDE 替你记住全部结构。微软靠它收了二十年的租。

### 2015：VS Code 与 LSP，编辑器成为平台

微软发布 VS Code，并定义了 **Language Server Protocol**：语言智能从 IDE 本体剥离成独立进程和开放协议，N 种编辑器 × M 种语言的适配矩阵坍缩成 N + M。IDE 从巨型单体变成轻内核 + 生态。

![早期版本的 VS Code](https://upload.wikimedia.org/wikipedia/commons/8/80/Visual_Studio_Code_0.10.1_on_Windows_7%2C_with_search.png)
*2015 年的 VS Code 0.10.1——后来统治十年的编辑器，最初长这样。（Wikimedia Commons, MIT）*

VS Code 免费，却终结了付费 IDE 的生意。这里第一次清晰地暴露出这个行业的一条暗线：**开发工具本身越来越不值钱，值钱的是它站的位置**——谁站在开发者和代码之间，谁就定义下一个十年。十年后 Copilot 从这个位置里长出来，不是巧合。

## AI 住进 IDE（2021–2024）

2021 年 GitHub Copilot 把补全从语法级推到意图级。2023 年 Cursor 干脆 fork 了 VS Code，把对话和 agent 塞进编辑器。接下来发生的事，即使放在软件史上也罕见：

![Cursor](https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/og/opengraph-default.png)
*Cursor：AI-IDE 时代最大的赢家。（图：Cursor 官方）*

Cursor 的 ARR 从 2025 年 1 月的 $1 亿涨到 2026 年 6 月的 $40 亿——18 个月 40 倍，B2B 软件史上最快之一；2025 年 11 月以 $293 亿估值融资，2026 年 6 月被 SpaceX 以 **$600 亿**全股票收购。一个 fork 的编辑器，三年，$600 亿。

但同一时期还有一个反面样本：**Windsurf**。2025 年年中 OpenAI 的 $30 亿收购流产，核心团队被 Google 以授权交易带走，年底残余部分以约 $2.5 亿卖给 Cognition。六个月，估值蒸发九成。

同一个品类，为什么一个 $600 亿、一个 $2.5 亿？因为地底下有一条断层线正在裂开，两家公司恰好站在两侧。断层线就是下一节。

## Agent 离开编辑器（2025–2026）

2025 年 2 月，Anthropic 发布 Claude Code——不是插件，不是编辑器，是一个跑在**终端**里的 agent。然后发生了软件工具史上最陡的一条增长曲线：

![Claude Code](https://cdn.sanity.io/images/4zrzovbb/claude-com/6c36adaaf60ecdde313a93ad255eef573ea4de97-1200x630.jpg?w=1200&h=630&fit=crop)
*Claude Code：跑在终端里，而不是编辑器里。（图：Anthropic 官方）*

年化收入从 2025 年 9 月的 $5 亿，到 11 月 $10 亿，到 2026 年 2 月 $25 亿，到 5 月约 **$80 亿**。平均每个开发者每周用它 20 个小时。SemiAnalysis 估计公开 commit 里由它生成的比例年初还是 4%，年底将超过 20%。Pragmatic Engineer 对 15,000 名开发者的调查里，73% 的团队每天使用 AI 编程工具，Claude Code 以 46% 当选"最受喜爱"。OpenAI 的 Codex CLI、Google 的 Gemini CLI 跟进——**最强的 agent 全部生在终端里，没有一个生在 IDE 里。**

关键不是数字，是形态变了。agent 不再是"提示-响应"的问答机，而是能连续跑上几十分钟、自己读代码、跑测试、改错误的工作单元。于是 IDE 的每一个核心假设同时失效：它假设一个人对着一个光标，现实是一个人带着 N 个并行的 agent；它假设核心动作是打字，现实是派活、审查、仲裁；它假设一个工作区一个分支，现实是每个 agent 占着自己的 worktree；它的整个界面为"读写代码"而优化，而你现在真正需要一眼看清的是——谁在跑，谁空转，谁卡在一个确认上等了你四十分钟。

Windsurf 输就输在这里：它把全部身家押在"编辑器 + AI"上，而断层线裂开之后，编辑器在错误的一侧。

## 卡位战已经开始

"人类指挥 agent 舰队"需要一个新环境。过去十二个月，几乎每一类玩家都交了卷。

**Warp → Oz**（2026 年 2 月）：终端厂商向上做编排，本地 agent + 云端 Docker agent 双模式，入选 TIME 2025 年度最佳发明。这是"从下往上"的路线。

![Warp](https://www.warp.dev/og/default.png)
*Warp：从"更好的终端"转身为 Agentic Development Environment。（图：Warp 官方）*

**JetBrains → Air**：IDE 巨头的自我革命，官方定义原文就是 "agentic development environment"——把任务委托给并行 agent，用 IDE 级的审查界面验收。当卖了二十五年 IDE 的公司开始给新品类起名，这个品类就成立了。

**GitKraken → Kepler**：Git 工具厂商从"分支管理"切入多 agent 编排。CEO Matt Johnston 的一句话可以当作本文的题眼：

> "The IDE was built for the age of one human typing. The ADE is built for the age of humans orchestrating fleets of agents."

![GitKraken Kepler](https://www.gitkraken.com/wp-content/uploads/2026/06/ADE_product_OG-1024x538.png)
*GitKraken Kepler：官方 OG 图直接印上了 "ADE" 三个字母。（图：GitKraken 官方）*

**Conductor**（Melty Labs）：Mac 原生 app，每个 agent 一个独立 git worktree 并行跑 Claude Code/Codex。产品免费、自带订阅——典型的"先抢工作流，暂缓变现"打法。

![Conductor](https://www.conductor.build/opengraph-image?f984893ec97162f4)
*Conductor：Mac 上并行跑一队 coding agent。（图：Conductor 官方）*

**herdr**：开源的 agent-aware 终端复用器（"tmux for agents"），1.5 万+ GitHub star，持久工作区 + agent 状态检测。开源社区用脚投票验证了需求，但只覆盖了终端侧。

![herdr](https://opengraph.githubassets.com/1/ogulcancelik/herdr)
*herdr：one terminal for the whole herd。（图：GitHub）*

**vibe-kanban**（Bloop）：给 agent 的看板——卡片拖到 In Progress，agent 领任务开分支。Apache 协议、社区庞大，然后 **2026 年 4 月宣布关停**，代码交给社区。

![vibe-kanban](https://vibekanban.com/images/cta-product-desktop.webp)
*vibe-kanban：品类里第一个阵亡者，教训比成功更值钱。（图：vibe-kanban 官方）*

vibe-kanban 之死值得多看一眼。它证明了需求真实存在，也证明了两条路走不通：纯"看板"抽象太薄——agent 的真实界面是终端和 diff，不是卡片；免费开源的编排工具撑不起持续投入。换句话说，这个品类的正确解法被反向框定了：**你必须拥有运行时本身（终端），而不只是它上面的调度视图；你必须从第一天就是一门生意。** 这两条，恰好是 Softlab 在 1975 年、Borland 在 1983 年就懂的事。

## 慢的那一环

现在可以把六十年收拢成一个模型了。

剥掉所有产品名，开发环境的本质只有一句话：**它是人的意图和机器状态之间的一个回路。** 写程序，就是不断把脑子里的意图注入机器，再把机器的真实状态读回脑子。六十年里所有的世代更替，都是同一个动作——找到回路里最慢的一环，消灭它。机房排队慢，分时系统消灭了它；编译慢，Turbo Pascal 消灭了它；一万个文件记不住，Eclipse 和 IntelliJ 消灭了它；生态碎片化拖慢一切，LSP 消灭了它。每消灭一环，"最慢"就往下一环挪。

2026 年，它挪到了终点。打字不再慢——代码是 agent 写的；编译不再慢，导航不再慢。回路里最慢的一环，第一次是**人自己**：你盯得住几个并行的 agent？而这个瓶颈和之前所有瓶颈都有一个本质区别——它消灭不掉。agent 会更多、更快、更便宜，人的注意力一分钟也不会变多。以前的环境消灭瓶颈，这一代的环境只能做一件事：**善待瓶颈。**

所以真正改变的不是工具，是"编程"这个词的含义。过去六十年，编程的核心动作是把想法翻译成代码，环境的全部使命是让翻译更快；现在翻译这件事本身外包了，留给人的是更古老、也从未被自动化过的东西：**判断**。什么值得做，做成什么样算对，哪个方案该毙掉。人不再写代码，人签收代码。开发环境的中心，从编辑器挪到了 diff。

工具的形态只是跟着这个逻辑走。agent 生在终端不是复古趣味，是物理事实：agent 的身体就是进程和文件系统。终端可组合、可无头运行、可以从任何一条隧道远程进来；GUI 是为人手设计的，管道是为程序设计的，而 agent 是程序。所以给 agent 造环境，不是给 IDE 加插件，而是把终端重新发明一遍——只是这一次，屏幕对面坐的不再是打字的人，而是**验收的人**。

词汇表跟着换了。上一代环境的名词是 file、buffer、project；这一代是 session——一个跑了四十分钟的 agent 进程；worktree——每个 agent 自己的平行宇宙；还有那个最要命的问题——"**谁在等我**"。谁先把这几个词做成开发者的肌肉记忆，谁就是这一代的 VS Code。

连协议层都在照剧本重演。LSP 当年把语言智能抽成协议，把 N×M 坍缩成 N+M；今天 MCP 之于工具、ACP 之于 agent 与环境的通信，是一模一样的动作。LSP 的教训还热着：协议分文不取，落地协议的地方长出一切。

钱的流向，不过是上面这些判断的影子。Cursor 的 $600 亿，买的不是那个编辑器，是它可能站住的位置；Windsurf 的 $2.5 亿，输的不是技术，是站错了断层线的一侧；Claude Code 一年 $80 亿则提醒所有人：agent 本身会变成模型的赠品——模型厂商送 agent，就像运营商送手机，生意不在赠品上，在赠品运行的地方。模型厂商当然也看得见这个地方，但有一件事他们天然做不了：中立。开发者已经同时用着 Claude Code、Codex 和 Gemini CLI，而 Anthropic 的环境不会好好伺候 Codex，正如 Google 做不出好的 iPhone 启动器。

这样的换代，一个工程师的职业生涯里只会遇到一两次。上一次是 2015 年，再上一次是 1983 年。

## 尾声：环境替你盯着

这场革命的载体，讽刺地，是被 IDE"取代"了四十年的老东西——终端。Agent 生在终端里，ADE 的自然形态就是一个为编排 agent 而重新发明的终端。

这也是我们做 [termio](https://termio.sh) 的原因：一个原生 macOS 的 agent 终端——多个 CLI agent 并行运行，菜单栏一眼看清谁在干活、谁在等你拍板，人不在桌前时手机接管监督权。不做编辑器的 AI 插件，不做云端的调度面板：拥有运行时，站在中立位，把"人监督 agent 舰队"这一件事做到肌肉记忆。

穿孔卡的时代，环境替你排队；分时的时代，环境替你等待；Turbo 的时代，环境替你编译；Eclipse 的时代，环境替你记忆；VS Code 的时代，环境替你连接。

Agent 的时代，环境替你**盯着**。

---

## 参考资料

### 历史

- [Integrated development environment — Wikipedia](https://en.wikipedia.org/wiki/Integrated_development_environment)
- [The evolution to integrated development environments (IDE) — Computerworld](https://www.computerworld.com/article/1341391/the-evolution-to-integrated-development-environments-ide.html)
- [A Bird's View on Language Servers — itemis](https://blogs.itemis.com/en/a-birds-view-on-language-servers) · [LSP — Eclipse Foundation](https://www.eclipse.org/community/eclipse_newsletter/2017/may/article1.php)

### ADE 论述

- [The IDE is dead, long live the ADE — Nick Hodges, InfoWorld, 2026-07-08](https://www.infoworld.com/article/4193975/the-ide-is-dead-long-live-the-ade.html)
- [What Is an Agentic Development Environment? — Augment Code](https://www.augmentcode.com/guides/what-is-an-agentic-development-environment)
- [Is the IDE Dead? — Coder](https://coder.com/blog/is-the-ide-dead-the-rise-of-agentic-ai-in-software-development)
- [2026 Agentic Coding Trends Report — Anthropic](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf)

### 市场与融资

- [Cursor $2B ARR & valuation — TNW](https://thenextweb.com/news/cursor-anysphere-2-billion-funding-50-billion-valuation-ai-coding) · [Cursor (company) — Wikipedia](https://en.wikipedia.org/wiki/Cursor_(company)) · [SpaceX × Cursor $60B — Digital Applied](https://www.digitalapplied.com/blog/spacex-acquires-cursor-anysphere-60b-ai-coding-2026) · [Crunchbase News](https://news.crunchbase.com/venture/cursor-financing-ai-coding-automation/)
- [Claude Code usage statistics — SerpSculpt](https://serpsculpt.com/claude-code-usage-statistics/) · [Anthropic $30B run rate — VentureBeat](https://venturebeat.com/technology/anthropic-says-it-hit-a-30-billion-revenue-run-rate-after-crazy-80x-growth) · [Anthropic Series G](https://www.anthropic.com/news/anthropic-raises-30-billion-series-g-funding-380-billion-post-money-valuation) · [Sacra: Anthropic](https://sacra.com/c/anthropic/)

### 竞品

- [Warp ADE — TIME Best Inventions 2025](https://time.com/collections/best-inventions-2025/7318249/warp-agentic-development-environment/) · [JetBrains Air](https://rywalker.com/research/air-jetbrains) · [Conductor](https://www.conductor.build/) · [herdr](https://herdr.dev/) · [vibe-kanban — GitHub](https://github.com/BloopAI/vibe-kanban) · [多 agent 管理工具盘点 — Nimbalyst](https://nimbalyst.com/blog/best-agent-management-tools-2026/) · [开源 agent 编排器 — Augment Code](https://www.augmentcode.com/tools/open-source-agent-orchestrators)

**配图授权**：历史图片来自 [Wikimedia Commons](https://commons.wikimedia.org/)（CC BY-SA / EPL / MIT，见各图说明）；Visual Basic 6.0 与 Visual Studio .NET 两张截图来自英文 Wikipedia，属合理使用（fair use）素材，正式发布前建议替换为自行运行旧版软件截取的画面；近期产品图为各公司官方网站公开的 OG/宣传资产，仅作评论性引用并注明出处。
