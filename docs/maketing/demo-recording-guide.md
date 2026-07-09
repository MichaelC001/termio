# termio — Landing Page Demo Recording Guide

A complete prep + shot list for the landing-page reel: **1 hero video + 8 GIFs**.

termio's whole pitch is "native Mac terminal that runs *multiple* AI agents in
parallel." A single-agent terminal looks like every other terminal — so the reel
must *show* the parallelism: multiple agents working at once + menu-bar status.

**Decisions locked in:**
- Format: **Both** — MP4/WebM for the landing page, `.gif` exports for
  README / social / email.
- Emphasis: **Parallel agents + tray**, **Git worktree isolation**,
  **Editor + diff**, **iOS companion**.

---

## 1. Prep before you record

**Recording tools**
- **Screen.studio** — best for landing pages (auto-zoom on clicks, smooth
  cursor, exports GIF + MP4). Paid, worth it.
- Free alternative: **QuickTime** (⌘⇧5) to capture + **Gifski** to convert.

**Clean the stage**
- Fresh macOS user or hide desktop icons; neutral dark wallpaper (matches a dark app).
- Fixed window size — record termio at **1280×800** (or 1440×900) so every clip
  crops consistently. Do **not** fullscreen (termio can't be screenshotted in
  fullscreen — it takes its own Space).
- Big cursor + click highlight on (Screen.studio, or macOS Accessibility → Pointer).
- Bump the **terminal font size** 1–2 pts — tiny text is unreadable in a GIF.
- Pre-seed 3 real projects in the sidebar with short, legible names
  (`web`, `api`, `docs`), each on its own worktree branch.
- Keep a scratch file of the exact prompts you'll **paste** — never type live
  (typos + thinking pauses kill the pacing).

**GIF rules** (matter more than people think)
- 3–6 seconds each, **silent, looping**, one idea per GIF.
- Target ≤ 5 MB, ≤ 800px wide, 15–20 fps. Landing pages die on 30 MB GIFs.
- Prefer **MP4/WebM autoplay-muted-loop** on the page; export true `.gif` only
  for README/social. Same visual, ~10× smaller.
- Start on a settled frame, end where it loops cleanly.

---

## 2. Hero demo video (~20s)

**Story: three agents, one glance.** Parallel agents + menu-bar status is what
nothing else does. Caption on-screen (no voiceover — autoplays muted).

| t | Action on screen | On-screen caption |
|---|---|---|
| 0–3s | Welcome page → **New Session** → agent picker → pick **Claude**. | "Spin up an AI agent" |
| 3–6s | Paste a prompt (`refactor the auth module`), hit return, agent starts. | "Give it a task" |
| 6–11s | Create a 2nd session (**Codex** on `api`), a 3rd (**Claude** on `docs`). Sidebar shows 3 sessions, each with its worktree branch. | "Run as many as you want — each on its own git worktree" |
| 11–15s | Zoom to the **menu-bar tray**: dots for working / idle. One flips to **attention**. | "Watch them all from the menu bar" |
| 15–19s | Click the attention session, answer the waiting permission prompt. It flips to **done**. | "Jump in only when they need you" |
| 19–20s | Pull back to the full window: 3 sessions, calm, done. Logo + tagline. | "termio" |

Record each beat as a **separate take**, then cut together. Don't attempt one
continuous run.

---

## 3. GIF shot list (record all 8)

Priority order if time runs short: **1, 2, 3, 4, 8, 5, 6, 7**.

**GIF 1 — Parallel agents (the signature).**
Sidebar with 3 sessions, status dots animating working → done. Just the sidebar,
~4s loop. #1 GIF — communicates the whole thesis without words.

**GIF 2 — Menu-bar tray.**
Crop tight to the menu bar. A dot goes working → attention → click → done. ~4s.
"Monitor without staring."

**GIF 3 — Answer a prompt without switching.**
Agent throws a `[y/n]` / permission card, you click yes, it continues. ~5s.
"You stay in control."

**GIF 4 — Worktree per session.**
New Session → name it → sidebar row appears with a branch label. ~5s. The git
isolation story.

**GIF 5 — Inline file editor.**
Single-click a file in the inspector → syntax-highlighted editor slides over the
terminal → type an edit → auto-saves (Ln/Col footer). ~5s.

**GIF 6 — Git diff viewer.**
Inspector → **Changes** tab → unified diff, green/red. Scroll a little. ~4s.

**GIF 7 — Usage tab.**
Settings → **Usage** → Claude/Codex limit bars. ~3s. Niche but heavy users love it.

**GIF 8 — iOS companion.**
Split frame or over-the-shoulder: phone shows the session list, tap a session →
terminal streams live from the Mac. ~5s. "Check on your agents from anywhere."

### Four-area coverage map

| Area | Clips |
|---|---|
| Parallel agents + tray | Hero video, GIF 1, GIF 2, GIF 3 |
| Git worktree isolation | GIF 4 |
| Editor + diff | GIF 5, GIF 6 |
| iOS companion | GIF 8 |
| (bonus) Usage | GIF 7 |

---

## 4. Export settings (for "Both")

Record each clip **once** at high quality, then export two versions.

**Landing-page version (MP4/WebM):**
- H.264 MP4 + a VP9/AV1 `.webm` fallback, ≤ 1280px wide, 30fps, ~1–3 MB each.
- Embed as:

```html
<video autoplay muted loop playsinline preload="metadata" poster="gif1.jpg">
  <source src="gif1.webm" type="video/webm">
  <source src="gif1.mp4" type="video/mp4">
</video>
```

- Always set a `poster` (first frame as JPG) so the layout doesn't jump before
  the video loads.

**Reusable version (.gif):**

```sh
gifski --fps 18 --width 800 -o gif1.gif gif1.mp4
```

Keep under ~5 MB; if bigger, drop fps to 15 or width to 700.

---

## 5. Pre-flight checklist

1. Fixed window size (1280×800), bumped terminal font, click-highlight on.
2. Pre-seed sidebar: `web` / `api` / `docs`, each on its own worktree branch.
3. Scratch file of the exact prompts to paste — no live typing.
4. **iOS GIF:** pair the phone to the *current* tunnel first. A stale cloudflared
   URL shows "unauthorized" — re-pair to the current QR before recording, or the
   clip fails mid-take.
5. Record every beat as its **own short take** and cut them together — never one
   continuous run.
