> 如對翻譯有改進建議，歡迎提交 PR。

<div align="center">

<img alt="termio" src="web/landing/public/logo.png" width="88" />

### 終端機優先的智能體開發環境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | 繁體中文 | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

<br />

在原生 Mac 應用程式中並行執行 Claude Code、Codex 與任何 CLI 智能體 —<br />
側邊欄即時呈現每個工作階段，選單列的小圓點隨時告訴您誰正需要您。

<br />

[**下載 macOS 版**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [官方網站](https://termio.sh) &nbsp;&bull;&nbsp; [文件](https://termio.sh/docs) &nbsp;&bull;&nbsp; [更新日誌](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="深色模式下的 termio：一個即時的 Claude Code 工作階段，旁邊是專案側邊欄" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## 為看著智能體工作而打造

IDE 是圍繞著「人打字寫程式」設計的。當大部分程式碼改由智能體來寫，
開發環境的職責也隨之改變：它是智能體工作的地方，也是您下指令、審閱成果、
幫它們排除障礙的地方。termio 就是這樣的環境 — 之所以終端機優先，
是因為智能體本來就活在終端機裡 — 專為新型態的工作而生：多個智能體同時進行，
大多數不勞您操心，但總有一個卡住等您。（完整論述請見
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md)。）

- **真正的終端機，不是網頁視圖。** Swift + AppKit，建構於
  [libghostty](https://ghostty.org)（Ghostty 的終端機核心）之上，以
  Metal 渲染。沒有 Electron，也沒有 xterm.js。
- **專案 → 工作階段。** 側邊欄對應您實際的工作方式：每個專案容納自己的
  終端機與智能體，git 工作樹（worktree）以巢狀方式收在專案底下，方便平行
  處理多項任務。
- **零設定的狀態偵測。** termio 會自動接上各智能體自己的 hook，讀取智能體
  本來就會發出的訊號。工作中、閒置、*需要您* — 每個工作階段都有狀態
  圓點，選單列圖示平時保持安靜，智能體工作時輕輕脈動，一旦有智能體被您
  卡住就會提醒您。
- **審閱不必離開。** 唯讀的 git 窗格（變更、歷史、統一 diff）、附
  點按即編輯器的檔案樹，以及全專案內容搜尋 — 提交程式碼仍然在終端機裡
  完成。
- **免費。** 不需帳號、沒有授權金鑰、沒有付費方案。採 MIT 授權。

## 功能特色

<table>
<tr>
<td width="50%" valign="middle">

### 工作階段並排呈現

每個專案都有自己的終端機與智能體工作階段。從側邊欄即可瞬間切換 —
每個工作階段都是持續運作的即時 PTY，就算您望向別處也不會停下

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero2.png" alt="一個 Codex 工作階段，旁邊是工作階段側邊欄" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 知道智能體何時需要您

工作階段圓點顯示工作中 / 閒置 / 需要您，並彙整至選單列圖示，
無論身在哪個應用程式都能一眼掌握。從選單列點選工作階段，termio
就會把它帶到最前面

</td>
<td width="50%">
  <img src="web/landing/public/feature/tray.png" alt="選單列圖示，依專案分組列出各工作階段" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 分割窗格

Ghostty 風格的工作階段內分割：左邊跑智能體，右邊放開發伺服器和 shell

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero5.png" alt="一個 Claude Code 工作階段與開發伺服器、shell 分割並排" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 檔案與內建編輯器

終端機旁就是檔案樹；點一下檔案即可就地編輯，支援語法標示與自動儲存。
影像與 PDF 以 Quick Look 開啟。⌘ 點按智能體輸出的任何路徑即可預覽

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero3.png" alt="內建編輯器顯示一個 Markdown 檔案，旁邊是檔案樹" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 檢查器

目前工作階段的一切盡在眼前：附統一 diff 的 git 變更與歷史、全專案
內容搜尋、易讀的智能體對話紀錄，以及工作目錄的相關操作

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero4.png" alt="檢查器面板，旁邊是一個 Claude Code 工作階段" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 指令面板

一個搜尋框，跳至任何工作階段、專案或操作

</td>
<td width="50%">
  <img src="web/landing/public/feature/pallette.png" alt="指令面板" width="100%" />
</td>
</tr>
</table>

**還有這些：**

- **Git 工作樹**：從側邊欄建立 worktree，它會以巢狀資料夾出現在專案底下
  — 一條分支對應一項平行任務。您從 CLI 建立的 worktree 也會一併顯示。
- **Chats**：不隸屬任何專案的臨時智能體對話，一個按鍵即可開啟。
- **用量儀表**：您的 Claude 與 Codex 方案額度，從各自的憑證於本機讀取，
  位於「設定 → 用量」。
- **佈景主題**：淺色、深色，以及跟隨系統的玻璃外觀。
- **自動更新**：經公證的 DMG，透過 Sparkle 更新；新版本會自行安裝。

## 與您的智能體一起工作

Claude Code、Codex、Gemini CLI、Grok、Cursor Agent、Copilot、Amp、OpenCode、
Pi、Kimi — 任何 CLI 智能體都行，因為工作階段本來就是一個真正的終端機。
對於內建支援的智能體，termio 會自動安裝各自的 hook 或外掛，
第一次啟動就能偵測狀態。

## 從終端機驅動

termio 附帶 `termio` CLI，工作階段因此可以用腳本操作 — 智能體自己也能操作。
在 termio 裡執行的智能體可以生出一個同儕、交付任務，再把回覆讀回來：

```sh
termio sessions list                       # 誰在工作、閒置，或正在等你
termio sessions spawn "fix the flaky test" # 用一段提示啟動新的智能體工作階段
termio sessions send claude@ab12cd34 "1"   # 回答同儕的權限提示
termio sessions watch                      # 即時串流狀態變化
```

## 在您的 iPhone 上

配套應用程式將每個 Mac 工作階段即時鏡射到您的手機 — 呈現的是完整 TUI，
不是聊天摘要。按鍵列把 esc、tab、ctrl 與方向鍵放在鍵盤上方，
按住說話即可將語音直接轉寫進提示。免費，公開測試中：
[在 TestFlight 上加入](https://testflight.apple.com/join/1Arf1UKR)。

<table>
<tr>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-mirror.webp" alt="一個即時的 Claude Code 工作階段鏡射到 iPhone 上" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-keys.webp" alt="鍵盤上方帶有 esc、tab、ctrl 與方向鍵的按鍵列" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-projects.webp" alt="列出專案及其簽出分支的首頁" width="100%" />
</td>
</tr>
</table>

## 安裝

**[下載 macOS 版 termio](https://downloads.termio.sh/termio.dmg)** — 免費、
不需帳號。需要 macOS 14 或以上版本。

或透過 [Homebrew](https://brew.sh) 安裝：

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone 端**：先到
[TestFlight](https://testflight.apple.com/join/1Arf1UKR) 取得配套應用程式
測試版，再掃描 Mac 應用程式「設定 ▸ 行動裝置」中的 QR code 完成配對。

## 社群

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 與開發者及其他使用者交流
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — 回報錯誤與提出功能建議

## 貢獻者

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="貢獻者" />
</a>

## 授權

[MIT](LICENSE)。
