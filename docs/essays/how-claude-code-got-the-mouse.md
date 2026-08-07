---
title: "How Claude Code Got the Mouse: Reverse-Engineering the Clickable Terminal"
status: draft
type: essay
created: 2026-08-03
updated: 2026-08-03
description: Claude Code's fullscreen mode quietly gave the terminal a working mouse — click-to-position, clickable menus, hover states, drag selection. A dig through the shipped binary reveals a five-layer architecture that any code agent could adopt.
---

# How Claude Code Got the Mouse

> A reverse-engineering write-up of Claude Code's fullscreen-mode mouse support, aimed at authors of other agent TUIs — this is a playbook worth copying.

Over the spring of 2026 — starting as a hidden env var in v2.1.89 and maturing release by release — Claude Code shipped something that sounds impossible if you grew up on terminals: **you can click**. Click into the middle of a half-typed prompt and the cursor moves there. Click a collapsed tool result and it expands. Click "Yes" on a permission prompt. Hover over things and they respond. Drag to select text *inside the TUI*, and it auto-copies.

Terminals have technically supported mouse reporting since xterm in the 1980s, and full-screen apps like vim and htop use it. But for years no mainstream *AI agent* TUI did — Claude Code, Codex, Gemini CLI, and friends were all keyboard-only line-editor UIs where the mouse belonged to the host terminal. Claude Code's fullscreen renderer (`/tui fullscreen`) changed that (Grok's CLI has since shipped similar interactions), and the implementation is more interesting than "they turned on mouse mode."

The community has noticed, in fragments. A Japanese demo of the mouse working in Claude Code — enabled via the then-undocumented `CLAUDE_CODE_NO_FLICKER=1` — pulled over 200k views back in April. By late July the discussion had turned into tip-sharing and, more tellingly, **demand aimed at the laggards**: Codex CLI users publicly asking its maintainers for click-to-move-cursor ("Claude Code and Grok already have it — don't force me to leave codex"). What nobody has written up is *how it works* — which is exactly what a competing TUI team would need.

So I took apart the shipped binary. This post is what I found, and — more importantly — the checklist other agent TUIs can follow to catch up.

## Method (and its limits)

Claude Code no longer ships readable JavaScript. The npm package now contains a single 256 MB Bun-compiled Mach-O binary with the app baked in as JavaScriptCore bytecode. You can't read the logic — but JSC bytecode keeps its **constant tables**: every identifier, property name, string literal, and telemetry event name survives verbatim, grouped by module. Identifier archaeology on those tables, plus a live probe (spawning `claude` under a pseudo-terminal and capturing the escape sequences it emits), is enough to reconstruct the architecture with high confidence.

Two kinds of claims below: things the binary and the pty *prove* (mode sequences, identifier clusters, feature strings), and mechanisms I'm *inferring* from them. I'll mark the inferences.

## What the probe shows

Spawn `claude` under a bare pty and within a second it emits:

