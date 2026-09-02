> 번역에서 고칠 부분이 있다면 PR을 보내주세요.

<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### 터미널 퍼스트 에이전트 개발 환경

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | 한국어</p>

[**macOS용 다운로드**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [웹사이트](https://termio.sh) &nbsp;&bull;&nbsp; [문서](https://termio.sh/docs) &nbsp;&bull;&nbsp; [변경 내역](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<img alt="다크 모드의 Termio: 프로젝트 사이드바 옆에서 실행 중인 Claude Code 세션" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## 터미널 퍼스트 ADE

코드의 대부분을 에이전트가 쓰게 되면, 개발 환경이 할 일은 그 에이전트들을 돌리고
지금 누가 나를 필요로 하는지 알려주는 거예요. Termio가 바로 그 환경이고, 진짜
터미널이에요. 에이전트가 이미 살고 있는 곳이 터미널이니까요.

처음 실행할 때 각 에이전트가 가진 훅을 알아서 연결해요. 세션은 작업 중인지,
쉬고 있는지, *당신이 필요한지*를 알려줘요 — 사이드바의 점, 에이전트가 막혔을 때
울리는 메뉴 막대 아이콘, 그리고 휴대폰에도 같은 신호가 가요. Claude Code, Codex,
OpenCode, Pi, Amp, Cursor, Copilot, Kimi, Antigravity, Crush, Grok, 그 밖의 어떤
CLI 에이전트든요.

더 긴 이야기는 [*From IDE to ADE*](docs/essays/from-ide-to-ade.md)에 있어요.

### tmux 대신

사람들이 tmux를 배우라고 하는 이유, Termio에서는 배우지 않아도 돼요. 모든 세션의
셸이 데몬 `termiod` 안에서 살기 때문에 앱을 종료해도 연결만 끊길 뿐이에요.
노트북을 덮었다가 Termio를 다시 열면 에이전트는 떠날 때 그대로예요 — 같은
프로세스, 같은 스크롤백. 세션을 끝내는 건 세션 닫기(⌘W)뿐이에요.

### 원격 터미널

`ssh`로 들어갈 수 있는 Linux VPS라면 어디든 돼요. Termio는 `~/.ssh/config`를 읽기만
하고 절대 고쳐 쓰지 않아요. **설정 ▸ 기기 ▸ 설정하기**가 SSH로 바이너리 하나를
`~/.local/bin`에 복사하고, 데몬을 띄우고, 그 머신에 에이전트 훅까지 설치해요.
로컬 세션과 원격 세션이 같은 호스트를 지나가요. 세션은 연결이 아니라 머신 위에
살아요. 연결이 끊겨도 에이전트는 계속 일하고, 다시 붙으면 화면이 그대로 돌아와요.

## 다른 도구와 비교하면

Termio는 에이전트가 그 안에서 도는 환경이에요. 세션은 머신 위의 `termiod` 안에서
살고, Mac 앱도 iPhone도 거기에 붙기만 해요.

| | Termio | [Ghostty](https://ghostty.org) | [cmux](https://cmux.com) | [herdr](https://herdr.dev) | [Superlogical](https://superlogical.com) | [Otty](https://otty.sh) |
| --- | --- | --- | --- | --- | --- | --- |
| 에이전트 모니터 | ✓ 훅 | – | ✓ | ✓ | – | ✓ 탭 배지 |
| 에이전트 오케스트레이션 API | ✓ `termio sessions` | – | ✓ CLI와 소켓 API | ✓ 소켓 API | – | – |
| 에이전트 알림 | ✓ 메뉴 막대 | – | ✓ | ✓ 토스트, 시스템 알림, 소리 | – | – |
| 멀티플렉서 | ✓ 데몬이 PTY를 들고 있음 | – | 다시 열 때 복원 | ✓ 서버가 PTY를 들고 있음 | ✓ 서버가 PTY를 들고 있음 | 다시 열 때 복원 |
| 원격 Linux | ✓ 네이티브 지원 | – | ✓ SSH 워크스페이스 | ✓ SSH로 붙기 | ✓ 네이티브 지원 | – |
| iOS | ✓ 호스트에 바로, VPS까지 | – | ✓ Mac과 페어링 | 커뮤니티 플러그인 | 예고만 | – |
| 프로젝트, 워크스페이스 | ✓ | – | 워크스페이스 그룹 | worktree 명령 | – | – |
| 파일 트리 | ✓ | – | – | ✓ 플러그인 | – | – |
| 에디터 | ✓ | – | – | – | – | – |
| Diff | ✓ | – | – | ✓ 플러그인 | – | – |
| 오픈소스 | ✓ MIT | ✓ MIT | ✓ GPL | ✓ Apache-2.0 | 일부, 미정 | – |

## 설치하기

**[macOS용 Termio 다운로드](https://downloads.termio.sh/termio.dmg)** —
무료이고 계정도 필요 없어요. macOS 14 이상에서 동작해요.
[Homebrew](https://brew.sh)로도 설치할 수 있어요:

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone에서는** [TestFlight](https://testflight.apple.com/join/1Arf1UKR)에서
컴패니언 베타를 받은 뒤, Mac 앱의 Settings ▸ Mobile에 뜨는 QR 코드를
스캔해서 페어링하면 돼요.

## 무엇을 쓸 수 있나요

<table>
<tr>
<td width="50%" valign="top">
<h3>프로젝트가 세션을 담아요</h3>
<p>체크아웃 하나에 프로젝트 하나, 그 아래에 터미널과 에이전트가 놓여요. 채팅은 그 위에 있어요 — 어느 프로젝트에도 속하지 않는 일회성 에이전트 세션이에요.</p>
<img alt="터미널, 채팅, 프로젝트, worktree와 그 아래 세션들을 보여주는 Termio 사이드바" src="web/landing/public/screenshots/docs/04-project-session-hierarchy.png" />
</td>
<td width="50%" valign="top">
<h3>Git worktree</h3>
<p>병렬 작업 하나에 브랜치 하나, 사이드바에서 만들어요. worktree는 원래 프로젝트 아래에 붙어요.</p>
<img alt="Termio 사이드바의 worktree, 그 아래 세션들과 worktree를 추가하는 컨텍스트 메뉴" src="web/landing/public/screenshots/docs/12-worktree-hierarchy.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>페인 분할</h3>
<p>⌘D는 오른쪽으로, ⇧⌘D는 아래로 나눠요. 에이전트, 개발 서버, 셸을 한 창에 두세요.</p>
<img alt="Codex 세션과 셸 페인 두 개를 함께 묶은 Termio" src="web/landing/public/screenshots/docs/03-grouped-panes.png" />
</td>
<td width="50%" valign="top">
<h3>한눈에 보이는 상태</h3>
<p>작업 중, 유휴, 완료, <em>당신이 필요함</em> — 줄마다 표시가 붙어요. 같은 목록이 <code>termio sessions list</code>예요.</p>
<img alt="작업 중, 완료, 당신이 필요함을 알리는 Termio 사이드바와 터미널의 termio sessions list" src="web/landing/public/screenshots/docs/05-session-statuses.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>파일 편집기</h3>
<p>트리에서 파일을 누르면 열려요. 문법 강조와 자동 저장이 되고, 커밋은 그대로 터미널에서 해요.</p>
<img alt="터미널 옆에서 Swift 파일을 문법 강조와 함께 연 Termio 파일 인스펙터" src="web/landing/public/screenshots/docs/06-files-editor.png" />
</td>
<td width="50%" valign="top">
<h3>변경 사항</h3>
<p>지금의 통합 diff를 보여주는 읽기 전용 git 페인이에요. 커밋, 푸시, PR은 터미널에 남아요.</p>
<img alt="파일 하나를 고르고 빨강·초록 통합 diff를 터미널 옆에 띄운 Termio 변경 사항 탭" src="web/landing/public/screenshots/docs/07-changes-diff.png" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>검색</h3>
<p>프로젝트 전체 내용 검색이에요. 편집기에서 해당 줄로 바로 이동해요.</p>
<img alt="네 개 파일에 걸친 DiffGapText 검색 결과를 보여주는 Termio 검색 탭" src="web/landing/public/screenshots/docs/09-project-search.png" />
</td>
<td width="50%" valign="top">
<h3>명령 팔레트</h3>
<p>⌘⇧P. 분할, 포커스 등 메뉴를 뒤져야 했던 건 전부 여기 있어요.</p>
<img alt="split을 입력해 오른쪽으로 분할을 선택한 Termio 명령 팔레트" src="web/landing/public/screenshots/docs/10-command-palette.png" />
</td>
</tr>
</table>

## 터미널에서 조종하기

`termio` CLI가 실행 중인 앱을 조종해요. Termio 안에서 돌고 있는 에이전트가 형제
세션을 띄우고, 작업을 넘기고, 답을 읽어올 수 있어요:

```sh
termio .                                    # 현재 디렉터리를 프로젝트로 열기
termio sessions list                        # 누가 작업 중이고, 대기 중이고, 당신을 기다리는지
termio sessions spawn "fix the flaky test"  # 프롬프트로 새 에이전트 세션 시작
termio sessions run "pnpm test --watch"     # 명령 하나로 일반 터미널 세션 시작
termio sessions send ab12cd34 "1"           # 형제 세션의 권한 프롬프트에 답하기
termio sessions read ab12cd34 --lines 40    # 그 세션의 현재 화면 출력
termio sessions watch                       # 상태 변화를 실시간으로 스트리밍
termio sessions focus ab12cd34              # 앱에서 그 세션을 앞으로 가져오기
termio sessions close ab12cd34              # 닫기
termio notify "the migration finished"      # macOS 알림 보내기
```

`--wait`는 이번 턴이 정리될 때까지 기다렸다가 최종 상태와 읽어야 할 트랜스크립트
줄 범위를 돌려줘요. `--json`은 어떤 `sessions` 명령이든 기계가 읽을 수 있게 만들고,
`--agent`는 `spawn`이 띄울 에이전트를 고르고, `--direction` / `--ratio`는 새 페인이
어디에 얼마나 크게 놓일지 정해요.

```sh
termio sessions spawn "run the migration" --agent codex --wait
```

세션 제어는 각 에이전트의 스킬 폴더(`~/.claude/skills`, `~/.codex/skills`)에
`termio` [에이전트 스킬](https://termio.sh/skill.md)을 설치하고, 실행할 때마다 최신
상태로 유지해요. 다른 에이전트도 이 저장소에서 같은 스킬을 받을 수 있어요:

```sh
npx skills add termio-sh/termio --skill termio
```

## iPhone에서

Termio iOS가 모든 세션을 실시간으로 미러링해요 — TUI 전체를 그대로요. 키 바가
esc, tab, ctrl, 화살표 키를 키보드 위에 놓아주고, 길게 눌러 말하면 음성이 그대로
프롬프트에 입력돼요. 공개 베타는
[TestFlight](https://testflight.apple.com/join/1Arf1UKR)에서 참여할 수 있어요.

<table>
  <tr>
    <td><img alt="iPhone의 Termio: 홈 화면, 프로젝트 위에 놓인 당신이 필요한 세션" src="web/landing/public/screenshots/iphone-home.webp" width="230" /></td>
    <td><img alt="iPhone의 Termio: 프로젝트 안의 세션들이 각자 상태를 알리고 있어요" src="web/landing/public/screenshots/iphone-sessions.webp" width="230" /></td>
    <td><img alt="iPhone의 Termio: 키보드 위에 키 바가 놓인 실시간 에이전트 세션" src="web/landing/public/screenshots/iphone-session-keys.webp" width="230" /></td>
  </tr>
</table>

## 아키텍처

모든 세션은 `termiod` 안에 살아요. 클라이언트는 붙기만 해요. 클라이언트를 닫아도
에이전트는 죽지 않고요. 프로토콜은 하나, 바뀌는 건 파이프뿐이에요.

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

휴대폰은 Mac을 거치지 않고 머신 위의 `termiod`에 바로 붙어요. VPS의 세션과
노트북의 세션은 같은 객체예요.

그 배경은 [`termiod/ARCHITECTURE.md`](termiod/ARCHITECTURE.md)에 적어 뒀어요.

## 로드맵

- **TUI 클라이언트** — tmux에 붙듯이, 어느 터미널에서든 붙을 수 있어요.
- **모바일 TUI → GUI** — 라이브 미러 위에 에이전트 세션을 GUI로 보여주는
  옵션이에요.
- **Android** — iPhone과 같은 컴패니언 앱이에요.
- **Windows 지원** — 네이티브 Windows 앱이에요. 같은 철학, 같은 termiod 코어로요.
- **웹 지원** — 어느 브라우저에서든 세션에 붙을 수 있어요. 터미널은 링크로
  공유할 수 있고요.
- **이슈 트리아지** — GitHub, GitLab, Linear 이슈를 앱 안에서 보고 바로
  에이전트에게 맡겨요.

진행 상황은 [GitHub Issues](https://github.com/termio-sh/termio/issues)에서 지켜보거나 의견을 남겨 주세요.

## 커뮤니티

**Termio는 오래 함께할 메인테이너를 찾고 있어요.** Termio를 즐겨 쓰고 있고 위
로드맵의 한 영역 — 웹 클라이언트, Windows, iOS 컴패니언 앱 — 을 맡아 보고 싶다면,
Discord에서 인사하거나 이슈를 하나 집어 보세요.

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 개발자, 다른 사용자들과 이야기 나눠요
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — 버그 제보와 기능 요청은 여기로요

## 기여자

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## 라이선스

Termio는 [MIT](LICENSE) 라이선스예요.
