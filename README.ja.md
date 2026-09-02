> 翻訳の改善提案は PR でお寄せください。

<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### ターミナルファーストのエージェンティック開発環境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | 日本語 | <a href="README.ko.md">한국어</a></p>

[**macOS 版をダウンロード**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [ウェブサイト](https://termio.sh) &nbsp;&bull;&nbsp; [ドキュメント](https://termio.sh/docs) &nbsp;&bull;&nbsp; [変更履歴](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<img alt="ダークモードの Termio: プロジェクトサイドバーの横で動作するライブ Claude Code セッション" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## ターミナルファーストの ADE

コードの大半をエージェントが書くようになると、環境の仕事はエージェントを動かすこと、そして「いまどれがあなたを必要としているか」を伝えることになります。Termio はその環境であり、本物のターミナルです。エージェントはすでにターミナルに住んでいるからです。

初回起動時に、各エージェント自身のフックを自動で設定します。セッションは作業中・アイドル・*要対応* を報告し、サイドバーのドット、詰まったときに鳴るメニューバーのアイコン、そして同じシグナルがあなたの iPhone にも届きます。Claude Code、Codex、OpenCode、Pi、Amp、Cursor、Copilot、Kimi、Antigravity、Crush、Grok、そのほかどんな CLI エージェントでも。

詳しい議論は [*From IDE to ADE*](docs/essays/from-ide-to-ade.md) をご覧ください。

### tmux の代わりに

みんなが tmux を覚えろと言う理由が、Termio では覚えなくて済みます。各セッションのシェルはデーモン `termiod` の中で動くので、アプリを終了してもデタッチされるだけです。ノートを閉じて、また Termio を開けば、エージェントは離れたときのまま — 同じプロセス、同じスクロールバック。終了させるのは「セッションを閉じる」（⌘W）だけです。

### リモートターミナル

`ssh` で入れる Linux VPS ならどれでも。Termio は `~/.ssh/config` を読むだけで、書き換えることはありません。**設定 ▸ デバイス ▸ セットアップ**が SSH 経由でバイナリを 1 つ `~/.local/bin` にコピーし、デーモンを起動し、そのマシンにエージェントのフックを入れます。ローカルのセッションもリモートのセッションも、同じホストを通ります。セッションは接続ではなくマシンの上で生きています。回線が切れてもエージェントは働き続け、再接続すれば画面がそのまま戻ります。

## 他のツールとの比較

Termio はエージェントが動く環境そのものです。セッションはマシン上の `termiod`
の中で動き、Mac アプリも iPhone もそこへアタッチするだけです。

| | Termio | [Ghostty](https://ghostty.org) | [cmux](https://cmux.com) | [herdr](https://herdr.dev) | [Superlogical](https://superlogical.com) | [Otty](https://otty.sh) |
| --- | --- | --- | --- | --- | --- | --- |
| エージェント監視 | ✓ フック | – | ✓ | ✓ | – | ✓ タブのバッジ |
| エージェント操作 API | ✓ `termio sessions` | – | ✓ CLI とソケット API | ✓ ソケット API | – | – |
| エージェント通知 | ✓ メニューバー | – | ✓ | ✓ トースト・システム通知・音 | – | – |
| マルチプレクサ | ✓ デーモンが PTY を持つ | – | 再起動時に復元 | ✓ サーバーが PTY を持つ | ✓ サーバーが PTY を持つ | 再起動時に復元 |
| リモートの Linux | ✓ ネイティブ対応 | – | ✓ SSH ワークスペース | ✓ SSH でアタッチ | ✓ ネイティブ対応 | – |
| iOS | ✓ ホストへ直接、VPS も含めて | – | ✓ Mac とペアリング | コミュニティのプラグイン | 予告のみ | – |
| プロジェクト・ワークスペース | ✓ | – | ワークスペースグループ | worktree コマンド | – | – |
| ファイルツリー | ✓ | – | – | ✓ プラグイン | – | – |
| エディタ | ✓ | – | – | – | – | – |
| Diff | ✓ | – | – | ✓ プラグイン | – | – |
| オープンソース | ✓ MIT | ✓ MIT | ✓ GPL | ✓ Apache-2.0 | 一部、未定 | – |

## インストール

**[macOS 版 Termio をダウンロード](https://downloads.termio.sh/termio.dmg)** — 無料、アカウント不要、macOS 14 以降に対応。[Homebrew](https://brew.sh) でもインストールできます:

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone では**: [TestFlight](https://testflight.apple.com/join/1Arf1UKR) でコンパニオンのベータ版を入手し、Mac アプリの設定 ▸ Mobile に表示される QR コードをスキャンしてペアリングしてください。

## 使えるもの

<table>
<tr>
<td width="50%" valign="top">
<h3>プロジェクトがセッションを持つ</h3>
<p>チェックアウトごとに 1 プロジェクト、その下にターミナルとエージェント。チャットはその上 — どのプロジェクトにも属さない使い捨てのエージェントセッションです。</p>
<img alt="ターミナル、チャット、プロジェクト、worktree とそのネストしたセッションを表示する Termio のサイドバー" src="web/landing/public/screenshots/docs/04-project-session-hierarchy.png" />
</td>
<td width="50%" valign="top">
<h3>Git worktree</h3>
<p>並行タスク 1 つにつき 1 ブランチ、サイドバーから作成できます。worktree は元のプロジェクトの下にネストします。</p>
<img alt="Termio のサイドバー内の worktree、ネストしたセッションと worktree を追加するコンテキストメニュー" src="web/landing/public/screenshots/docs/12-worktree-hierarchy.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>ペイン分割</h3>
<p>⌘D で右に、⇧⌘D で下に分割。エージェント、開発サーバー、シェルを 1 つのウインドウに。</p>
<img alt="Codex セッションと 2 つのシェルペインをグループ化した Termio" src="web/landing/public/screenshots/docs/03-grouped-panes.png" />
</td>
<td width="50%" valign="top">
<h3>ひと目でわかるステータス</h3>
<p>作業中、アイドル、完了、<em>要対応</em> — すべての行にマークが付きます。同じ一覧が <code>termio sessions list</code> です。</p>
<img alt="作業中・完了・要対応を報告する Termio のサイドバーと、ターミナルの termio sessions list" src="web/landing/public/screenshots/docs/05-session-statuses.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>ファイルエディタ</h3>
<p>ツリーでファイルをクリック。シンタックスハイライトと自動保存。コミットはこれまでどおりターミナルで。</p>
<img alt="ターミナルの横で Swift ファイルをシンタックスハイライト付きで開いた Termio のファイルインスペクタ" src="web/landing/public/screenshots/docs/06-files-editor.png" />
</td>
<td width="50%" valign="top">
<h3>変更</h3>
<p>現在の統合 diff を表示する読み取り専用の git ペイン。コミット、プッシュ、PR はターミナルのままです。</p>
<img alt="ファイルを選択し、赤と緑の統合 diff をターミナルの横に表示した Termio の変更タブ" src="web/landing/public/screenshots/docs/07-changes-diff.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>検索</h3>
<p>プロジェクト全体の内容検索。エディタの該当行にそのままジャンプします。</p>
<img alt="4 つのファイルにまたがる DiffGapText の一致を並べた Termio の検索タブ" src="web/landing/public/screenshots/docs/09-project-search.png" />
</td>
<td width="50%" valign="top">
<h3>コマンドパレット</h3>
<p>⌘⇧P。分割、フォーカス、メニューを探し回るような操作はすべてここから。</p>
<img alt="split と入力し「右に分割」を選択している Termio のコマンドパレット" src="web/landing/public/screenshots/docs/10-command-palette.png" />
</td>
</tr>
</table>

## ターミナルから操作する

`termio` CLI は動作中のアプリを操作します。Termio の中のエージェントは、兄弟セッションを起こし、タスクを渡し、その返答を読み取れます:

```sh
termio .                                    # カレントディレクトリをプロジェクトとして開く
termio sessions list                        # 作業中・アイドル・あなた待ちの一覧
termio sessions spawn "fix the flaky test"  # プロンプトを渡して新しいエージェントセッションを開始
termio sessions run "pnpm test --watch"     # コマンドを渡して通常のターミナルセッションを開始
termio sessions send ab12cd34 "1"           # 兄弟セッションの権限確認に答える
termio sessions read ab12cd34 --lines 40    # セッションの画面の内容を出力
termio sessions watch                       # ステータスの変化をストリームで受け取る
termio sessions focus ab12cd34              # アプリでそのセッションを前面に出す
termio sessions close ab12cd34              # 閉じる
termio notify "the migration finished"      # macOS の通知を送る
```

`--wait` はそのターンが落ち着くまで待ち、最終ステータスと読むべきトランスクリプトの範囲を返します。`--json` はどの `sessions` コマンドも機械可読にします。`--agent` は `spawn` が起動するエージェントを選びます。`--direction` / `--ratio` は新しいペインの位置と大きさを決めます。

```sh
termio sessions spawn "run the migration" --agent codex --wait
```

セッション制御は各エージェントのスキルフォルダ（`~/.claude/skills`、`~/.codex/skills`）に `termio` [エージェントスキル](https://termio.sh/skill.md)をインストールし、起動のたびに最新に保ちます。ほかのエージェントも、このリポジトリから同じスキルを入れられます:

```sh
npx skills add termio-sh/termio --skill termio
```

## iPhone で

Termio iOS はすべてのセッションをライブでミラーします — 完全な TUI です。キーバーがキーボードの上に esc、tab、ctrl、矢印キーを並べ、長押しで話すと音声がプロンプトに書き起こされます。[TestFlight](https://testflight.apple.com/join/1Arf1UKR) で public beta 公開中。

<table>
  <tr>
    <td><img alt="iPhone の Termio: ホーム画面、プロジェクトの上に要対応のセッション" src="web/landing/public/screenshots/iphone-home.webp" width="230" /></td>
    <td><img alt="iPhone の Termio: プロジェクト内のセッションが、それぞれのステータスを報告している" src="web/landing/public/screenshots/iphone-sessions.webp" width="230" /></td>
    <td><img alt="iPhone の Termio: キーボードの上にキーバーが並んだライブのエージェントセッション" src="web/landing/public/screenshots/iphone-session-keys.webp" width="230" /></td>
  </tr>
</table>

## アーキテクチャ

すべてのセッションは `termiod` の中で生きています。クライアントはアタッチするだけです。クライアントを閉じてもエージェントは死にません。プロトコルは 1 つ、変わるのはパイプだけです。

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

iPhone は Mac を経由せず、マシン上の `termiod` に直接アタッチします。VPS 上のセッションは、ノート PC 上のセッションとまったく同じオブジェクトです。

その考え方は [`termiod/ARCHITECTURE.md`](termiod/ARCHITECTURE.md) にあります。

## ロードマップ

- **TUI クライアント** — tmux にアタッチするように、どのターミナルからでもアタッチ。
- **モバイルでの TUI → GUI** — ライブミラーの上に、エージェントセッションの GUI 表示をオプションで。
- **Android** — iPhone と同じコンパニオン。
- **Windows 対応** — ネイティブの Windows アプリとしての Termio。同じ考え方、同じ termiod コア。
- **Web 対応** — どのブラウザからでもセッションにアタッチ。リンクで共有できるターミナルも。
- **Issue トリアージ** — GitHub、GitLab、Linear の issue をアプリの中に。そのままエージェントに渡せます。

進捗を追ったり意見を寄せたりするには [GitHub Issues](https://github.com/termio-sh/termio/issues) へ。

## コミュニティ

**Termio は長期のメンテナを探しています。** 使っていて気に入っていて、上のロードマップのどれか — Web クライアント、Windows、iOS コンパニオン — を担当してみたい方は、Discord で声をかけてください。issue を 1 つ拾うところからでも大歓迎です。

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 開発者やほかのユーザーと交流できます
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — バグ報告と機能リクエスト

## コントリビューター

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## ライセンス

[MIT](LICENSE)。
