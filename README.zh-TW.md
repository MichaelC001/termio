> 如對翻譯有改進建議，歡迎提交 PR。

<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### 終端機優先的 Agent 開發環境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | 繁體中文 | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

<br />

在真正的 Mac 終端機裡並排跑 Claude Code、Codex 和任何 CLI Agent —<br />
Swift 加 libghostty，沒有 Electron。選單列的圓點告訴你哪一個在等你，<br />
人不在桌前的時候，iPhone 來告訴你。

<br />

[**下載 macOS 版**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [官方網站](https://termio.sh) &nbsp;&bull;&nbsp; [文件](https://termio.sh/docs) &nbsp;&bull;&nbsp; [更新日誌](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="深色模式下的 Termio：一個正在執行的 Claude Code 工作階段，旁邊是專案側邊欄" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## 安裝

**[下載 macOS 版 Termio](https://downloads.termio.sh/termio.dmg)** — 免費、
不需帳號，需要 macOS 14 或以上版本。或透過 [Homebrew](https://brew.sh) 安裝：

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone 端**：先到
[TestFlight](https://testflight.apple.com/join/1Arf1UKR) 取得配套應用程式
測試版，再掃 Mac 應用程式「設定 ▸ 手機」裡的 QR code 完成配對。

## 為 Agent 寫程式而造

IDE 是圍繞著一個人打字寫程式設計的。程式碼大半改由 Agent 寫之後，開發環境的職責
跟著變：它既是 Agent 幹活的地方，也是你下指令、審閱、幫它們排除障礙的地方。Termio
就是這樣一個環境 — 終端機優先，因為 Agent 本來就住在終端機裡 — 它對著工作的新形狀
造：好幾個 Agent 同時在跑，大多數不用你管，有一個卡住了。（完整論述請見
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md)。）

- **真正的終端機，不是網頁視圖。** Swift + AppKit，跑在
  [libghostty](https://ghostty.org)（Ghostty 的終端機核心）上，用 Metal 渲染。
  沒有 Electron，也沒有 xterm.js。
- **專案 → 工作階段。** 側邊欄對應你實際的工作方式：每個專案裝著自己的終端機和
  Agent，Git worktree 巢狀收在專案底下，一條分支對應一項平行任務。
- **狀態不用設定。** Termio 自動接上每個 Agent 自己的 hook，讀它們本來就會發出的
  訊號。工作中、閒置，還是*需要你* — 每個工作階段一個狀態圓點；選單列圖示平時安靜，
  Agent 幹活時脈動，有 Agent 被你擋住時出聲。
- **審閱不必離開。** 唯讀的 git 窗格（變更、歷史、統一 diff）、點按即編輯的檔案樹、
  全專案內容搜尋 — 提交仍然在終端機裡做。
- **Git worktree。** 從側邊欄建立，以巢狀資料夾出現在專案底下，一條分支對應一項
  平行任務。
- **聊天。** 不隸屬任何專案的一次性 Agent 工作階段。
- **用量儀表。** Claude 與 Codex 的方案額度，在「設定 ▸ 用量」本機讀取。
- **佈景主題。** 淺色、深色，以及跟隨系統的玻璃外觀。
- **自動更新。** 經公證的 DMG，透過 Sparkle 更新。
- **免費。** 不需帳號、沒有授權金鑰、沒有付費方案。採 MIT 授權。

## 不需要學 tmux 了

所有人勸你學 tmux 的理由，是跑 Agent 需要比終端機活得久的工作階段——退出 app、
闔上筆電，Agent 得繼續做事。這件事 Termio 開箱就做了：每個工作階段的 shell 都
活在常駐程式 `termiod` 裡，退出 app 只是斷開連線。再打開，Agent 還在你離開的
地方——同一個程序，同一份捲動歷史。只有「關閉工作階段」（⌘W）會結束它。

tmux 剩下要教你的東西，要麼是一個 Mac 快捷鍵，要麼你本來就會：

- 分割：⌘D，放大：⇧⌘↩——不用先按 Ctrl-b。⌘ 快捷鍵根本不會傳進窗格裡的程式，
  所以永遠不會和 vim 或 TUI 搶鍵。
- 捲歷史、選文字、複製：觸控板、滑鼠、⌘C。沒有 copy-mode 要進出。
- Linux 機器上的工作階段：同一個常駐程式跑在那邊，任何 shell 裡
  `termiod attach <session>` 就能接上。
- 腳本化：`termio sessions`（見下文）做的就是 `send-keys` 腳本做的事，而且
  Agent 狀態是協定物件，不用抓畫面。

## 和你現有的 Agent 一起用

Claude Code、Codex、Antigravity、Grok、Cursor Agent、Copilot、Amp、OpenCode、
Pi、Kimi — 以及任何其他 CLI Agent，因為工作階段本來就是一個真正的終端機。
內建的那些，Termio 會自動裝上它們各自的 hook 或外掛，你第一次啟動它們時狀態偵測
就已經在了。

## 從終端機驅動

Termio 附帶 `termio` 命令列工具，工作階段因此可以用腳本操作 — Agent 自己也能呼叫。
跑在 Termio 裡的 Agent 可以生出一個同儕，交給它一項任務，再把回覆讀回來：

```sh
termio .                                    # 把目前目錄當成專案打開
termio sessions list                        # 誰在工作、閒置，或正在等你
termio sessions spawn "fix the flaky test"  # 用一段提示啟動新的 Agent 工作階段
termio sessions run "pnpm test --watch"     # 用一條指令啟動一般終端機工作階段
termio sessions send ab12cd34 "1"           # 回答同儕的權限確認
termio sessions read ab12cd34 --lines 40    # 印出某個工作階段目前的畫面
termio sessions watch                       # 即時串流狀態變化
termio sessions focus ab12cd34              # 在應用程式裡把某個工作階段切到前景
termio sessions close ab12cd34              # 關掉它
termio notify "the migration finished"      # 發一則 macOS 通知
```

其餘的交給參數：`--wait` 會一路等到這一輪結束，回來時帶著最終狀態和可以去讀的紀錄
行範圍；`--json` 讓任何 `sessions` 指令輸出機器可讀的結果；`--agent` 決定 `spawn`
啟動哪個 Agent；`--direction` / `--ratio` 決定新面板落在哪、佔多大。

```sh
termio sessions spawn "run the migration" --agent codex --wait
```

Agent 自己會學會這套：工作階段控制會往每個 Agent 的技能目錄（`~/.claude/skills`、
`~/.codex/skills`）裝一個 `termio`
[Agent 技能](https://termio.sh/skill.md)，並在每次啟動時保持它最新。
其他 Agent 也可以直接從這個儲存庫裝同一個技能：

```sh
npx skills add termio-sh/termio --skill termio
```

## 在你的 iPhone 上

配套應用程式把每個 Mac 工作階段即時鏡射到手機上 — 呈現的是完整 TUI，不是聊天摘要。
按鍵列把 esc、tab、ctrl 和方向鍵放在鍵盤上方，按住說話把語音直接轉寫進提示。免費，
公開測試中：[在 TestFlight 上加入](https://testflight.apple.com/join/1Arf1UKR)。

<table>
  <tr>
    <td><img alt="iPhone 上的 Termio：首頁，等你的工作階段排在專案上方" src="web/landing/public/screenshots/iphone-home.webp" width="230" /></td>
    <td><img alt="iPhone 上的 Termio：一個專案底下的工作階段，每個都在回報自己的狀態" src="web/landing/public/screenshots/iphone-sessions.webp" width="230" /></td>
    <td><img alt="iPhone 上的 Termio：一個正在執行的 Agent 工作階段，鍵盤上方是按鍵列" src="web/landing/public/screenshots/iphone-session-keys.webp" width="230" /></td>
  </tr>
</table>

## 架構

Termio 的每個工作階段都跑在 `termiod` 上 — 一個小小的 Rust daemon，在活兒實際跑
的那台機器上持有 PTY。每個介面 — Mac 應用程式、手機、瀏覽器 — 都是透過同一套帶版本
的協定附著上去的用戶端。

```
  web     ─WSS──┐
  iPhone  ─WSS──┼─► termiod (Mac)    ─► PTY ─► shell / agent
  Mac app ─unix─┘

  web     ─WSS──┐
  iPhone  ─WSS──┼─► termiod (Linux)  ─► PTY ─► shell / agent
  Mac app ─ssh──┘
```

變的只有管線，每一段上的訊框完全一樣。沒有哪個用戶端要穿過另一個用戶端才能拿到工作
階段 — 手機因此不是 Mac 的衛星，VPS 上的工作階段和筆電上的工作階段也因此是同一種
東西。

**已經有的：** daemon 和它的協定、`unix`、`ssh`、`wss` 三種傳輸、附著時的快照、
回捲、檔案和 git 平面，以及 launchd/systemd 託管。Mac 應用的每個工作階段都跑在
它上面，手機透過 WSS 附著到 Mac 或 Linux 機器。**還沒有的：** 瀏覽器客戶端。

推導過程寫在 [`termiod/ARCHITECTURE.md`](termiod/ARCHITECTURE.md) 和
[`docs/`](docs/README.md) 底下的設計筆記裡。

## 路線圖

- **Linux 遠端伺服器** — 工作階段跑在你自己的 Linux 機器上（VPS、開發機），在 Mac
  應用程式裡統一帶。
- **Mux 伺服器** — 持久的工作階段主機：工作階段活在機器上，不在連線裡。闔上筆電，
  Agent 繼續工作；重新附著，畫面原樣回來。
- **Issue 分流** — GitHub、GitLab、Linear 的 issue 直接進應用程式，隨手交給 Agent。
- **手機上的 TUI → GUI** — 在即時鏡射之上，把 Agent 工作階段選擇性地渲染成 GUI。
- **Windows 支援** — 原生 Windows 應用程式。同樣的想法，同樣的終端機核心，不是
  Electron 移植。
- **Web 支援** — 從任何瀏覽器附著到你的工作階段，終端機還能用連結分享。

在 [GitHub Issues](https://github.com/termio-sh/termio/issues) 追蹤進展或參與討論。

## 社群

**Termio 正在找長期維護者。** 如果你喜歡用它，也想認領路線圖裡的某一塊 — Linux
遠端伺服器、Web 用戶端、Windows，或者 iOS 配套應用程式 — 來 Discord 打聲招呼，
或者直接撿一個 issue。

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 和開發者以及其他使用者交流
- **微信群** — 中文使用者掃下面的 QR Code
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — 錯誤回報與功能建議

<img alt="微信群 QR Code" src="web/landing/public/wechat-group.png" width="220" />

微信 QR Code 每幾天失效一次。失效了就在 Discord 說一聲，會換上新的。

## 貢獻者

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="貢獻者" />
</a>

## 授權

[MIT](LICENSE)。
