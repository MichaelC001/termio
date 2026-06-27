# Crystal / Nimbalyst（stravu/crystal）

> 同类里 **merge-back 体验最成熟**的开源参考实现；但 Electron、走 diff 路线。

## 一句话定位

多会话 Claude Code，每会话一个 git worktree，**rebase / squash / diff 预览**做得最细。

## 厂商 / 开源 / 链接

- 开源（后更名 Nimbalyst）。GitHub：https://github.com/stravu/crystal ｜ https://nimbalyst.com/crystal/
- 技术栈：Electron + TypeScript（核心见 `worktreeManager.ts`）。

## 核心能力

- 每会话一 worktree、一分支；**三种合并 UI**：从 main rebase / squash 后 rebase / apply 前看 diff。
- 鼠标悬停显示**将要执行的 git 命令**（透明、可学习）；空仓自动建初始 commit。

## 优势

- **worktree 生命周期 + 合并 UX 是同类最成熟参考**，且开源可读。
- 对"既要并行又要细致合并"的用户体验完整。

## 劣势

- **Electron**（非原生、重），质感不如 termio/cmux/Unpeel。
- 走 diff/评审路线，表面积大。

## 与 termio 的异同 / 启示

- **直接借鉴其 git plumbing**：worktree create/list/lock/clean 命令序列、分支命名、
  "destroy 前检查 dirty/untracked/unpushed"的安全规则。
- "悬停显示真实 git 命令"对 termio 这种**有主见但想透明**的工具是个好交互范式。
- termio 不跟它比合并 UI 的丰富度——termio 的合并应止于"看 diff（用外部）+ push/PR"，保持轻。

## 参考链接

- https://github.com/stravu/crystal ｜ https://nimbalyst.com/crystal/
