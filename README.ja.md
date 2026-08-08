<div align="center">

<img alt="termio" src="web/landing/public/logo.png" width="88" />

### ターミナルファーストのエージェント開発環境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | 日本語 | <a href="README.ko.md">한국어</a></p>

<br />

Claude Code、Codex をはじめとする CLI エージェントをネイティブ Mac アプリで並列実行 —<br />
すべてのセッションがサイドバーにライブ表示され、メニューバーのドットがあなたを必要としているエージェントを教えてくれます。

<br />

[**macOS 版をダウンロード**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [ウェブサイト](https://termio.sh) &nbsp;&bull;&nbsp; [ドキュメント](https://termio.sh/docs) &nbsp;&bull;&nbsp; [変更履歴](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="ダークモードの termio: プロジェクトサイドバーの横で動作するライブ Claude Code セッション" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## エージェントの仕事を見守るために作られた環境

IDE は人間がコードを打ち込むことを前提に作られました。AIコーディングエージェントがコードの大半を書く時代には、環境の役割が変わります。そこはエージェントが働く場所であり、あなたが指示し、レビューし、詰まったエージェントを助ける場所です。termio はまさにその環境です — エージェントがすでに住んでいる場所だからこそターミナルファーストで、新しい仕事のかたちのために作られています。複数のエージェントが同時に動き、そのほとんどは放っておいて大丈夫で、ひとつだけが行き詰まっている — そんな状況のために。（詳しい議論は [*From IDE to ADE*](docs/essays/from-ide-to-ade.md) をご覧ください。）

- **Web ビューではない、本物のターミナル。** Swift + AppKit を
  [libghostty](https://ghostty.org)（Ghostty のターミナルコア）の上に構築し、
  Metal でレンダリング。Electron も xterm.js も使っていません。
- **プロジェクト → セッション。** サイドバーは実際の作業の構造をそのまま映します。
  各プロジェクトが自分のターミナルとエージェントを持ち、並行タスク用の
  git ワークツリーがその下にネストされます。
- **設定ゼロのステータス表示。** termio は各エージェント固有のフックを自動で配線し、
  エージェントがすでに発しているシグナルを読み取ります。作業中・アイドル・
  *要対応* — セッションごとのドットに加え、メニューバーのトレイは普段は静かに、
  エージェントの作業中は脈打ち、あなたの対応待ちでブロックされると鳴らして知らせます。
- **離れずにレビュー。** 読み取り専用の git ペイン（変更、履歴、unified diff）、
  クリックで編集できるエディタ付きのファイルツリー、プロジェクト全体のコンテンツ検索 —
  コミットする場所はあくまでターミナルのままです。
- **無料。** アカウント不要、ライセンスキー不要、有料プランなし。MIT ライセンスです。

## 機能

<table>
<tr>
<td width="50%" valign="middle">

### セッションを並べて

各プロジェクトが自分のターミナルとエージェントセッションを保持します。サイドバーから瞬時に切り替え — 各セッションはライブな PTY で、目を離している間も動き続けます。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero2.png" alt="セッションサイドバーの横で動作する Codex セッション" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### エージェントがあなたを必要とする瞬間がわかる

セッションドットが作業中／アイドル／要対応を示し、どのアプリからでも一目で確認できるメニューバーのトレイに集約されます。トレイからセッションを選べば、termio がそのセッションを前面に呼び出します。

</td>
<td width="50%">
  <img src="web/landing/public/feature/tray.png" alt="プロジェクトごとにセッションを一覧表示するメニューバーのトレイ" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 分割ペイン

セッション内での Ghostty スタイルの分割。左にエージェント、右に開発サーバーとシェル、といった配置ができます。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero5.png" alt="開発サーバーとシェルの横に分割表示された Claude Code セッション" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### ファイルと内蔵エディタ

ターミナルの横にファイルツリー。ファイルをクリックすれば、シンタックスハイライトと自動保存付きでその場で編集できます。画像と PDF は Quick Look で開きます。エージェントが出力したパスは ⌘クリックでプレビューできます。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero3.png" alt="ファイルツリーの横で Markdown ファイルを表示する内蔵エディタ" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### インスペクタ

いま向き合っているセッションのすべてがここに。unified diff 付きの git の変更と履歴、プロジェクト全体のコンテンツ検索、エージェントの会話の読みやすいトレース、作業ディレクトリへのアクション。

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero4.png" alt="Claude Code セッションの横のインスペクタパネル" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### コマンドパレット

ひとつの検索ボックスから任意のセッション、プロジェクト、アクションへジャンプできます。

</td>
<td width="50%">
  <img src="web/landing/public/feature/pallette.png" alt="コマンドパレット" width="100%" />
</td>
</tr>
</table>

**そのほかの同梱機能:**

- **git ワークツリー**: サイドバーからワークツリーを作成すると、プロジェクト配下に
  ネストされたフォルダとして表示されます — 並行タスクごとに 1 ブランチ。
  CLI から作成したワークツリーも表示されます。
- **チャット**: どのプロジェクトにも属さない使い捨てのエージェント会話に、
  キーひとつでアクセスできます。
- **使用量メーター**: Claude と Codex のプラン上限を、それぞれの認証情報から
  ローカルで読み取り、設定 → Usage に表示します。
- **テーマ**: ライト、ダーク、そしてシステムに追従するガラス調の外観。
- **自動アップデート**: 公証済み DMG と Sparkle によるアップデート。
  新しいバージョンは自動でインストールされます。

## お使いのエージェントで動く

Claude Code、Codex、Gemini CLI、Grok、Cursor Agent、Copilot、Amp、OpenCode、
Pi、Kimi — そのほかどんな CLI エージェントでも動きます。セッションは本物のターミナルそのものだからです。組み込み対応のエージェントについては、termio がそれぞれのフックやプラグインを自動でインストールするため、初回起動からステータス検出が機能します。

## ターミナルから操作する

termio は `termio` CLI を同梱しており、セッションはスクリプトで操作できます — エージェント自身からも。termio 内で動くエージェントは、兄弟セッションを起動してタスクを渡し、返答を読み返すことができます。

```sh
termio sessions list                       # 誰が作業中か、アイドルか、あなたを待っているか
termio sessions spawn "fix the flaky test" # プロンプトを渡して新しいエージェントセッションを開始
termio sessions send claude@ab12cd34 "1"   # 兄弟セッションの許可プロンプトに応答
termio sessions watch                      # ステータスの変化をリアルタイムにストリーム
```

## iPhone で

コンパニオンアプリは、Mac のすべてのセッションをスマートフォンにライブでミラーリングします — チャットの要約ではなく、完全な TUI です。キーバーが esc、tab、ctrl、矢印キーをキーボードの上に配置し、長押しで話せば音声がそのままプロンプトに文字起こしされます。無料でパブリックベータ公開中: [TestFlight で参加](https://testflight.apple.com/join/1Arf1UKR)。

<table>
<tr>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-claude.webp" alt="iPhone にミラーリングされたライブ Claude Code セッション" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-keys.webp" alt="キーボードの上に esc、tab、ctrl、矢印キーを備えたキーバー" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-voice.webp" alt="長押しで話した音声をプロンプトに文字起こしする音声入力" width="100%" />
</td>
</tr>
</table>

## インストール

**[macOS 版 termio をダウンロード](https://downloads.termio.sh/termio.dmg)** — 無料、アカウント不要。macOS 14 以降が必要です。

または [Homebrew](https://brew.sh) でインストール:

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone では**: [TestFlight](https://testflight.apple.com/join/1Arf1UKR) でコンパニオンベータを入手し、Mac アプリの設定 ▸ Mobile に表示される QR コードをスキャンしてペアリングします。

## コミュニティ

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 開発者やほかのユーザーと交流できます
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — バグ報告と機能リクエスト

## コントリビューター

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## ライセンス

[MIT](LICENSE) です。
