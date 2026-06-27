# Conductor

> 与 termio **相反哲学**的代表：Mac 原生、worktree 并行，但**重 diff / App 内评审**。

## 一句话定位

Mac 原生 App，把多个 Claude Code Agent 并行跑在 git worktree 里，并**在 App 内审 diff、合并**。

## 厂商 / 开源 / 链接

- 闭源商业产品。站点：https://www.conductor.build

## 技术栈与形态

- 原生 macOS（未公开细节）。本地运行 Claude Code Agent。

## 核心能力

- 每个 Agent 一个隔离 workspace；**只复制 git-tracked 文件**（避免 `node_modules`/`.env` 重复），
  每个 workspace 自行跑 setup。
- App 内 **review diff → 合并**的闭环；会话按项目分组。

## 优势

- "并行跑 + 看结果 + 合并"做成闭环，对"我要审 Agent 产出"的用户很顺手。
- worktree 的文件复制策略干净（只带 tracked 文件）。

## 劣势

- 与 termio 哲学相反——**重 diff/评审面板**，表面积大。
- 闭源、细节不透明。

## 与 termio 的异同 / 启示

- 这是"**要不要做 diff**"的分水岭。termio 应坚持**不做代码面板**（赌"Agent 在代码里 +
  人用 git/IDE 审"），把想要 in-app 评审的人用清晰文案引导走，而非中途加面板破坏定位。
- **可借鉴**：worktree 的"只复制 tracked 文件 + `.worktreeinclude`"策略，避免重复巨型目录。

## 参考链接

- https://www.conductor.build
