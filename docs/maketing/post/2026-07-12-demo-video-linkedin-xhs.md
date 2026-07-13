# termio demo video — LinkedIn + 小红书文案（2026-07-12）

Video: `~/Desktop/screenstudio/termio/Termio-with-cover.mp4` (59.7s, 1660×1080).
X post on hold by user decision; LinkedIn + Xiaohongshu first.
Angle: user value, essay-style storytelling (Common Reader post as the model:
friction chain → files pain → "others built this but ugly" → what I built →
honest present-tense capabilities → free).

---

## 小红书（中文）

**标题**（≤20 字）：做了一个给 AI 编程的终端 ADE， Termio，Mac 原生，漂亮又流畅。

**封面**：单独上传 `2026-07-12-video-cover.png`；视频传高清原片 `Termio.mp4`。

**正文**：

2026 年，软件编程的范式已经彻底变化了。 我们大部分时间已经不是敲键盘写代码，而是一个项目开着十几个Agent 会话, Claude Code、Codex、OpenCode, Pi... 给 Agent描述编程意图， 编排他们执行这些意图。传统为手写代码进行优化的IDE，其布局功能已经不再适合AI编程了，这也是最近很多人在做 ADE （Agent Development Environment）的原因。

我最近也开发了一个 ADE， Termio，一个原生 Mac 终端 ADE，内核用 libghostty（和 Ghostty 同款），agent 的 TUI 渲染性能很强， 使用极为流畅。更重要的产品设计围绕 AI 编程进行设计，项目管理和 Session管理的状态一目了然，文件树和 diff 直接在终端旁边显示，给 Agent 提供 context 十分方便。另外也开发了 iPhone 端的 companion app ，随时随地通过手机进行 AI 编程。

别的不敢保证，应该是当前市面上当前最漂亮的 ADE 终端了。如果你想要一款漂亮，稳定的 ADE 终端，可以下载试一试 termio.sh。


**标签** #AI编程 #ClaudeCode #OpenCode #Kimi #Mac软件 #程序员 #效率工具

---

## LinkedIn (English)

These days I rarely write code by hand. Most of my day is spent supervising
coding agents — Claude Code, Codex, OpenCode, a few of them running at once —
and answering their questions.

The workflow usually went like this: open five terminal windows → cmd-tab
through them one by one → discover an agent has been sitting on "Do you want
to proceed?" for twenty minutes → answer it → forget which project the next
window belongs to.

And then there are files. A terminal has no concept of a file. To show an
agent a design mockup, you drag the file into the window to conjure up a
path. To see what it actually changed, you type git diff and scroll through
a wall of characters. To fix one line yourself, you switch away to an editor.
Everything about coding has moved into the terminal — except the files.

Plenty of people have built tools for this — tmux scripts, web dashboards,
Electron wrappers. They work. But honestly, they're all ugly. The terminal
is the window I stare at longest every day; I couldn't stand it being ugly.

So I built termio: a native Mac terminal, written in Swift, on libghostty
(the same core as Ghostty), so agents' TUIs render exactly as they should.

It doesn't do much yet, but everything it does, I use every day. A sidebar
holds every project and session, each with a live status — working, done, or
waiting for your answer. A file tree sits right beside the terminal: click a
file to read or edit it, and see what the agent changed as a diff, right
there. An iPhone companion is on its way to the App Store, so you can answer
that "proceed?" prompt from your phone.

Beyond that, I don't plan to add much. It exists to do one thing: let one
person quietly run a team of agents.

It's free. No account, no sign-up. Link in the comments.

**First comment:** Download: termio.sh — free, no account needed.
