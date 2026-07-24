---
title: 从 IDE 到 ADE：排了六十年的队，掉头了
status: archived
type: essay
created: 2026-07-11
updated: 2026-07-24
lang: zh
related:
  - from-ide-to-ade.en.md
description: 1960 年，人排队等机器；2026 年，机器排队等人。把开发环境六十年的历史重讲一遍，你会发现 IDE 的落幕不是意外，而是同一条规律的第六次重演——只是这一次，瓶颈第一次挪到了人身上。
---

1957 年，一位心理学家给自己做了一次时间统计。

J. C. R. Licklider 想搞清楚，一个以思考为业的人，一天到底把时间花在了哪里。他跟踪记录了自己几个月的工作，结论让他难堪：所谓"思考时间"里，大约 **85%** 花在为思考摆好姿势上——找资料、画图表、把数据挪成能用的格式。真正做判断的时间只是零头。更糟的是，用他自己的话说，决定他尝试什么、不尝试什么的，"在一个令人难堪的程度上，取决于文书工作的可行性，而非智力上的价值"。

三年后，他把这份难堪写成了论文《人机共生》（*Man-Computer Symbiosis*, 1960），并下了一个预言：总有一天，机器会接管这些准备工作，人只负责机器做不了的事——**设定目标，做出判断**。

六十六年后的今天，一个 coding agent 在某台 Mac 的终端里连续跑了四十分钟：读代码、改代码、跑测试、修失败。然后它停下来，卡在一个权限确认上，等它的人类回到桌前。

请注意这个画面里队伍的方向。1960 年代，程序员抱着穿孔卡在机房外排队，等机器翻牌；2026 年，是 agent 排着队，等人翻牌。**六十年，这条队伍掉了个头。**

2026 年 7 月 8 日，InfoWorld 刊出一篇标题毫不客气的文章：《The IDE is dead, long live the ADE》。作者 Nick Hodges 的论断是：统治软件开发四十年的集成开发环境，在 agentic coding 面前正在变成一个越用越少的工具。这听起来像标题党。但 IDE 的历史被人梳理过太多次，几乎全都梳理成了编年史——哪一年出了哪个产品。编年史看不出必然性。要看出必然性，你得盯着一个别的东西看：**每一代开发环境，消灭的都是当时回路里最慢的一环；每一次瓶颈迁移，都把工具产业重新洗一次牌。**

下面把六十年重讲一遍。不是编年史——是那条队伍怎么一点点掉头的。

## 队伍的一头是机器

在"开发环境"这个词存在之前，写程序是物理劳动：编码纸上手写，穿孔员打卡，交机房，等几个小时甚至隔天，拿回一叠打印纸——上面可能只有一行编译错误。

