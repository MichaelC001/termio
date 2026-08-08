<div align="center">

<img alt="termio" src="web/landing/public/logo.png" width="88" />

### 終端機優先的智能體開發環境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | 繁體中文 | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

<br />

在原生 Mac App 中並行執行 Claude Code、Codex 與任何 CLI 代理 —<br />
每個工作階段都即時顯示在側邊欄，選單列的小圓點會告訴你誰正需要你。

<br />

[**下載 macOS 版**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [官方網站](https://termio.sh) &nbsp;&bull;&nbsp; [文件](https://termio.sh/docs) &nbsp;&bull;&nbsp; [更新日誌](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="深色模式下的 termio：一個即時的 Claude Code 工作階段，旁邊是專案側邊欄" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## 為看著代理工作而打造

IDE 是圍繞著「人打字寫程式」設計的。當大部分程式碼由 AI 編碼代理來寫，
開發環境的任務就變了：它是代理工作的地方，也是你指揮、審閱、幫它們排除
障礙的地方。termio 就是這樣的環境 — 終端機優先，因為代理本來就活在
終端機裡 — 為工作的新型態而生：多個代理同時進行，大多數不需要你，
但總有一個卡住了。（完整的論述：
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md)。）

- **真正的終端機，不是網頁視圖。** Swift + AppKit，建立在
  [libghostty](https://ghostty.org)（Ghostty 的終端機核心）之上，以
  Metal 渲染。沒有 Electron，沒有 xterm.js。
- **專案 → 工作階段。** 側邊欄反映你實際的工作方式：每個專案容納自己的
  終端機與代理，並將 git 工作樹（worktree）巢狀在專案之下，用於平行任務。
- **零設定的狀態偵測。** termio 會自動接上每個代理自己的 hook，並讀取
  代理本來就會發出的訊號。工作中、閒置、或*需要你* — 每個工作階段都有
  狀態圓點，加上一個選單列圖示：平時安靜，代理工作時脈動，有代理被你
  卡住時就會提醒。
- **不用離開就能審閱。** 唯讀的 git 窗格（變更、歷史、統一 diff）、
  附帶點按即編輯器的檔案樹，以及全專案內容搜尋 — 提交程式碼仍然在
  終端機裡完成。
- **免費。** 不需帳號、沒有授權金鑰、沒有付費方案。MIT 授權。

## 功能

<table>
<tr>
<td width="50%" valign="middle">

### 工作階段，並排呈現

每個專案都有自己的終端機與代理工作階段。從側邊欄即可瞬間切換 —
每個工作階段都是一個持續運作的即時 PTY，就算你正在看別的地方也不會停。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero2.png" alt="一個 Codex 工作階段，旁邊是工作階段側邊欄" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 知道代理什麼時候需要你

工作階段圓點顯示工作中 / 閒置 / 需要你，並彙整到選單列圖示，
讓你在任何 App 裡都能一眼看到。從選單列挑一個工作階段，termio
會把它帶到最前面。

</td>
<td width="50%">
  <img src="web/landing/public/feature/tray.png" alt="選單列圖示，依專案分組列出各工作階段" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 分割窗格

Ghostty 風格的工作階段內分割：左邊是代理，右邊是開發伺服器和一個 shell。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero5.png" alt="一個 Claude Code 工作階段與開發伺服器、shell 分割並排" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 檔案與內建編輯器

終端機旁的檔案樹；點一下檔案就能就地編輯，支援語法標示與自動儲存。
影像與 PDF 以 Quick Look 開啟。⌘-點按代理輸出的任何路徑即可預覽。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero3.png" alt="內建編輯器顯示一個 Markdown 檔案，旁邊是檔案樹" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 檢查器

眼前這個工作階段的一切：帶統一 diff 的 git 變更與歷史、全專案內容搜尋、
易讀的代理對話紀錄，以及工作目錄的相關操作。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero4.png" alt="檢查器面板，旁邊是一個 Claude Code 工作階段" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 指令面板

從一個搜尋框跳到任何工作階段、專案或操作。

</td>
<td width="50%">
  <img src="web/landing/public/feature/pallette.png" alt="指令面板" width="100%" />
</td>
</tr>
</table>

**還有這些：**

- **Git 工作樹**：從側邊欄建立 worktree，它會以巢狀資料夾出現在專案之下
  — 每個平行任務一條分支。你從 CLI 建立的 worktree 也會出現。
- **Chats**：不屬於任何專案的臨時代理對話，一個按鍵就能開啟。
- **用量儀表**：你的 Claude 與 Codex 方案額度，從各自的憑證在本機讀取，
  位於「設定 → 用量」。
- **佈景主題**：淺色、深色，以及跟隨系統的玻璃外觀。
- **自動更新**：經過公證的 DMG，透過 Sparkle 更新；新版本會自行安裝。

## 與你的代理一起工作

Claude Code、Codex、Gemini CLI、Grok、Cursor Agent、Copilot、Amp、OpenCode、
Pi、Kimi — 以及任何其他 CLI 代理，因為工作階段就是一個真正的終端機。
對於內建支援的代理，termio 會自動安裝各自的 hook 或外掛，
所以第一次啟動時狀態偵測就能運作。

## 從終端機驅動它

termio 附帶一個 `termio` CLI，工作階段因此可以用腳本操作 — 包括讓代理
自己來操作。在 termio 裡執行的代理可以生出一個同儕、交給它一個任務，
再把回覆讀回來：

```sh
termio sessions list                       # 誰在工作、閒置，或正在等你
termio sessions spawn "fix the flaky test" # 用一段提示啟動新的代理工作階段
termio sessions send claude@ab12cd34 "1"   # 回答同儕的權限提示
termio sessions watch                      # 即時串流狀態變化
```

## 在你的 iPhone 上

配套 App 將每個 Mac 工作階段即時鏡射到你的手機 — 是完整的 TUI，
不是聊天摘要。按鍵列把 esc、tab、ctrl 和方向鍵放在鍵盤上方，
按住說話即可將語音直接轉寫進提示。免費，公開測試中：
[在 TestFlight 上加入](https://testflight.apple.com/join/1Arf1UKR)。

<table>
<tr>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-claude.webp" alt="一個即時的 Claude Code 工作階段鏡射到 iPhone 上" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-keys.webp" alt="鍵盤上方帶有 esc、tab、ctrl 與方向鍵的按鍵列" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-voice.webp" alt="按住說話的語音輸入正轉寫進提示" width="100%" />
</td>
</tr>
</table>

## 安裝

**[下載 macOS 版 termio](https://downloads.termio.sh/termio.dmg)** — 免費、
不需帳號。需要 macOS 14 以上。

或以 [Homebrew](https://brew.sh) 安裝：

```sh
brew install --cask termio-sh/tap/termio
```

**在 iPhone 上**：先到
[TestFlight](https://testflight.apple.com/join/1Arf1UKR) 取得配套 App 測試版，
再掃描 Mac App「設定 ▸ 行動裝置」中的 QR code 完成配對。

## 社群

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 與開發者及其他使用者交流
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — 錯誤回報與功能建議

## 貢獻者

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="貢獻者" />
</a>

## 授權

[MIT](LICENSE)。
