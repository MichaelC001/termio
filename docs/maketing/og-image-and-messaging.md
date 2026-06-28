---
title: OG image & landing copy
status: draft
type: marketing
updated: 2026-06-28
---

# OG image & landing copy — working notes

Status: **draft / unresolved**. The OG image is rendered and wired up; the
*headline copy* is still being decided. This doc captures the problem, what we
tried, why, and how to regenerate — so the next session can pick it up without
re-deriving anything.

---

## 1. What we're building

A social-share / Open Graph image for the termio landing site (`web/landing`),
plus the headline copy that goes on it (and, by extension, the site H1).

- Output: `web/landing/public/og.webp` — **2400×1260** (1.91:1, same as unpeel's).
- Wired in `web/landing/src/app/layout.tsx` → `metadata.openGraph.images` and
  `metadata.twitter.images` (card = `summary_large_image`). `metadataBase` is
  `https://termio.app`, so the relative `/og.webp` resolves to absolute.
- Format: **WebP, quality 86**. ~115 KB. (A PNG of the same image was ~1.9 MB —
  15× bigger — so we don't ship PNG.)

### Layout (locked, looks good)
- Dark mesh-gradient background using termio's hero palette
  (`#0c1538 → #2a5bc4 → #5f82e0 → #9b8fd4 → #cbb4d3`).
- Left column: logo mark + "Termio" wordmark, headline, subhead.
- Right: the app-window screenshot, **fully framed** (not bleeding off-edge),
  rounded corners + soft drop shadow, floating on the gradient.
- The screenshot is the Claude-Code-session capture the user supplied.

The **layout is settled**. The open question is purely the **words**.

---

## 2. Reference: unpeel.com (what "real" copy looks like)

termio is modeled on unpeel.com. Their OG is a static `og.webp` at 2400×1260:
app window (agent sessions sidebar + live Claude Code terminal) on a dark bg.

Their voice = **calm, declarative, concrete product-truth**. Short statements,
periods, no hype. Verbatim samples worth imitating *in spirit* (not word-for-word):

- Hero: "A native macOS terminal app for AI agents." / "Native Swift, powered by libghostty."
- "All your agents in one place"
- "Terminals that never die." — *"Sessions run outside the app. Quit it, crash
  it, relaunch it, and your agents are still working."*
- "See everything at a glance." — *"Which agents are busy, which are done, which
  need your answer."*
- "Parallel agents, one repo." — *"Built-in git worktrees let multiple agents
  work the same project without stepping on each other."*
- Why: "The future of AI-assisted work isn't one model or one harness. It's
  many, working together."

**Lesson:** their copy describes *actual behavior you can picture*. That's the bar.

⚠️ Don't lift their signature line "All your agents in one place" verbatim —
termio already reads as an unpeel clone; copying their headline word-for-word
makes that worse. Borrow the *concept* ("one place"), not the phrase. Note our
own headline already expresses it more concretely with a real noun ("terminal").

---

## 3. The copy iterations (and why each was rejected)

The user's stated intent (zh): *所有 project 的 agent 都在同一个 terminal 里;
一个人在一个空间里驾驭 agent,完成多个项目和任务* — i.e. **one person commands
many agents across many projects from a single place.**

| # | Headline | Verdict |
|---|----------|---------|
| 1 | Run every agent. Lose nothing. | Punchy but **vague** — "lose nothing" doesn't say *what's* at stake. |
| 2 | Every agent. Every project. One terminal. | Clean parallel, but it's a **mad-lib template** (Every X. Every Y. One Z.) — reads generated. |
| 3 | Every agent. Every project. One Termio. | **Worse.** "One Termio" is brand-noise, not a claim. User pushback: *"你的文案要有真实感，你现在写的是什么东西？"* |
| 4 (current) | **Claude Code, Codex, Gemini — all at once.** | **Grounded.** Names real agents (match the screenshot sidebar), the subhead states verifiable mechanisms. |

### The principle the user is enforcing: 真实感 (concreteness)
Copy must be **specific and verifiable**, not abstract parallelism. Name real
tools, describe real behavior the product actually does. If a reader can't
picture it or it could describe any product, it's fluff. This killed the
"Every X. Every Y. One Z." template outright.

### Current copy (rendered, not final)
> **Claude Code, Codex, Gemini — all at once.**
> Every coding agent in one native Mac app. Each in its own git worktree, still
> working after you quit.

Why it's more real:
- Headline names the actual agents shown in the screenshot → text & image confirm
  each other.
- Subhead = real mechanisms: per-agent **git worktree** (parallel, no collisions)
  + **sessions survive quit** (processes outside the app).
- Drops the template.

---

## 4. Open decisions (for the next pass)

1. **Headline direction.** Is "Claude Code, Codex, Gemini — all at once." the
   keeper, or do we want one leading with a different real truth? Candidates,
   all grounded:
   - Durability hook: *"Quit the app. Your agents keep coding."*
   - Parallelism/repo: *"Many agents, one repo, no collisions."*
   - Solo-leverage (the user's core intent): *"One person, every project,
     all your agents at once."* — risk: drifts back toward abstract.
2. **Gemini vs OpenCode.** Screenshot sidebar shows **OpenCode**, headline says
   **Gemini**. For exact text↔image match, swap to "…Codex, OpenCode — all at
   once." Pending user call.
3. **Sync the site H1.** Landing H1 in `web/landing/src/components/sections/hero.tsx`
   is still "Run every agent. Lose nothing." — diverges from the OG. Once the
   headline is locked, update the H1 to match (brand consistency).
4. **Subhead wording.** Could fold the brand in ("…inside Termio") or the "one
   space" concept ("…in one space") if we want it more explicit.

---

## 5. How to regenerate the OG (reproducible recipe)

Tooling: **ImageMagick** (`magick`, installed via Homebrew). Fonts:
`/System/Library/Fonts/Supplemental/Arial Bold.ttf` (headline/wordmark),
`/System/Library/Fonts/SFNS.ttf` (subhead). Source screenshot is the
user-supplied Claude-Code capture (2000×1440).

Pipeline (see chat history for the exact one-shot script):
1. **Background** — `magick -size 2400x1260 xc:black -sparse-color shepards
   '<5 palette points>' -blur 0x18 bg.png` (mesh gradient from hero palette).
2. **Window** — resize screenshot to ~1194×860, round corners (radius 40) via a
   `roundrectangle` alpha mask + `-compose DstIn`, add a hairline white border.
3. **Shadow** — extract window alpha, pad + blur (`0x48`), multiply alpha ~0.5,
   composite under the window.
4. **Compose** — bg + shadow + window (window at ~+1070+200, fully framed).
   Save as text-free `stage.png` (reuse this when only the copy changes).
5. **Text** — `-annotate` the logo mark, "Termio" wordmark, headline (~84–96 pt),
   subhead (~35 pt) onto `stage.png`.
6. **Export** — `magick og.png -quality 86 -define webp:method=6
   public/og.webp`; delete the PNG.

> Tip: to iterate on **copy only**, keep `stage.png` and just re-run step 5 → 6.
> Don't rebuild the gradient/window each time.

The metadata wiring in `layout.tsx` doesn't change when the image changes (same
filename), so copy iterations are image-only.

---

## 6. Decisions still owned by the user
- Final headline + subhead wording.
- Gemini vs OpenCode in the headline.
- Whether to sync the landing H1 to the chosen headline.

Everything here is working-tree only; nothing committed (per repo git convention).
