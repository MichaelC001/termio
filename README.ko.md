<div align="center">

<img alt="termio" src="web/landing/public/logo.png" width="88" />

### 터미널 퍼스트 에이전트 개발 환경

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | 한국어</p>

<br />

Claude Code, Codex를 비롯한 모든 CLI 에이전트를 네이티브 Mac 앱에서 나란히 실행하세요 —<br />
모든 세션이 사이드바에 실시간으로 표시되고, 메뉴바 점 표시가 누가 당신을 필요로 하는지 알려줍니다.

<br />

[**macOS용 다운로드**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [웹사이트](https://termio.sh) &nbsp;&bull;&nbsp; [문서](https://termio.sh/docs) &nbsp;&bull;&nbsp; [변경 내역](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="다크 모드의 termio: 프로젝트 사이드바 옆에서 실행 중인 Claude Code 세션" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## 에이전트의 작업을 지켜보기 위해 만들어졌습니다

IDE는 사람이 직접 코드를 타이핑하던 시대에 맞춰 만들어졌습니다. AI 코딩
에이전트가 대부분의 코드를 작성하는 시대에는 개발 환경의 역할이 달라집니다.
에이전트가 일하는 곳이자, 당신이 지시하고, 검토하고, 막힌 곳을 풀어주는
곳이 되어야 합니다. termio가 바로 그 환경입니다 — 에이전트가 이미 살고 있는
곳이기에 터미널 퍼스트로, 새로운 작업 방식에 맞춰 만들어졌습니다. 여러
에이전트가 동시에 달리고, 대부분은 알아서 잘 굴러가지만, 그중 하나는 막혀
있는 그런 상황 말입니다. (더 긴 논의는
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md)를 참고하세요.)

- **웹 뷰가 아닌 진짜 터미널.** [libghostty](https://ghostty.org)(Ghostty의
  터미널 코어) 위에 Swift + AppKit으로 만들어졌고 Metal로 렌더링합니다.
  Electron도, xterm.js도 없습니다.
- **프로젝트 → 세션.** 사이드바는 실제 작업 방식을 그대로 반영합니다. 각
  프로젝트가 자신의 터미널과 에이전트를 품고, 병렬 작업을 위한 git
  워크트리가 그 아래에 중첩됩니다.
- **설정 없이 동작하는 상태 표시.** termio가 각 에이전트 고유의 훅을 자동으로
  연결하고, 에이전트가 이미 내보내는 신호를 읽습니다. 작업 중, 대기 중, 또는
  *needs you* — 세션별 점 표시와 함께, 평소에는 조용하다가 에이전트가 일할 때
  맥동하고 당신을 기다리며 막혀 있을 때 울리는 메뉴바 트레이가 있습니다.
- **떠나지 않고 검토.** 읽기 전용 git 패널(변경 사항, 히스토리, 통합 diff),
  클릭해서 바로 편집하는 에디터가 딸린 파일 트리, 프로젝트 전체 내용 검색 —
  커밋은 여전히 터미널에서 합니다.
- **무료.** 계정도, 라이선스 키도, 유료 등급도 없습니다. MIT 라이선스입니다.

## 기능

<table>
<tr>
<td width="50%" valign="middle">

### 나란히 놓인 세션

프로젝트마다 자신의 터미널과 에이전트 세션을 유지합니다. 사이드바에서 즉시
전환할 수 있고, 각 세션은 다른 곳을 보고 있는 동안에도 계속 실행되는 살아
있는 PTY입니다.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero2.png" alt="세션 사이드바 옆에서 실행 중인 Codex 세션" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 에이전트가 당신을 필요로 하는 순간을 압니다

세션 점 표시가 작업 중 / 대기 중 / needs-you 상태를 보여주고, 이를 모아 어떤
앱에서든 흘끗 확인할 수 있는 메뉴바 트레이로 집계합니다. 트레이에서 세션을
선택하면 termio가 그 세션을 앞으로 가져옵니다.

</td>
<td width="50%">
  <img src="web/landing/public/feature/tray.png" alt="프로젝트별로 묶인 세션 목록을 보여주는 메뉴바 트레이" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 분할 창

세션 안에서 Ghostty 스타일의 분할: 왼쪽에는 에이전트, 오른쪽에는 개발 서버와
셸을 놓을 수 있습니다.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero5.png" alt="개발 서버 및 셸과 나란히 분할된 Claude Code 세션" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 파일과 내장 에디터

터미널 옆에 파일 트리가 있습니다. 파일을 클릭하면 구문 강조와 자동 저장을
갖춘 에디터에서 그 자리에서 편집할 수 있습니다. 이미지와 PDF는 Quick Look으로
열립니다. 에이전트가 출력한 경로를 ⌘-클릭하면 미리 볼 수 있습니다.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero3.png" alt="파일 트리 옆에서 Markdown 파일을 보여주는 내장 에디터" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 인스펙터

지금 다루는 세션에 관한 모든 것: 통합 diff가 딸린 git 변경 사항과 히스토리,
프로젝트 전체 내용 검색, 읽기 좋게 정리된 에이전트 대화 트레이스, 그리고 작업
디렉터리 액션까지.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero4.png" alt="Claude Code 세션 옆의 인스펙터 패널" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 커맨드 팔레트

검색창 하나로 어떤 세션, 프로젝트, 액션으로든 바로 이동합니다.

</td>
<td width="50%">
  <img src="web/landing/public/feature/pallette.png" alt="커맨드 팔레트" width="100%" />
</td>
</tr>
</table>

**이 밖에도 들어 있습니다:**

- **Git 워크트리**: 사이드바에서 워크트리를 만들면 프로젝트 아래 중첩 폴더로
  나타납니다 — 병렬 작업마다 브랜치 하나씩. CLI에서 만든 워크트리도 함께
  표시됩니다.
- **Chats**: 어떤 프로젝트에도 속하지 않는 임시 에이전트 대화를 키 입력 한
  번으로 시작할 수 있습니다.
- **사용량 미터**: Claude와 Codex 플랜 한도를 각자의 자격 증명에서 로컬로
  읽어 Settings → Usage에 보여줍니다.
- **테마**: 라이트, 다크, 그리고 시스템을 따라가는 글래스 모드.
- **자동 업데이트**: Sparkle 업데이트가 포함된 공증된 DMG. 새 버전이 스스로
  설치됩니다.

## 당신의 에이전트와 함께 동작합니다

Claude Code, Codex, Gemini CLI, Grok, Cursor Agent, Copilot, Amp, OpenCode,
Pi, Kimi — 그리고 그 밖의 어떤 CLI 에이전트든 사용할 수 있습니다. 세션은
그저 진짜 터미널이기 때문입니다. 내장 지원되는 에이전트에 대해서는 termio가
각각의 훅이나 플러그인을 자동으로 설치해서, 처음 실행하는 순간부터 상태
감지가 동작합니다.

## 터미널에서 조종하기

termio는 `termio` CLI를 함께 제공하므로 세션을 스크립트로 다룰 수 있습니다 —
에이전트 스스로도 가능합니다. termio 안에서 실행 중인 에이전트가 형제 세션을
띄우고, 작업을 넘기고, 답변을 읽어올 수 있습니다:

```sh
termio sessions list                       # 누가 작업 중이고, 대기 중이고, 당신을 기다리는지
termio sessions spawn "fix the flaky test" # 프롬프트로 새 에이전트 세션 시작
termio sessions send claude@ab12cd34 "1"   # 형제 세션의 권한 프롬프트에 답하기
termio sessions watch                      # 상태 변화를 실시간으로 스트리밍
```

## iPhone에서

컴패니언 앱이 모든 Mac 세션을 휴대폰에 실시간으로 미러링합니다 — 채팅 요약이
아니라 TUI 전체를 그대로 보여줍니다. 키 바가 esc, tab, ctrl, 화살표 키를
키보드 위에 놓아주고, 길게 눌러 말하면 음성이 프롬프트로 바로 받아쓰기됩니다.
무료이며 공개 베타 중입니다: [TestFlight에서 참여하기](https://testflight.apple.com/join/1Arf1UKR).

<table>
<tr>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-claude.webp" alt="iPhone에 실시간으로 미러링된 Claude Code 세션" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-keys.webp" alt="키보드 위의 esc, tab, ctrl, 화살표 키가 있는 키 바" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/iphone-voice.webp" alt="길게 눌러 말하기로 프롬프트에 받아쓰는 음성 입력" width="100%" />
</td>
</tr>
</table>

## 설치

**[macOS용 termio 다운로드](https://downloads.termio.sh/termio.dmg)** — 무료,
계정 불필요. macOS 14 이상이 필요합니다.

또는 [Homebrew](https://brew.sh)로 설치할 수 있습니다:

```sh
brew install --cask termio-sh/tap/termio
```

**iPhone에서는**: [TestFlight](https://testflight.apple.com/join/1Arf1UKR)에서
컴패니언 베타를 받은 뒤, Mac 앱의 Settings ▸ Mobile에 표시되는 QR 코드를
스캔해 페어링하세요.

## 커뮤니티

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 개발자 및 다른 사용자와 대화
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — 버그와 기능 요청

## 기여자

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## 라이선스

[MIT](LICENSE).