| Sequence | Meaning |
|---|---|
| `CSI ?1049h` | Alternate screen (the fullscreen renderer's canvas) |
| `CSI ?1000h` | Mouse click reporting |
| `CSI ?1002h` | Button-drag reporting |
| `CSI ?1003h` | **Any-motion** reporting — this is what powers hover states |
| `CSI ?1006h` | SGR extended encoding (coordinates beyond column 223, distinct press/release) |
| `CSI ?2004h` | Bracketed paste |

That's the full mouse ladder, including motion tracking — the terminal now streams every movement, click, and wheel tick to the app as escape sequences on stdin. From here on, everything is software.

## The paper trail: a feature that was never announced

Here's the strangest part. Grep the official CHANGELOG for the feature and you find that **"Added mouse support" was never written**. The biggest interaction change a terminal agent has shipped arrived with no headline. Instead, the release notes tell the story sideways, as an archaeology of fix entries:

- **2.1.89** — the birth, disguised as an env var: *"Added `CLAUDE_CODE_NO_FLICKER=1` environment variable to opt into flicker-free alt-screen rendering with virtualized scrollback."* Mouse isn't mentioned; the renderer is the Trojan horse. (The community found it anyway — the most-viewed post about the feature, a 200k-view April demo, teaches exactly this env var, weeks before the `/tui` command existed.)
- **2.1.83–2.1.98** — the mouse leaks into the fix log before ever being announced: *"Fixed mouse tracking escape sequences leaking to shell prompt after exit"*, *"Fixed copy-on-select not firing when you release the mouse outside the terminal window"*, *"Fixed click-to-expand hover text being nearly invisible on light terminal themes"*, *"Fixed a crash in fullscreen mode when hovering over MCP tool results."* Copy-on-select, click-to-expand, and hover all demonstrably exist — none was ever introduced.
- **2.1.110** — the front door appears: *"Added `/tui` command — run `/tui fullscreen` to switch to flicker-free rendering in the same conversation."* Still no mouse in the entry.
- **2.1.132** — the only sentence that ever admits the feature exists, and it's about a banner: *"Updated the `/tui fullscreen` startup banner to describe additional renderer benefits (lower memory usage, mouse support, auto-copy on select)."* The announcement of mouse support is a note that a banner now mentions mouse support.
- **2.1.139–2.1.145** — polish ships feature-by-feature: `/scroll-speed` with live preview; *"Slash command and @-mention suggestion list now supports mouse hover and click."*
- **2.1.187 / 2.1.208** — menus become clickable: *"Added mouse click support to select menus (permission prompts, `/model`, `/config`, etc.)"*, then multi-select menus and "Other" input rows.
- **2.1.195** — the opt-out tells you the scope: *"Added `CLAUDE_CODE_DISABLE_MOUSE_CLICKS` to disable mouse click/drag/hover in fullscreen mode while keeping wheel scroll."*
- And click-to-position — the marquee interaction — **appears in no entry at all**. The only written evidence anywhere is the banner string inside the binary: *"Click to move your cursor in the text input."*

The changelog also corroborates the quirk matrix from the binary, in official words: the xterm.js wheel-speed bug and JetBrains 2025.2 scroll chaos (*"spurious arrow keys, wrong-direction events, runaway acceleration"*, both 2.1.132), WSL2 wheel regressions (2.1.179), Cmd+click fixed separately for Ghostty (2.1.187), Ghostty-over-ssh/tmux (2.1.191), and Warp (2.1.198), copy-on-select printing base64 into GNU screen (2.1.219), and mouse tracking disabled outright on incapable Windows consoles (2.1.172). Roughly forty entries over thirty-ish releases — a drip of compatibility labor, never a launch.

Why ship it this way? Inference, but the shape is familiar: the renderer was the risky bet (an alt-screen rewrite of the whole UI), so it went out as an env var, graduated to a `/tui` toggle, and grew an upsell banner — with telemetry (`fullscreen-upsell`, `fullscreen-downsell`, an exit survey) deciding the pace. The mouse was never the announcement because the mouse was never the product; it's a *property of the new renderer*. You don't announce that a browser supports clicking.

## The architecture, layer by layer

### Layer 1 — Capability and quirk negotiation

The binary contains a small terminal-mode manager (constants `MOUSE_NORMAL`, `MOUSE_BUTTON`, `MOUSE_ANY`, `MOUSE_SGR`, modes `alternateScreen`, `bracketedPaste`, `focusEvents`, `mouseTracking: off | normal | button | any`) — a declarative ladder rather than scattered writes.

What impressed me more is the **quirk matrix** around it. Terminal mouse support in the wild is a minefield, and the identifier list reads like a war journal:

- `fullscreen disabled: tmux -CC (iTerm2 integration mode) detected` and `fullscreen disabled: Windows over SSH (ConPTY re-rendering) detected` — whole configurations where they refuse to enable it.
- `checkedTmuxMouseHint` / `add 'set -g mouse on' to ~/.tmux.conf` — they detect tmux and *coach the user* into passing mouse events through.
- `emitJediTermScrollBug` / `tengu_jediterm_scroll_bug_detected` — a workaround for JetBrains' JediTerm terminal.
- `readVSCodeScrollSensitivity` — they read VS Code's own `terminal.integrated.mouseWheelScrollSensitivity` setting so wheel speed matches the host.
- `Scroll wheel is sending arrow keys` / `scroll-as-arrows` — detecting terminals that translate wheel events into arrow keys and adapting.
- `macCmdClickArrivesWithoutSgrModifierBit` — the SGR encoding has bits for Shift/Alt/Ctrl but macOS Cmd doesn't reliably arrive as one, and Cmd+click-to-open-URL needs special-casing per terminal.

The lesson: **the hard part isn't enabling mouse mode, it's the compatibility program around it.** They ship escape hatches at every granularity — `CLAUDE_CODE_DISABLE_MOUSE`, `CLAUDE_CODE_DISABLE_MOUSE_CLICKS` (keep wheel, drop clicks), `CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL`, `CLAUDE_CODE_NO_FLICKER`, `CLAUDE_CODE_SCROLL_SPEED` — plus telemetry (`tengu_fullscreen_upsell_dialog_accepted`, `fullscreen-downsell`, and an exit survey: "To help us make fullscreen mode better, what made you switch back?") to find out when the bet fails.

### Layer 2 — Input decoding and gesture synthesis

Raw SGR reports (`CSI < button ; x ; y M/m`) are decoded into a gesture stream. The identifier cluster is textbook UI toolkit: `onClickAt`, `onHoverAt`, `onMultiClick`, `onSelectionStart`, `onSelectionDrag`, with `lastClickRow` / `lastClickCol` / `lastClickTime` / `clickCount` / `doubleClickInterval` state behind them.

That state means they synthesize **double- and triple-click** from raw press events, exactly like a GUI toolkit — the terminal gives you only "button 0 pressed at (34, 12)"; word-select and line-select are app-level constructs. Hover (`onHoverAt`, `lastHoverRow/Col`, `setHoveredKey`) rides on the any-motion firehose from mode 1003.

### Layer 3 — The layout registry (hit-testing)

This is the load-bearing layer. A terminal click gives you a *cell coordinate*; the app has to answer "what UI element is at row 12, column 34?" The binary shows a positions registry built during render: `scanElement`, `scanElementSubtree`, `setPositions`, `positions`, `prefixSum`, `screenOrd$`, and the star witness, a property literally named `hitTest`.

Inference, but a confident one: the fullscreen renderer (which is a custom frame-diffing engine — `renderFullFrame`, `blit`, `invalidatePrevFrame`, style/char/hyperlink pools — not stock Ink) records each component's screen rectangle as it paints, and click dispatch walks that registry. It's the same design as a browser's layout tree feeding elementFromPoint. Hyperlinks get their own pool (`getHyperlinkAt`, `openHyperlink`), with a scheme allowlist on dispatch (`refusing to dispatch clicked link with non-allowlisted scheme` — someone thought about `file://` and worse being clickable).

Once you have the registry, the features fall out almost for free:

- **Click-to-position in the input**: hit-test resolves to the editor component, the cell offset maps to a character offset (wide-char aware), cursor moves. The feature string is right there: "Click to move your cursor in the text input."
- **Click-to-expand**: `onItemClick`, `isItemClickable`, `isItemExpanded` — collapsed tool results are just clickable components.
- **Clickable menus**: each option row registers a rect; a click is equivalent to arrowing to it and pressing Enter.

### Layer 4 — Rebuilding selection (the tax)

Here's the cost nobody mentions: the moment you enable mouse reporting, **the host terminal's native text selection stops working** — drags go to the app now. So Claude Code had to rebuild selection inside the TUI: `handleSelectionStart`, `handleSelectionDrag`, `handleMultiClick`, `getSelectedText`, `copySelection`, `setSelectionBgColor`, `subscribeToSelectionChange` — plus feature strings for auto-copy-on-select, column (rectangular) selection, and pointers to "terminal native copy" via modifier+drag as the escape hatch.

This is the part I'd wave in front of every agent-TUI author considering the feature: mouse capture is not additive. You take ownership of selection, and users have fifteen years of muscle memory about how terminal selection behaves. Budget for it.

The complaints on X corroborate this layer almost line by line: users annoyed that auto-copy-on-select keeps clobbering their clipboard, users startled that clicking the terminal "does something now" when they only wanted keyboard focus, one user spending twenty minutes hunting for the disable flag. None of these are bugs — they're the cost of taking ownership of a gesture users thought belonged to the terminal. The opt-out granularity (`CLAUDE_CODE_DISABLE_MOUSE_CLICKS` keeping wheel but dropping clicks) exists precisely because this tax is real.

### Layer 5 — The scroll engine

Fullscreen mode means the app owns scrollback too (the alt screen has none). The binary shows a virtual-scrolling implementation that would look at home in a web app: `virtualScroll`, `scrollToIndex`, `scrollAnchor`, `stickyScroll`, `scrolledOffAbove` / `scrolledOffBelow`, prefix-sum line-height accounting, and a wheel pipeline with acceleration (`wheelMode`, `burst`, `burstCount`, `mult`, `wheel accel`), flood detection (`wheelFlood`), and per-host sensitivity. Rendering only the viewport out of a long transcript is what keeps click latency low — the same reason web apps virtualize lists.

## The playbook for other agent TUIs

This isn't a hypothetical audience. Codex CLI users are asking its maintainers for click-to-position by name; the same requests name-check Claude Code and Grok as the tools that already have it. The demand is public — what's been missing is the implementation map. If you build a code agent TUI and want parity, the shipped evidence suggests this order:

1. **Go alt-screen with a frame-diffing renderer first.** Mouse support rides on owning the whole screen; Claude Code gated it behind fullscreen mode rather than retrofitting the scrolling line-based UI.
2. **Enable the full ladder** — 1000/1002/1006 minimum; add 1003 only when you have hover states to justify the event volume.
3. **Build the layout registry during render.** Every interactive component registers its screen rect; hit-testing is a lookup, not a heuristic. This is the piece that turns "mouse events" into "UI".
4. **Synthesize gestures yourself**: click count, double/triple, drag, hover. The terminal gives you presses; everything else is your toolkit.
5. **Rebuild selection, or don't ship.** Auto-copy-on-select and modifier+drag native passthrough are the minimum to not enrage users.
6. **Carry a quirk matrix**: tmux, ConPTY, JediTerm, VS Code, scroll-as-arrows terminals. Refuse loudly where it can't work, coach where config fixes it.
7. **Ship opt-outs at every granularity and instrument the retreat path.** Claude Code measures who leaves fullscreen mode and asks why.

## Coda

The striking thing isn't any single trick — it's that this is a **GUI toolkit's worth of machinery** (hit-testing, gesture synthesis, hover, selection, virtualized scrolling) built on a byte stream from 1980s escape codes, shipped quietly behind a `/tui` toggle. The terminal's event model was never the limitation; the missing piece was an app willing to treat cells as pixels and build the toolkit above them.

If the TUI has the mouse, the line between "terminal app" and "app" gets very thin. That has consequences for everyone building on this substrate — terminals, multiplexers, and every agent that still thinks the keyboard is the only input device.

*Method note: all identifiers and quoted strings above were extracted from the publicly shipped `@anthropic-ai/claude-code` 2.1.220 npm binary's constant tables; runtime behavior was verified by spawning it under a pty and logging its escape output. Mechanisms not directly observable in bytecode are labeled as inference.*
