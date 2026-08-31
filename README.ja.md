> 翻訳の改善提案は PR でお寄せください。

<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### ターミナルファーストのエージェンティック開発環境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | 日本語 | <a href="README.ko.md">한국어</a></p>

<br />

Claude Code、Codex をはじめ、あらゆる CLI エージェントを本物の Mac ターミナルで並列に実行 —<br />
Swift と libghostty、Electron なし。メニューバーのドットが、いま対応の必要なエージェントを知らせ、<br />
席を離れているあいだは iPhone が見守ります。

<br />

[**macOS 版をダウンロード**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [ウェブサイト](https://termio.sh) &nbsp;&bull;&nbsp; [ドキュメント](https://termio.sh/docs) &nbsp;&bull;&nbsp; [変更履歴](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="ダークモードの Termio: プロジェクトサイドバーの横で動作するライブ Claude Code セッション" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## インストール

**[macOS 版 Termio をダウンロード](https://downloads.termio.sh/termio.dmg)** — 無料、アカウント不要、macOS 14 以降に対応。[Homebrew](https://brew.sh) でもインストールできます:

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone では**: [TestFlight](https://testflight.apple.com/join/1Arf1UKR) でコンパニオンのベータ版を入手し、Mac アプリの設定 ▸ Mobile に表示される QR コードをスキャンしてペアリングしてください。

## エージェント時代の開発のために

IDE は、人間がコードを打ち込むことを前提に設計されてきました。コードの大半をエージェントが書くようになると、環境の役割は変わります。そこはエージェントが働く場所であり、あなたが指示し、レビューし、行き詰まったエージェントを助ける場所です。Termio はまさにその環境です。エージェントがすでに住んでいる場所だからこそターミナルファーストであり、複数のエージェントが同時に動き、そのほとんどは手がかからず、ひとつだけが詰まっている — そんな新しい仕事のかたちのために作られています。（詳しい議論は [*From IDE to ADE*](docs/essays/from-ide-to-ade.md) をご覧ください。）

- **Web ビューではない、本物のターミナル。** Swift + AppKit を
  [libghostty](https://ghostty.org)（Ghostty のターミナルコア）の上に構築し、
  Metal でレンダリングします。Electron も xterm.js も使っていません。
- **プロジェクト → セッション。** サイドバーは実際の作業の構造をそのまま映します。
  各プロジェクトが自分のターミナルとエージェントを持ち、その下に並行タスク用の
  git ワークツリーがネストされます。
- **設定ゼロのステータス表示。** Termio は各エージェント固有のフックを自動で配線し、
  エージェントがもともと発しているシグナルを読み取ります。作業中・アイドル・
  *要対応* — セッションごとのドットに加え、メニューバーのトレイは普段は静かに、
  エージェントの作業中は脈打ち、あなたの対応待ちになると鳴って知らせます。
- **離れずにレビュー。** 読み取り専用の git ペイン（変更、履歴、unified diff）、
  クリックでそのまま編集できるエディタ付きのファイルツリー、プロジェクト全体のコンテンツ検索 —
  コミットする場所は、あくまでターミナルのままです。
- **git ワークツリー。** サイドバーから作成すると、プロジェクト配下にネストされた
  フォルダとして表示されます。並行タスクごとに 1 ブランチ。
- **チャット。** どのプロジェクトにも属さない使い捨てのエージェント会話。
- **使用量メーター。** Claude と Codex のプラン上限を、設定 → Usage に
  ローカルで表示します。
- **テーマ。** ライト、ダーク、システムに追従するガラス調。
- **自動アップデート。** 公証済み DMG を Sparkle が更新します。
- **無料。** アカウントもライセンスキーも有料プランもありません。MIT ライセンスです。

## tmux を学ばなくていい

みんなが tmux を学べと言う理由は、エージェントの作業にはターミナルより長生きする
セッションが要るからです — アプリを終了しても、ノートを閉じても、エージェントは
動き続けてほしい。Termio はそれを最初からやります。各セッションのシェルはデーモン
`termiod` の中に住んでいるので、終了しても切断されるだけ。アプリを開き直せば、
エージェントは離れたときのまま — 同じプロセス、同じスクロールバックです。
終わらせるのは「セッションを閉じる」（⌘W）だけ。

tmux が教えてくれるはずだった残りは、Mac のショートカットか、もう知っていることです。

- 分割は ⌘D、ズームは ⇧⌘↩ — 先に Ctrl-b は要りません。⌘ ショートカットは
  ペインの中のプログラムに届かないので、vim や TUI とキーを取り合いません。
- スクロール・選択・コピーはトラックパッド、マウス、⌘C。出入りする copy-mode は
  ありません。
- Linux マシンのセッションも同じデーモンが動き、どのシェルからでも
  `termiod attach <session>` で入れます。
- スクリプトは `termio sessions`（後述）が `send-keys` の役目を果たし、
  エージェントのステータスは画面ではなくプロトコル上のオブジェクトです。

## お使いのエージェントで動く

Claude Code、Codex、Gemini CLI、Grok、Cursor Agent、Copilot、Amp、OpenCode、
Pi、Kimi — そのほかどんな CLI エージェントでも動きます。セッションは本物のターミナルそのものだからです。組み込み対応のエージェントは、Termio がそれぞれのフックやプラグインを自動でインストールするため、初回起動からステータス検出が機能します。

## ターミナルから操作する

Termio には `termio` CLI が同梱されており、セッションをスクリプトから操作できます — エージェント自身からも。Termio の中で動くエージェントは、兄弟セッションを起動してタスクを渡し、返答を読み取れます。

```sh
termio .                                    # カレントディレクトリをプロジェクトとして開く
termio sessions list                        # 誰が作業中か、アイドルか、あなたを待っているか
termio sessions spawn "fix the flaky test"  # プロンプトを渡して新しいエージェントセッションを開始
termio sessions run "pnpm test --watch"     # コマンドを渡して通常のターミナルセッションを開始
termio sessions send ab12cd34 "1"           # 兄弟セッションの許可プロンプトに応答
termio sessions read ab12cd34 --lines 40    # そのセッションの画面を出力
termio sessions watch                       # ステータスの変化をリアルタイムにストリーム
termio sessions focus ab12cd34              # アプリでそのセッションを前面に出す
termio sessions close ab12cd34              # 閉じる
termio notify "the migration finished"      # macOS の通知を送る
```

残りはフラグが担います。`--wait` はターンが落ち着くまでブロックし、最終ステータスと読むべきトランスクリプトの行範囲を返します。`--json` は任意の `sessions` コマンドを機械可読にし、`--agent` は `spawn` が起動するエージェントを選び、`--direction` / `--ratio` は新しいペインの位置と大きさを決めます。

```sh
termio sessions spawn "run the migration" --agent codex --wait
```

## iPhone で

コンパニオンアプリが、Mac のすべてのセッションをスマートフォンにライブでミラーリングします — チャットの要約ではなく、TUI そのものです。キーバーが esc、tab、ctrl、矢印キーをキーボードの上に並べ、長押しで話せば音声がそのままプロンプトに文字起こしされます。無料のパブリックベータを公開中です: [TestFlight で参加](https://testflight.apple.com/join/1Arf1UKR)。

## ロードマップ

- **Linux リモートサーバー** — VPS や開発マシンなど、自分の Linux マシンで
  セッションを動かし、Mac アプリから管理できます。
- **Mux サーバー** — 永続的なセッションホスト。セッションは接続ではなくマシン側に
  生きるので、ノートを閉じてもエージェントは動き続け、再接続すれば画面がそのまま
  戻ります。
- **Issue トリアージ** — GitHub・GitLab・Linear の issue をアプリ内で確認し、
  そのままエージェントに任せられます。
- **モバイルの TUI → GUI** — ライブミラーの上に、エージェントセッションを GUI として
  表示するオプション。
- **Windows 対応** — ネイティブの Windows アプリ。同じ思想、同じターミナルコアで、
  Electron 移植ではありません。
- **Web 対応** — どのブラウザからでもセッションに接続。ターミナルはリンクで
  共有できます。

進捗のフォローやご意見は [GitHub Issues](https://github.com/termio-sh/termio/issues) へ。

## コミュニティ

**Termio は長期的なメンテナーを募集しています。** Termio を気に入って使っていて、
上のロードマップのどこか — Linux リモートサーバー、Web クライアント、Windows、
iOS コンパニオンアプリ — を担当してみたい方は、Discord で声をかけるか、issue を
拾ってみてください。

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 開発者やほかのユーザーと交流できます
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — バグ報告と機能リクエスト

## コントリビューター

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## ライセンス

[MIT](LICENSE) ライセンスです。