![一张 FORTRAN 穿孔卡](https://upload.wikimedia.org/wikipedia/commons/5/58/FortranCardPROJ039.agr.jpg)
*一张 FORTRAN 程序穿孔卡。一行代码，一张卡。（Arnold Reinhold, Wikimedia Commons, CC BY-SA）*

最慢的一环是**反馈周期**：写下代码和看到结果之间，隔着一个官僚系统。Licklider 数出来的那 85%，在这个年代不是病症，是常态——整个行业的"思考时间"都耗在排队上。

第一代环境要消灭的，就是这条队。

## 1964：编程变成一场对话

1964 年 5 月 1 日凌晨四点，达特茅斯学院 College Hall 的地下室里，数学教授 John Kemeny 和一名学生程序员在相邻的两台终端上同时敲下 RUN。两个 BASIC 程序一起返回了正确答案——按达特茅斯自己的说法，"分时系统和 BASIC 在这一刻同时诞生"。这套系统（连分时内核都是本科生写的）不是第一个分时系统——MIT 的 CTSS 早它三年——但它第一次把这种体验交到普通人手里：语言、编辑器、执行环境长在同一个地方，一个大一学生就能坐在"终端"前写代码、跑代码。反馈周期从隔天变成几秒。

![ASR-33 电传打字机](https://upload.wikimedia.org/wikipedia/commons/d/df/ASR-33_at_CHM.agr.jpg)
*Teletype ASR-33，分时时代的标准"显示器"。（Computer History Museum 藏品，Arnold Reinhold 摄, CC BY-SA）*

但请注意那台终端的形状：一台电传打字机。人敲一行，机器答一行，纸卷向上走。**编程史上第一个交互界面，是一场笔谈。**终端生下来就不是"显示器"，是对话工具——你说，它答，你再说。

后来的一切图形界面，都是对这场对话的包装。这个细节，六十年后会变得非常重要。

## 1970s：被遗忘的岔路

几乎所有 IDE 史都从分时系统直接跳到商业 IDE。但 70 年代有一条岔路，值得停下来看——因为它 2026 年还会回来。

在 Xerox PARC，Alan Kay 团队做出了 Smalltalk。用今天的眼光很难描述它有多异端：程序不是文本文件，是**活着的对象**；环境不是工具，是程序栖息的世界。你不"编辑—编译—运行"，你走进一个正在运行的系统里，一边跟它对话一边改造它——浏览器、检查器、调试器都开在活体上，改一个方法，世界当场变化。Alan Kay 后来回忆，主力实现者 Dan Ingalls 最迷恋的就是在一个"永远在运行"的系统上自举——此后十年他发了八十多个版本，没有一次需要"关机重来"。同一时期 MIT 谱系的 Lisp 机走的是同一条路：编辑器、编译器、调试器和你的程序活在同一个地址空间里，界限根本不存在。

![Smalltalk-76 的界面](https://upload.wikimedia.org/wikipedia/commons/9/91/Smalltalk-76.png)
*Smalltalk-76：重叠窗口、类浏览器、活的对象——1976 年。（Wikimedia Commons, CC0）*

![Symbolics Genera](https://upload.wikimedia.org/wikipedia/commons/e/e4/Symbolics_Genera_screenshot.gif)
*Lisp 机的 Genera 环境：整个操作系统就是一个开发环境。（Wikimedia Commons, 公有领域）*

1979 年 12 月，Steve Jobs 到 PARC 参观，看了 Smalltalk 的演示。多年后他自己承认："他们其实给我看了三样东西，但我被第一样闪瞎了眼，根本没看见另外两样。"他拿走的第一样是图形界面；被他漏看的两样，一样是网络，另一样正是这个活的、面向对象的环境。而在更大的战场上，赢的是另一种哲学：Unix——程序是死的文本文件，工具是分离的小刀，一切靠管道缝合。它简陋，但便宜、可组合、可移植。Richard Gabriel 在 1989–90 年给这种胜利起了个流传至今的名字：**worse is better**——他在剑桥的讲台上刚说完，台下第一个开口的 Gerry Sussman 几乎是在嘲笑他，而计算机小报的标题干脆写成《Lisp 已死，Gabriel 宣布》。

岔路就此封存。但此后四十年，赢家一直在回头打劫输家：史上第一个实用的重构工具是 Smalltalk 的 Refactoring Browser（Don Roberts 与 John Brant，UIUC），Martin Fowler 盛赞它"让重构第一次变得又快又愉悦"，IntelliJ 把它的衣钵带进了主流；REPL、热重载、notebook、"边跑边改"——每一样被当作新发明欢呼的东西，都是从这条岔路上捡回来的。

记住这条岔路。

## 1975–1983：环境变成一门生意

通常被认为是第一个作为商品出售的 IDE，不是来自硅谷，而是慕尼黑。1975 年，Softlab 的 **Maestro I** 给编程单独配上专用工作站——它原名 PET（Programm-Entwicklungs-Terminal-System），因为 Commodore 的同名电脑抢了名字才改叫 Maestro。据报道全球装机曾达 22,000 套：波音买了 8 套，美国银行一口气装了 24 套、576 个开发终端。"为编程单独造一台机器"在当时是个激进的想法——也是第一次有人证明：**开发环境本身是一门生意。**

真正把这门生意做进历史的，是一个丹麦年轻人写的编译器。他叫 **Anders Hejlsberg**——记住这个名字，他还会出现两次。

1983 年 11 月，Borland 把他的编译器许可过来，和编辑器塞进同一个程序、塞进个人电脑，命名为 Turbo Pascal，定价 **$49.95**——同类工具当时卖几百上千美元。整个 1.0，编辑器加编译器加运行时，只有 **33KB**。编译以秒计，出错时直接停在编辑器里、光标钉在第一个错误上（Hejlsberg 因此连错误恢复都不用写）："改一行，按一个键，两秒看到结果"重新定义了编程的节奏。最慢的一环从"等机器"变成了"编辑—编译—运行之间的切换"，Borland 消灭了它，也顺手吃掉了那个年代的开发工具市场。

![Turbo Pascal 6 的界面](https://upload.wikimedia.org/wikipedia/commons/8/84/Turbopascal_6.png)
*Turbo Pascal 的字符界面 IDE：编辑、编译、运行、调试，第一次全在一块屏幕里。（Wikimedia Commons）*

## 1991–2001：替你记住一万个文件

个人电脑上的软件越写越大，最慢的一环随之迁移：当项目从一个文件涨到一万个文件，瓶颈变成了**人对代码库的认知负担**。这十年，IDE 从工具变成产业，四个名字各占一块里程碑。

**1991，Visual Basic**：把 GUI 构建器和代码写作缝在一起——拖控件、双击、写事件处理。"可视化编程"第一次让百万级人群跨过编程的门槛，一代企业软件由此诞生。

![Visual Basic 6.0](https://upload.wikimedia.org/wikipedia/en/0/0e/Visual_Basic_6.0_on_Windows_XP.png)
*Visual Basic 6.0：左边控件箱，中间画窗体，双击写事件——无数企业内部系统的出生地。（Wikipedia, 合理使用）*

**1995–1997**：Hejlsberg 第二次登场。他为 Borland 主刀的 Delphi 是对 VB 的正面回击；微软随即出手挖人——签字费 $150 万，Borland 加薪挽留，微软就再加 $150 万。1996 年 10 月他入职微软，次年 Borland 以"三十个月挖走 34 名核心员工"把微软告上法庭。也是 1997 年，微软把所有语言和工具收进一个屋檐叫 Visual Studio，此后统治 Windows 开发二十年，Hejlsberg 在里面设计了 C#。"开发环境"从单个产品变成了平台战略。

![Visual Studio .NET](https://upload.wikimedia.org/wikipedia/en/f/f2/Visual_Studio_.NET_2002_EN.png)
*Visual Studio .NET（2002）——初代 VS 97 已难觅可引用的截图，这是它血统最近的后代：解决方案树 + 属性面板 + 设计器的三件套定型于此。（Wikipedia, 合理使用）*

**2001，Eclipse**：IBM 捐出价值 $4,000 万的代码并交给开放联盟治理，第一个正面击败商业产品的开源 IDE，插件体系成为后来所有"平台型 IDE"的模板。

![Eclipse 的 Java 开发界面](https://upload.wikimedia.org/wikipedia/commons/e/e3/Eclipse_Java_Development_GTK.png)
*Eclipse 的经典解剖结构：项目树、编辑器、Outline、Problems 面板。（Wikimedia Commons, EPL）*

**2001，IntelliJ IDEA**：JetBrains 把"把代码当语法树而不是文本"做成信仰——重构、语义补全、意图检测，语言级智能的金标准从此姓 J。而它最招牌的自动重构，师承的正是那条被封存的岔路：Smalltalk 的 Refactoring Browser。

![IntelliJ IDEA](https://upload.wikimedia.org/wikipedia/commons/8/89/IntelliJ_IDEA_14.1.3.png)
*IntelliJ IDEA：深度语义理解的代表作，也是后来 Android Studio 等一整族 IDE 的地基。（Wikimedia Commons）*

这十年的环境替你记忆。微软靠它收了二十年的租。

## 2015：值钱的不是工具，是位置

微软发布 VS Code，随后（2016 年 6 月，与 Red Hat、Codenvy 一道）把它内部的语言智能开放成 **Language Server Protocol**：语言服务从 IDE 本体剥离成独立进程和开放协议，N 种编辑器 × M 种语言的适配矩阵坍缩成 N + M。IDE 从巨型单体变成轻内核 + 生态。

VS Code 本身用 TypeScript 写成——TypeScript 的首席架构师，Anders Hejlsberg，第三次出现。从 Turbo Pascal 到 C# 到 TypeScript，一个人的简历就是这部历史的目录：他每次换东家，都精确地落在瓶颈即将迁移的位置上。

![早期版本的 VS Code](https://upload.wikimedia.org/wikipedia/commons/8/80/Visual_Studio_Code_0.10.1_on_Windows_7%2C_with_search.png)
*2015 年的 VS Code 0.10.1——后来统治十年的编辑器，最初长这样。（Wikimedia Commons, MIT）*

VS Code 免费，把付费 IDE 挤成了一门利基生意。这里第一次清晰地暴露出这个行业的一条暗线：**开发工具本身越来越不值钱，值钱的是它站的位置**——谁站在开发者和代码之间，谁就定义下一个十年。十年后 Copilot 从这个位置里长出来，不是巧合。

## AI 住进 IDE（2021–2024）

2021 年 GitHub Copilot 把补全从语法级推到意图级。2023 年 Cursor 干脆 fork 了 VS Code，把对话和 agent 塞进编辑器。接下来发生的事，即使放在软件史上也罕见：

![Cursor](https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/og/opengraph-default.png)
*Cursor：AI-IDE 时代最大的赢家。（图：Cursor 官方）*

Cursor 的 ARR 从 2025 年 1 月的 $1 亿涨到 2026 年 6 月的 $40 亿——一年半 40 倍，B2B 软件史上最快之一；2025 年 11 月以 $293 亿估值完成 $23 亿融资，Google 和 Nvidia 都在投资人名单里；2026 年 6 月 16 日，刚完成 IPO 四天的 SpaceX 宣布以 **$600 亿**全股票收购它——史上最大的创业公司收购案。一个 fork 的编辑器，三年，$600 亿。

但同一时期还有一个反面样本：**Windsurf**。2025 年 7 月，OpenAI 的 $30 亿收购因微软的 IP 条款流产；几天后，Google 支付 $24 亿授权费带走 CEO 和核心研发团队——不占一分股权；再过三天，残余部分被 Cognition 收走，价格双方都没披露，TechCrunch 引述知情人的估计：约 $2.5 亿。股东不算亏——Google 那 $24 亿里有他们的分成——但作为一家公司，Windsurf 在几周内被拆成了三块，没有一块还叫 Windsurf。

同一个品类，为什么一个卖出 $600 亿、一个被拆成三块？因为地底下有一条断层线正在裂开，两家公司恰好站在两侧。断层线就是下一节。

## Agent 离开编辑器（2025–2026）

2025 年 2 月，Anthropic 发布 Claude Code——不是插件，不是编辑器，是一个跑在**终端**里的 agent。然后发生了软件工具史上最陡的一条增长曲线：

![Claude Code](https://cdn.sanity.io/images/4zrzovbb/claude-com/6c36adaaf60ecdde313a93ad255eef573ea4de97-1200x630.jpg?w=1200&h=630&fit=crop)
*Claude Code：跑在终端里，而不是编辑器里。（图：Anthropic 官方）*

年化收入从 2025 年 9 月的 $5 亿，到 11 月的 $10 亿，再到 2026 年 2 月的超过 $25 亿——这三个数字全部出自 Anthropic 官方披露；第三方估计到 5 月已在 $80 亿上下。Dario Amodei 在 2026 年 5 月的开发者大会上说，平均每个使用它的开发者，每周用它 **20 个小时**。SemiAnalysis 测算，GitHub 公开 commit 里由 Claude Code 提交的比例，2026 年初已达 4%，按当前轨迹年底将超过 20%。Pragmatic Engineer 2026 年初对约 900 名工程师的调查里，95% 的人至少每周使用 AI 编程工具，Claude Code 以 46% 当选"最受喜爱"——从发布到登顶，只用了一年。OpenAI 的 Codex CLI（2025 年 4 月）、Google 的 Gemini CLI（2025 年 6 月）先后跟进——**三大模型厂商的旗舰 agent，全部生在终端里，没有一个生在 IDE 里。**

关键不是数字，是形态变了。agent 不再是"提示—响应"的问答机，而是能连续跑上几十分钟、自己读代码、跑测试、改错误的工作单元。于是 IDE 的每一个核心假设同时失效：它假设一个人对着一个光标，现实是一个人带着 N 个并行的 agent；它假设核心动作是打字，现实是派活、审查、仲裁；它假设一个工作区一个分支，现实是每个 agent 占着自己的 worktree；它的整个界面为"读写代码"而优化，而你现在真正需要一眼看清的是——谁在跑，谁空转，谁卡在一个确认上等了你四十分钟。

排了六十年的队，在这里正式掉头：**排队的不再是人，是 agent；被等的不再是机器，是你。**

Windsurf 输就输在这里：它把全部身家押在"编辑器 + AI"上，而断层线裂开之后，编辑器在错误的一侧。

## 卡位战已经开始

"人类指挥 agent 舰队"需要一个新环境。过去十二个月，几乎每一类玩家都交了卷。

**Warp**：终端厂商向上做编排。2025 年 6 月率先把自己改名为 "Agentic Development Environment"——ADE 这个词能流行，Warp 出了大力——并凭此入选 TIME 2025 年度最佳发明；2026 年 2 月再推云编排平台 **Oz**，本地 agent 与云端 Docker agent 双模式，随后干脆开源了整个 ADE。这是"从下往上"的路线。

![Warp](https://www.warp.dev/og/default.png)
*Warp：从"更好的终端"转身为 Agentic Development Environment。（图：Warp 官方）*

**JetBrains → Air**（2026 年 3 月公测）：IDE 巨头的自我革命，官方定义原文就是 "an agentic development environment for delegating coding tasks to multiple AI agents"——通过 ACP 协议接入 Codex、Claude、Gemini CLI，用 IDE 级的审查界面验收。当卖了二十五年 IDE 的公司开始给新品类起名，这个品类就成立了。

**GitKraken → Kepler**（2026 年 6 月）：Git 工具厂商从"分支管理"切入多 agent 编排。CEO Matt Johnston 在开头那篇 InfoWorld 文章里说的一句话，可以当作本文的题眼：

> "The IDE was built for the age of one human typing. The ADE is built for the age of humans orchestrating fleets of agents."

![GitKraken Kepler](https://www.gitkraken.com/wp-content/uploads/2026/06/ADE_product_OG-1024x538.png)
*GitKraken Kepler：官方 OG 图直接印上了 "ADE" 三个字母。（图：GitKraken 官方）*

**Conductor**（Melty Labs）：Mac 原生 app，每个 agent 一个独立 git worktree，并行跑 Claude Code、Codex、Cursor。产品目前免费，让你自带已有的 agent 订阅——典型的"先抢工作流，暂缓变现"打法。

![Conductor](https://www.conductor.build/opengraph-image?f984893ec97162f4)
*Conductor：Mac 上并行跑一队 coding agent。（图：Conductor 官方）*

**herdr**：源码公开的 agent 终端复用器，常被叫作 "tmux for agents"（它自己说"不止于此"），持久工作区 + 15 种 agent 的状态自动检测。上线三个半月，1.5 万 GitHub star——开发者用脚投票验证了需求，但它只覆盖了终端侧。

![herdr](https://opengraph.githubassets.com/1/ogulcancelik/herdr)
*herdr：one terminal for the whole herd。（图：GitHub）*

**vibe-kanban**（Bloop）：给 agent 的看板——卡片拖到 In Progress，agent 领任务开分支。Apache 协议、2.7 万 star，然后 **2026 年 4 月 10 日公司关停**，项目交给社区维护。告别信里那句话，应该刻在这个品类的门口："绝大多数用户是免费用户，而我们找不到一个能让自己兴奋起来的商业模式。"

![vibe-kanban](https://vibekanban.com/images/cta-product-desktop.webp)
*vibe-kanban：品类里第一个阵亡者，教训比成功更值钱。（图：vibe-kanban 官方）*

vibe-kanban 之死值得多看一眼。它证明了需求真实存在，也证明了两条路走不通：纯"看板"抽象太薄——agent 的真实界面是终端和 diff，不是卡片；免费开源的编排工具撑不起持续投入。换句话说，这个品类的正确解法被反向框定了：**你必须拥有运行时本身（终端），而不只是它上面的调度视图；你必须从第一天就是一门生意。**这两条，恰好是 Softlab 在 1975 年、Borland 在 1983 年就懂的事。

## 讣告发表那天，前线在干什么

InfoWorld 宣判 IDE 死刑的同一天——2026 年 7 月 8 日——Jarred Sumner 发表了另一篇文章：《Rewriting Bun in Rust》。如果说前者是讣告，后者就是新时代的现场报道。

Bun 是一个 53.5 万行 Zig 写成的 JavaScript 运行时，Claude Code 就跑在它上面。按 Sumner 自己的估算，把它重写成 Rust"需要一个小团队干整整一年"——而软件工程的每一本教科书都会告诉你，永远不要重写。他的做法是：**一个工程师，11 天，峰值同时 64 个 Claude。**6,502 个 commit，最快时每小时 695 个，API 成本约 $16.5 万。

数字不是重点，方法才是。每个任务是一条流水线：一个实现者写代码；**至少两个对抗评审者**在独立的上下文里只看 diff，唯一的任务是"找出 bug，找出这段代码不能工作的理由"；评审意见被消化之后，才允许提交。动工之前，Sumner 先跟 Claude 聊了三个小时，把 Zig 惯用法到 Rust 的映射沉淀成 PORTING.md，把全库每个结构体的生命周期分析成 LIFETIMES.tsv；先拿 3 个文件试跑完整流程，才放开全部 1,448 个。兜底的全是机器：语言无关的测试套件（每平台百万级断言，"0 个测试被跳过或删除"）、六平台 CI、合并后一千亿次覆盖引导 fuzzing。连"选 Rust"这个决定本身都是为回路服务的，他的原话是：**"编译器报错，是比 style guide 更好的反馈回路。"**（利益相关：Bun 于 2025 年 12 月被 Anthropic 收购，这篇文章自带展示成分——但以上流程细节全部可检验。）

请注意这个故事里**没有**的东西：没有人逐行签收。每小时 695 个 commit，物理上不存在"人审每个 diff"这回事。人做的是三件别的事：开工前设计回路，运行中盯着回路的健康，合并前抽查证据——Sumner 全程读 git 历史，终审时把 Rust 和 Zig 并排读了一遍，亲手在本地跑过，才按下合并键。他对整件事的总结淡得像没事发生："一个工程师今天能做的事，比一年前多得多。"

Bun 是极端值，但把 2026 年最会用 agent 的一批工程师排成一列，你会看到一条清晰的光谱。Ghostty 的 Mitchell Hashimoto 站在最谨慎的一端：刻意一次只开一个 agent，"请永远不要不经彻底的人工审查就发布 AI 写的代码"——但连他都把自己方法论的第五阶段命名为 "engineer the harness"，工程化你的挽具。Simon Willison 同时开四个，"我产出的代码，95% 不是我敲的"，代价是"到上午十一点我已经废了"——四个，就是一个人注意力的天花板。Claude Code 之父 Boris Cherny 本地五个会话加云端十来个，每天合并二三十个 PR，他的第一心法不是读 diff，而是**闭合回路**：让 agent 自己用浏览器和测试验证每个改动，他说这能让质量翻两三倍。Peter Steinberger 走到光谱另一端，采访标题就叫《我发布我没读过的代码》——他盯的是流，不是行；而他的另一句话，恰好就是本文的论点：**"我的注意力才是瓶颈。"**再往外，是把人彻底挪出单笔决策的组织化形态：Spotify 的后台 agent 车队用"确定性验证器 + LLM 裁判"跨数千个组件迁移代码，裁判否决约四分之一的提案，没有强制人工评审；Steve Yegge 的 Gas Town 给 20–30 个并行 Claude 编好了角色表——工人、巡逻者、合并队列、市长——人类的头衔是 Overseer，审计的是账本，不是代码。

Armin Ronacher 给这一切算过一笔账，残酷而诚实："不对称性是碾压式的——生成一个 PR 只要一分钟，诚实地评审它要一个小时。"前线全部的方法论，本质上都是对这一个不等式的回应。

## 慢的那一环

现在可以把六十年收拢成一个模型了。

剥掉所有产品名，开发环境的本质只有一句话：**它是人的意图和机器状态之间的一个回路。**写程序，就是不断把脑子里的意图注入机器，再把机器的真实状态读回脑子。六十年里所有的世代更替，都是同一个动作——找到回路里最慢的一环，消灭它。机房排队慢，分时系统消灭了它；编译慢，Turbo Pascal 消灭了它；一万个文件记不住，Eclipse 和 IntelliJ 消灭了它；生态碎片化拖慢一切，LSP 消灭了它。每消灭一环，"最慢"就往下一环挪。

2026 年，它挪到了终点。打字不再慢——代码是 agent 写的；编译不再慢，导航不再慢。回路里最慢的一环，第一次是**人自己**：Willison 的四个 agent，Steinberger 的"我的注意力才是瓶颈"，Ronacher 的一分钟对一小时。而这个瓶颈和之前所有瓶颈都有一个本质区别——它消灭不掉。agent 会更多、更快、更便宜，人的注意力一分钟也不会变多。所以前线的回应是两手同时做：一手让盯着这件事更高效——看流而不是看行，看回路的健康而不是每一次输出；另一手让需要盯的东西变少——把怀疑做成对抗评审的 agent，把"对"做成测试、编译器和 fuzzer，让机器先过滤掉机器的错误。以前的环境消灭瓶颈，这一代的环境做两件事：**善待瓶颈，并且教会机器少去打扰它。**

所以真正改变的不是工具，是"编程"这个词的含义。过去六十年，编程的核心动作是把想法翻译成代码，环境的全部使命是让翻译更快；现在翻译这件事本身外包了，留给人的是 Licklider 在 1960 年就圈出来的那 15%——更古老、也从未被自动化过的东西：**判断**。但前线的实践给"判断"补了一个注脚：它也顶不住每小时 695 个 commit。于是判断本身开始迁移，而且是朝两个方向同时走。**向上游**——什么值得做、什么算"对"，越来越多地在动工之前就被写成文档和挽具：Sumner 的 PORTING.md，Cherny 团队一周更新好几次的 CLAUDE.md，Hashimoto 记录着 agent 失败模式的 AGENTS.md——这些规格、提示词和回路设计，正在取代代码本身，成为一个工程师真正的手艺沉淀。**向系统**——"对不对"被翻译成机器可执行的证据：测试、编译器、对抗评审、LLM 裁判。人不再写代码，也不逐行签收代码；**人签收证据，抽查样本，并为整条回路的设计负责。**开发环境的中心，从编辑器挪到 diff，再从 diff 挪向回路本身。用 Geoffrey Huntley 的话说："工程师正在从雕琢代码，转向设计那些写代码的系统。"

工具的形态只是跟着这个逻辑走。agent 生在终端不是复古趣味，是物理事实：agent 的身体就是进程和文件系统，终端可组合、可无头运行、可以从任何一条隧道远程进来。但还有一层更深的回归。还记得 1964 年那场电传打字机上的笔谈，和 70 年代那条被封存的岔路吗？跟一个正在运行的智能系统对话，它当着你的面读懂并改造代码——**这就是 Smalltalk 的梦，只是穿着 Unix 最丑的衣服实现了。**worse is better，又赢了一次。事后看，GUI-IDE 的四十年是一段插曲：对话才是这门手艺的主线，编辑器是括号。

词汇表跟着换了。上一代环境的名词是 file、buffer、project；这一代是 session——一个跑了四十分钟的 agent 进程；worktree——每个 agent 自己的平行宇宙；harness——你为 agent 设计的那条回路；verifier——机器可执行的"对"；还有那个最要命的问题——"**谁在等我**"。谁先把这几个词做成开发者的肌肉记忆，谁就是这一代的 VS Code。

连协议层都在照剧本重演。LSP 当年把语言智能抽成协议，把 N×M 坍缩成 N+M；今天 MCP 之于工具、ACP 之于 agent 与环境的通信，是一模一样的动作——JetBrains Air 接入 Codex、Claude、Gemini 靠的正是 ACP。LSP 的教训还热着：协议分文不取，落地协议的地方长出一切。

钱的流向，不过是上面这些判断的影子。Cursor 的 $600 亿，买的不是那个编辑器，是它可能站住的位置；Windsurf 的被拆解，输的不是技术，是站错了断层线的一侧；Claude Code 一年从 $5 亿到数十亿则提醒所有人：agent 本身会变成模型的赠品——模型厂商送 agent，就像运营商送手机，生意不在赠品上，在赠品运行的地方。模型厂商当然也看得见这个地方，但有一件事他们天然做不了：中立。开发者已经同时用着 Claude Code、Codex 和 Gemini CLI，而 Anthropic 的环境不会好好伺候 Codex，正如当年的 Google 从不肯给 Windows Phone 一个像样的 YouTube。

Licklider 的预言只对了一半。机器确实接管了那 85% 的准备工作——他没料到的是，剩下 15% 的判断会成为整个回路里最贵、也最堵的一环。**人机共生实现之日，人成了瓶颈。**这样的换代，一个工程师的职业生涯里只会遇到一两次。上一次是 2015 年，再上一次是 1983 年。

## 尾声：环境替你盯着

这场革命的载体，讽刺地，是被 IDE"取代"了四十年的老东西——终端。Agent 生在终端里，ADE 的自然形态就是一个为编排 agent 而重新发明的终端。

这也是我们做 [termio](https://termio.sh) 的原因：一个原生 macOS 的 agent 终端——多个 CLI agent 并行运行，菜单栏一眼看清谁在干活、谁在等你拍板，人不在桌前时手机接管监督权。不做编辑器的 AI 插件，不做云端的调度面板：拥有运行时，站在中立位，把"人监督 agent 舰队"这一件事做到肌肉记忆。

穿孔卡的时代，环境替你排队；分时的时代，环境替你等待；Turbo 的时代，环境替你编译；Eclipse 的时代，环境替你记忆；VS Code 的时代，环境替你连接。

Agent 的时代，环境替你**盯着**。

队伍已经掉头。现在轮到机器等人了——好的环境，会让它们等得短一点。

---

## 参考资料

### 一手文献：史前与岔路

- [Man-Computer Symbiosis — J. C. R. Licklider, IRE Transactions, 1960（MIT CSAIL 存档全文）](https://groups.csail.mit.edu/medg/people/psz/Licklider.html)
- [BASIC at Dartmouth — 达特茅斯学院官方"BASIC at 50"纪念站](https://www.dartmouth.edu/basicfifty/basic.html)
- [The Early History of Smalltalk — Alan Kay, HOPL-II, 1993](https://worrydream.com/EarlyHistoryOfSmalltalk/)
- [The Xerox PARC Visit — 斯坦福大学 "Making the Macintosh" 数字档案（含对 1979 年访问诸多传说的澄清）](https://web.stanford.edu/dept/SUL/sites/mac/parc.html)
- [Worse Is Better — Richard Gabriel 本人整理的来龙去脉](https://dreamsongs.com/WorseIsBetter.html)
- [Crossing Refactoring's Rubicon — Martin Fowler 论 Smalltalk Refactoring Browser, 2001](https://martinfowler.com/articles/refactoringRubicon.html)

### 历史

- [Maestro I — Wikipedia](https://en.wikipedia.org/wiki/Maestro_I)
- [Turbo Pascal — Wikipedia](https://en.wikipedia.org/wiki/Turbo_Pascal) · [30 Years Ago: Turbo Pascal, BASIC Turn PCs Into Programming Engines — eWEEK（含 Hejlsberg 33KB 自述）](https://www.eweek.com/enterprise-apps/30-years-ago-turbo-pascal-basic-turn-pcs-into-programming-engines/)
- [Borland and Microsoft Announce Settlement — 微软官方新闻稿, 1997-09-19](https://news.microsoft.com/source/1997/09/19/borland-and-microsoft-announce-settlement/)
- [Eclipse Celebrates 10 Years of Innovation — Eclipse 基金会官方（IBM $4,000 万代码捐赠）](https://www.eclipse.org/org/press-release/20111102_10years.php)
- [A Common Protocol for Languages — VS Code 官方博客，LSP 开放公告, 2016-06-27](https://code.visualstudio.com/blogs/2016/06/27/common-language-protocol)

### ADE 论述

- [The IDE is dead, long live the ADE — Nick Hodges, InfoWorld, 2026-07-08](https://www.infoworld.com/article/4193975/the-ide-is-dead-long-live-the-ade.html)
- [2026 Agentic Coding Trends Report — Anthropic](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf)

### 前线实践（工程师一手记述）

- [Rewriting Bun in Rust — Jarred Sumner, 2026-07-08](https://bun.com/blog/bun-in-rust) · [Simon Willison 的解读](https://simonwillison.net/2026/Jul/8/rewriting-bun-in-rust/)
- [My AI Adoption Journey — Mitchell Hashimoto, 2026-02-05](https://mitchellh.com/writing/my-ai-adoption-journey) · [Vibing a Non-Trivial Ghostty Feature, 2025-10-11](https://mitchellh.com/writing/non-trivial-vibing)
- [Embracing the parallel coding agent lifestyle — Simon Willison, 2025-10-05](https://simonwillison.net/2025/Oct/5/parallel-coding-agents/) · [Agentic Engineering Patterns（连载指南）](https://simonwillison.net/guides/agentic-engineering-patterns/)
- [Boris Cherny 的并行工作流 — X, 2026-01](https://x.com/bcherny/status/2017742743125299476) · [Building Claude Code — The Pragmatic Engineer, 2026-03-04](https://newsletter.pragmaticengineer.com/p/building-claude-code-with-boris-cherny)
- [Just Talk To It — Peter Steinberger, 2025-10-14](https://steipete.me/posts/just-talk-to-it) · [“I ship code I don't read” — The Pragmatic Engineer, 2026-01-28](https://newsletter.pragmaticengineer.com/p/the-creator-of-clawd-i-ship-code)
- [Agent Psychosis — Armin Ronacher, 2026-01-18](https://lucumr.pocoo.org/2026/1/18/agent-psychosis/) · [Porting MiniJinja to Go With an Agent, 2026-01-14](https://lucumr.pocoo.org/2026/1/14/minijinja-go-port/)
- [Ralph Wiggum as a "software engineer" — Geoffrey Huntley, 2025-07-14](https://ghuntley.com/ralph/) · [everything is a ralph loop, 2026-01-17](https://ghuntley.com/loop/)
- [Feedback loops for background coding agents — Spotify Engineering, 2025-12-09](https://engineering.atspotify.com/2025/12/feedback-loops-background-coding-agents-part-3) · [Gas Town — Steve Yegge](https://yegge.ai/gastown)
- [Claude Code best practices — Anthropic 官方](https://code.claude.com/docs/en/best-practices) · [Introducing dynamic workflows — Anthropic, 2026-05-28](https://claude.com/blog/introducing-dynamic-workflows-in-claude-code)

### 市场

- [Cursor Hits $4 Billion Annualized Revenue — Forbes, 2026-06-08](https://www.forbes.com/sites/richardnieva/2026/06/08/cursor-4-billion-annualized-revenue/) · [Cursor raises $2.3B at $29.3B valuation — CNBC, 2025-11-13](https://www.cnbc.com/2025/11/13/cursor-ai-startup-funding-round-valuation.html) · [SpaceX to acquire Cursor for $60B in stock — TechCrunch, 2026-06-16](https://techcrunch.com/2026/06/16/spacex-to-acquire-cursor-for-60b-in-stock-days-after-blockbuster-ipo/)
- [Cognition to buy Windsurf days after Google poached CEO in $2.4B licensing deal — CNBC, 2025-07-14](https://www.cnbc.com/2025/07/14/cognition-to-buy-ai-startup-windsurf-days-after-google-poached-ceo.html) · [How Windsurf's VCs and founders got paid — TechCrunch, 2025-08-01](https://techcrunch.com/2025/08/01/more-details-emerge-on-how-windsurfs-vcs-and-founders-got-paid-from-the-google-deal/)
- Claude Code 收入里程碑（Anthropic 官方）：[$5 亿 run-rate, Series F, 2025-09](https://www.anthropic.com/news/anthropic-raises-series-f-at-usd183b-post-money-valuation) · [$10 亿, 2025-12](https://www.anthropic.com/news/anthropic-acquires-bun-as-claude-code-reaches-usd1b-milestone) · [超 $25 亿, Series G, 2026-02](https://www.anthropic.com/news/anthropic-raises-30-billion-series-g-funding-380-billion-post-money-valuation) · [公司整体 run-rate 破 $470 亿, Series H, 2026-05](https://www.anthropic.com/news/series-h)
- [Claude Code is the Inflection Point — SemiAnalysis, 2026-02-05（4% → 20%+ commit 测算）](https://newsletter.semianalysis.com/p/claude-code-is-the-inflection-point)
- [AI Tooling for Software Engineers in 2026 — The Pragmatic Engineer, 2026-03-03（n=906 调查）](https://newsletter.pragmaticengineer.com/p/ai-tooling-2026)
- [Anthropic hits $30B run rate after "crazy" 80x growth — VentureBeat（Amodei "每周 20 小时"引言出处）](https://venturebeat.com/technology/anthropic-says-it-hit-a-30-billion-revenue-run-rate-after-crazy-80x-growth)

### 竞品（官方出处）

- Warp：[Introducing Warp 2.0: the Agentic Development Environment, 2025-06](https://www.warp.dev/blog/reimagining-coding-agentic-development-environment) · [Introducing Oz, 2026-02-10](https://www.warp.dev/blog/oz-orchestration-platform-cloud-agents) · [TIME Best Inventions 2025](https://time.com/collections/best-inventions-2025/7318249/warp-agentic-development-environment/)
- JetBrains Air：[官方发布博客, 2026-03](https://blog.jetbrains.com/air/2026/03/air-launches-as-public-preview-a-new-wave-of-dev-tooling-built-on-26-years-of-experience/) · [air.dev](https://air.dev/)
- GitKraken Kepler：[Introducing Kepler, 2026-06-15](https://www.gitkraken.com/blog/introducing-kepler-the-delivery-engine-for-agent-driven-development)
- [Conductor](https://www.conductor.build/) · [herdr — GitHub](https://github.com/ogulcancelik/herdr) · [Goodbye bloop — vibe-kanban 关停公告, 2026-04-10](https://www.vibekanban.com/blog/shutdown)
- [OpenAI Codex CLI — GitHub](https://github.com/openai/codex) · [Introducing Gemini CLI — Google 官方博客, 2025-06-25](https://blog.google/innovation-and-ai/technology/developers-tools/introducing-gemini-cli-open-source-ai-agent/)

**配图授权**：历史图片来自 [Wikimedia Commons](https://commons.wikimedia.org/)（CC0 / 公有领域 / CC BY-SA / EPL / MIT，见各图说明）；Visual Basic 6.0 与 Visual Studio .NET 两张截图来自英文 Wikipedia（合理使用）；近期产品图为各公司官方网站公开的 OG/宣传资产，仅作评论性引用并注明出处。
