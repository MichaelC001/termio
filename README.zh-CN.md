> 如对翻译有改进建议，欢迎提交 PR。

<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### 终端优先的 Agent 开发环境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

[**下载 macOS 版**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [官网](https://termio.sh) &nbsp;&bull;&nbsp; [文档](https://termio.sh/docs) &nbsp;&bull;&nbsp; [更新日志](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<img alt="深色模式下的 Termio：一个正在运行的 Claude Code 会话，旁边是项目侧栏" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## 终端优先的 ADE

代码大半改由 Agent 写之后，开发环境的职责就是把它们跑起来，并告诉你哪一个需要你。Termio 就是这样一个环境，而它是一个真实的终端——因为 Agent 本来就住在终端里。

它在第一次启动时自动接好每个 Agent 自带的 hook。会话会报告工作中、空闲，还是*需要你*——侧栏一个状态点，菜单栏托盘在有 Agent 被挡住时出声，手机上是同一个信号。Claude Code、Codex、OpenCode、Pi、Amp、Cursor、Copilot、Kimi、Antigravity、Crush、Grok，以及任何其他 CLI Agent。

更完整的论述：[*From IDE to ADE*](docs/essays/from-ide-to-ade.md)。

### tmux 的替代品

所有人劝你学 tmux 的理由，Termio 让你不用学。每个会话的 shell 都活在守护进程 `termiod` 里，退出 app 只是断开连接。合上笔记本，再打开 Termio，Agent 还在你离开的地方——同一个进程，同一份回滚历史。只有「关闭会话」（⌘W）会结束它。

### 远程终端

任何你能 `ssh` 上去的 Linux VPS。Termio 读 `~/.ssh/config`，从不改写它。**设置 ▸ 设备 ▸ 设置**会通过 SSH 把一个二进制文件复制到 `~/.local/bin`，启动守护进程，并在那台机器上装好 Agent 的 hook。本地会话和远程会话走的是同一套宿主。会话活在机器上，不在连接里。断开链接，Agent 继续干活；重新附着，屏幕原样回来。

## 横向对比

Termio 是 Agent 跑在里面的环境。会话活在机器上的 `termiod` 里，Mac app 和
iPhone 都只是附着上去。

| | Termio | [Ghostty](https://ghostty.org) | [cmux](https://cmux.com) | [herdr](https://herdr.dev) | [Superlogical](https://superlogical.com) | [Otty](https://otty.sh) |
| --- | --- | --- | --- | --- | --- | --- |
| Agent 监控 | ✓ 靠 hook | – | ✓ | ✓ | – | ✓ 标签徽标 |
| Agent 编排 API | ✓ `termio sessions` | – | ✓ CLI 和 socket API | ✓ socket API | – | – |
| Agent 通知 | ✓ 菜单栏托盘 | – | ✓ | ✓ toast、系统通知或声音 | – | – |
| 多路复用 | ✓ 守护进程持有 PTY | – | 重启后恢复 | ✓ 服务端持有 PTY | ✓ 服务端持有 PTY | 重启后恢复 |
| 远程 Linux | ✓ 原生支持 | – | ✓ SSH 工作区 | ✓ 通过 SSH 附着 | ✓ 原生支持 | – |
| iOS | ✓ 直接附着到宿主，包括 VPS | – | ✓ 和 Mac 配对 | 社区插件 | 已预告 | – |
| 项目、工作区 | ✓ | – | 工作区分组 | worktree 命令 | – | – |
| 文件树 | ✓ | – | – | ✓ 插件 | – | – |
| 编辑器 | ✓ | – | – | – | – | – |
| Diff | ✓ | – | – | ✓ 插件 | – | – |
| 开源 | ✓ MIT | ✓ MIT | ✓ GPL | ✓ Apache-2.0 | 部分开源，尚未确定 | – |

## 安装

**[下载 macOS 版 Termio](https://downloads.termio.sh/termio.dmg)**——免费，
不用账号，需要 macOS 14 或更高版本。也可以走 [Homebrew](https://brew.sh)：

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone 端**：从
[TestFlight](https://testflight.apple.com/join/1Arf1UKR) 装伴侣应用的公测版，
再扫 Mac 应用 **设置 ▸ 手机** 里的二维码配对。

## 你会得到什么

<table>
<tr>
<td width="50%" valign="top">
<h3>项目装着会话</h3>
<p>一个 checkout 一个项目，它的终端和 Agent 都在下面。聊天排在项目上方——不属于任何项目的一次性 Agent 会话。</p>
<img alt="Termio 侧栏，显示终端、聊天、项目、worktree 及其嵌套的会话" src="web/landing/public/screenshots/docs/04-project-session-hierarchy.png" />
</td>
<td width="50%" valign="top">
<h3>Git worktree</h3>
<p>一条分支对应一项并行任务，从侧栏创建。Worktree 嵌在它来自的项目下面。</p>
<img alt="Termio 侧栏里的一个 worktree，带着嵌套的会话和一个新增 worktree 的右键菜单" src="web/landing/public/screenshots/docs/12-worktree-hierarchy.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>分屏面板</h3>
<p>⌘D 向右分屏，⇧⌘D 向下分屏。一个 Agent、一个开发服务器、一个 shell，同一个窗口。</p>
<img alt="Termio 里一个 Codex 会话和两个 shell 面板并排成组" src="web/landing/public/screenshots/docs/03-grouped-panes.png" />
</td>
<td width="50%" valign="top">
<h3>状态一眼看清</h3>
<p>工作中、空闲、完成，还是<em>需要你</em>——每一行都有标记。同一份列表就是 <code>termio sessions list</code>。</p>
<img alt="Termio 侧栏报告工作中、完成和需要你，终端里同时跑着 termio sessions list" src="web/landing/public/screenshots/docs/05-session-statuses.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>文件编辑器</h3>
<p>在文件树里点一个文件。语法高亮，自动保存。提交仍然在终端里做。</p>
<img alt="Termio 的文件检查器里打开了一个 Swift 文件，语法高亮的编辑器旁边是终端" src="web/landing/public/screenshots/docs/06-files-editor.png" />
</td>
<td width="50%" valign="top">
<h3>更改</h3>
<p>只读的 git 面板，显示当前的统一 diff。提交、推送和开 PR 仍然在终端里。</p>
<img alt="Termio 的更改标签页选中了一个文件，红绿统一 diff 显示在终端旁边" src="web/landing/public/screenshots/docs/07-changes-diff.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>搜索</h3>
<p>项目级内容搜索，点一下就跳到编辑器里匹配的那一行。</p>
<img alt="Termio 的搜索标签页列出 DiffGapText 在四个文件里的匹配" src="web/landing/public/screenshots/docs/09-project-search.png" />
</td>
<td width="50%" valign="top">
<h3>命令面板</h3>
<p>⌘⇧P。分屏、聚焦，一切你本来要翻菜单找的东西。</p>
<img alt="Termio 的命令面板输入 split，选中了向右分屏" src="web/landing/public/screenshots/docs/10-command-palette.png" />
</td>
</tr>
</table>

## 从终端驱动

`termio` 命令行工具驱动正在运行的应用。跑在 Termio 里的 Agent 可以派生一个同伴，交给它一个任务，再把回复读回来：

```sh
termio .                                    # 把当前目录作为项目打开
termio sessions list                        # 谁在工作、空闲，或在等你
termio sessions spawn "fix the flaky test"  # 用一段提示启动新的 Agent 会话
termio sessions run "pnpm test --watch"     # 用一条命令启动普通终端会话
termio sessions send ab12cd34 "1"           # 回答同伴的权限确认
termio sessions read ab12cd34 --lines 40    # 打印某个会话当前的屏幕
termio sessions watch                       # 实时流式输出状态变化
termio sessions focus ab12cd34              # 在应用里把某个会话切到前台
termio sessions close ab12cd34              # 关掉它
termio notify "the migration finished"      # 发一条 macOS 通知
```

`--wait` 一直等到这一轮结束，回来时带上最终状态和可以去读的记录行范围。`--json` 让任何 `sessions` 命令输出机器可读的结果。`--agent` 决定 `spawn` 启动哪个 Agent。`--direction` / `--ratio` 决定新面板落在哪、占多大。

```sh
termio sessions spawn "run the migration" --agent codex --wait
```

会话控制会往每个 Agent 的技能目录（`~/.claude/skills`、`~/.codex/skills`）装一个 `termio` [Agent 技能](https://termio.sh/skill.md)，并在每次启动时保持它最新。其他 Agent 也可以直接从这个仓库装同一个技能：

```sh
npx skills add termio-sh/termio --skill termio
```

## 在你的 iPhone 上

Termio iOS 把每个会话实时镜像过来——完整的 TUI。按键条把 esc、tab、ctrl 和方向键放在键盘上方，按住说话把语音直接转写进提示词。公测中：[TestFlight](https://testflight.apple.com/join/1Arf1UKR)。

<table>
  <tr>
    <td><img alt="iPhone 上的 Termio：首页，等你的会话排在项目上方" src="web/landing/public/screenshots/iphone-home.webp" width="230" /></td>
    <td><img alt="iPhone 上的 Termio：一个项目下的会话，每个都在报告自己的状态" src="web/landing/public/screenshots/iphone-sessions.webp" width="230" /></td>
    <td><img alt="iPhone 上的 Termio：一个正在运行的 Agent 会话，键盘上方是按键条" src="web/landing/public/screenshots/iphone-session-keys.webp" width="230" /></td>
  </tr>
</table>

## 架构

每个会话都活在 `termiod` 里。客户端只是附着上去。关掉一个客户端不会杀死 Agent。一套协议，变的只有管道。

```
  ┌─────────────────┐ unix  ┌────────────┐         ┌─────────────────┐
  │ Mac app         │──────►│            │         │                 │
  ├─────────────────┤ unix  │            │         │                 │
  │ Windows (soon)  │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ iPhone          │──────►│  termiod   │── PTY ─►│  shell / agent  │
  ├─────────────────┤ unix  │   (Mac)    │         │                 │
  │ TUI (soon)      │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ Android (soon)  │──────►│            │         │                 │
  └─────────────────┘       └────────────┘         └─────────────────┘

  ┌─────────────────┐ ssh   ┌────────────┐         ┌─────────────────┐
  │ Mac app         │──────►│            │         │                 │
  ├─────────────────┤ ssh   │            │         │                 │
  │ Windows (soon)  │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ iPhone          │──────►│  termiod   │── PTY ─►│  shell / agent  │
  ├─────────────────┤ ssh   │  (Linux)   │         │                 │
  │ TUI (soon)      │──────►│            │         │                 │
  ├─────────────────┤ wss   │            │         │                 │
  │ Android (soon)  │──────►│            │         │                 │
  └─────────────────┘       └────────────┘         └─────────────────┘
```

手机直接附着到机器上的 `termiod`，不经过 Mac。VPS 上的会话和你笔记本上的会话是同一种东西。

推导过程写在 [`termiod/ARCHITECTURE.md`](termiod/ARCHITECTURE.md) 里。

## 路线图

- **TUI 客户端** — 从任意终端附着，像你附着 tmux 那样。
- **手机上的 TUI → GUI** — 在实时镜像之上，把 Agent 会话可选地渲染成 GUI。
- **Android** — 和 iPhone 一样的伴侣应用。
- **Windows 支持** — 原生 Windows 应用。同样的想法，同样的 termiod 内核。
- **Web 支持** — 从任意浏览器附着到你的会话，终端还能用链接分享。
- **Issue 分诊** — GitHub、GitLab、Linear 的 issue 直接进应用，随手交给 Agent。

在 [GitHub Issues](https://github.com/termio-sh/termio/issues) 关注进展或参与讨论。

## 社区

**Termio 正在找长期维护者。** 如果你喜欢用它，也想认领上面路线图里的某一块——Web 客户端、Windows，或者 iOS 伴侣应用——来 Discord 打个招呼，或者直接捡一个 issue。

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 和开发者以及其他用户交流
- **微信群** — 中文用户扫下面的二维码
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — bug 和功能需求

<img alt="微信群二维码" src="web/landing/public/wechat-group.png" width="220" />

微信二维码每几天失效一次。失效了就在 Discord 说一声，会换上新的。

## 贡献者

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## 许可证

[MIT](LICENSE)。
