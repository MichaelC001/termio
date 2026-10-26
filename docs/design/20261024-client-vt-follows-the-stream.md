---
title: The client VT follows the stream
status: draft
type: design
created: 2026-10-24
updated: 2026-10-25
related:
  - 20260730-termiod-session-protocol.md
  - 20260901-pty-size-is-not-the-write-token.md
  - 20260902-superlogical-server-memory-parking.md
---

# The client VT follows the stream

> Move termio's client terminal to Rex's architecture: the client owns a
> libghostty-vt terminal, its size changes only at a marker in the byte stream,
> and every attach decodes a snapshot into a fresh terminal.

## Why

Every client must parse at the PTY's authoritative size (§C.5 of the session
protocol). termio meets that requirement with timing, not with structure:

- The daemon's resize is a **barrier**. It buffers each client's `D` frames,
  sends a full-screen keyframe, then releases the buffer.
- The client's VT belongs to ghostty's embedded surface, and its size comes from
  the view's pixels: `ghostty_surface_set_size` → IO-thread mailbox → a 25 ms
  coalesce → `terminal.resize`. Bytes enter on another path,
  `ghostty_surface_write_buffer`, which parses at once. Nothing orders the two.
- `TerminalKeyframeHold` bridges the gap with guesses: a 30 ms wait, a 250 ms
  deadline, a 1.75 s grace for a surface that never reports, a 500 ms backstop,
  a 400 ms declaration debounce and a 150 ms drag throttle.

Each guess has a failure mode, and each fix adds a state. #755 fixed input boxes
scrambled after an app update. It needed three review rounds and four extra
states. A session that was not selected at relaunch still reads 15 rows for a
few seconds after it is shown.

Rex (Superlogical) has none of this machinery. Its ordering comes from structure.

## What Rex does

This section records what the shipped binaries show. Evidence was gathered on
2026-10-24 from `Rex Beta.app` build 1408 and its server. **Observed** means read
in the binary; **inferred** means not traced to the end.

| Claim | Evidence | Level |
|---|---|---|
| The client uses libghostty-vt, not ghostty's embedded surface | 0 `ghostty_surface_*` / `ghostty_app_*` / `GHOSTTY_ACTION_*` strings (termio's binary has 6). The embedded `abi.json` is libghostty-vt's own type export (`src/terminal/c/types.zig`) | observed |
| It is upstream libghostty-vt, not a fork | All 187 ABI types appear in upstream ghostty history. Its terminfo names upstream commit `36ec90a07`. Several types it uses landed upstream on 2026-10-21 (`GhosttyTerminalWriteStop`, snapshot Kitty data) | observed |
| The client renders with its own Metal renderer | `swift-ghostty_GhosttyRender.bundle/default.metallib` (`cell_bg_fragment`, `text_vertex`, `image_vertex`, …); types `GlyphCache`, `GlyphAtlasTextures`, `CellFontSet`, `ImageStore`, `CursorPlan`. `swift-ghostty` is Superlogical's package and is not public | observed |
| The client splits the stream at `ESC _ rex1;` | `FUN_100f4a7ac` scans with `memchr(…, 0x1b, …)` against a 7-byte literal `1b 5f 72 65 78 31 3b` and the terminator `1b 5c` | observed |
| The control is applied in place, between the bytes before and after it | The splitter is synchronous. Bytes before the marker go to the sink first, then the control handler `FUN_100f4bd08` runs, then the rest | observed |
| A resize control resizes the client VT | `FUN_100f4bd08` takes the resize branch (enum tag 0, two packed `UInt16`) after flushing pending bytes. The call into libghostty is indirect and was not traced | inferred |
| Attach decodes a snapshot into a fresh terminal | upstream `ghostty_snapshot_decoder_decode` returns a new terminal through an out parameter (`snapshot.h:781`); Rex's `SnapshotDecoder` holds `decodedTerminal: GhosttyVT.Terminal?` | observed |
| The view does not resize the VT for server blocks | `automaticallyResizesTerminal` and `onGridSizeChange` exist on the render view and surface. The value Rex sets was not found | inferred |
| Server order: wait for ground → VT resize → `TIOCSWINSZ` → APC in the stream | Go pclntab: `scheduleGroundMutationsLocked` calls `VTGround`; `term.(*Terminal).Resize` calls `libghostty.(*Terminal).Resize`, then `pty.resize`; `applyGroundMutationsLocked` calls `enqueueEncodableLocked` after the mutation | observed |

| Input reaches the server as structured events, not bytes | The server's API text: "A client may send only `key`, `paste`, `mouse`, `wheel`, and `focus` events." A key carries `mods`, `consumed_mods`, `composing` and the unshifted key; a mouse event carries the cell, the pixel and the buttons held; a wheel carries `delta_x`, `delta_y` and `delta_mode` | observed |
| The server encodes input with libghostty against its own VT | cgo stubs `_Cfunc_ghostty_key_encoder_encode`, `_Cfunc_ghostty_key_encoder_setopt_from_terminal`, `_Cfunc_ghostty_mouse_encoder_encode`, `_Cfunc_ghostty_focus_encode`, `_Cfunc_ghostty_go_terminal_paste`; Go methods `libghostty.(*KeyEncoder).Encode`, `(*MouseEncoder).Encode`, `FocusEncode`, `PasteEncode` | observed |
| The server's VT answers the program's queries | cgo exports `goWritePtyTrampoline`, `goDeviceAttributesTrampoline`, `goXtversionTrampoline`, `goColorSchemeTrampoline` | observed |
| The client also links libghostty's encoders | Swift types `GhosttyVT.KeyEncoder` and `GhosttyVT.MouseEncoder` are present. What the client uses them for was not traced | observed |

Rex's own protocol document states the contract: "Program bytes before it were
written at the old size, and bytes after it at the new size."

## The design

### Daemon

The session actor already serialises both halves. `fan_out` of PTY bytes and
`apply_size_policy` run on the same task, and `Data` and `Event` share each
client's ordered `out` channel. The sidecar already receives `Resize` in its FIFO
before the ioctl that raises SIGWINCH.

1. A client that negotiates a new capability, `vt_stream`, gets no resize
   barrier. It receives `E resized {rows, cols, mode}` at the exact position in
   its stream where the PTY changed size, with no keyframe.
2. `mode` is the operation the sidecar applied: `reflow`, `truncate`, or
   `shell` (`resize_for_shell`: clear from the prompt row down, then reflow).
   The client applies the identical operation.
3. The attach snapshot for a `vt_stream` client is libghostty's native
   snapshot (`ghostty_snapshot_encode`), not VT bytes rendered by
   `TermioSnapshot.render`. It carries modes, the Kitty keyboard stack, scroll
   region, charsets, both screens, scrollback and the unfinished parser input.
4. Resize stays a ground-state mutation: the marker is placed only where the
   sidecar parser is in the ground state, so it never lands inside an escape
   sequence.
5. Clients without `vt_stream` keep today's barrier and keyframes.
6. Input from a `vt_stream` client arrives as `E` events, as Rex's does:
   `key`, `paste`, `mouse`, `wheel` and `focus`. The daemon encodes each one
   with libghostty's encoders against the modes of its own VT, then writes the
   bytes to the PTY on the path `D` input takes, with the same write-token
   rule. `D` stays for text that is typed verbatim (`termio sessions send`).
7. Encoding never waits for the parse. After each batch the sidecar parses, it
   copies the terminal's modes into the encoders (`setopt_from_terminal`), and
   the session actor encodes with them as they are. A Ctrl-C sent during a
   flood is encoded at once, against the modes of the last byte parsed, not
   queued behind the backlog.

The anti-100× invariant is unchanged. The daemon still delivers bytes without
waiting on the sidecar parse; only the marker's position is new.

### Client (Mac first, then iOS)

1. A new terminal stack replaces the embedded surface for termiod sessions: a
   libghostty-vt terminal plus termio's own renderer, as Rex does.
2. One reader thread owns the terminal. It writes `D` bytes with `vt_write`
   and, on `E resized`, calls `ghostty_terminal_resize` before the next byte.
   The VT size has no other writer.
3. The view never resizes the VT. A view larger than the grid shows blank space
   to the right and bottom; a smaller one clips. The view reports the grid it
   could hold, and that report is the viewport declaration the §12 size policy
   already consumes.
4. Attach decodes the snapshot into a new terminal and swaps it in. Nothing is
   reset in place.
5. Input goes to the daemon as events (daemon item 6). The client turns an
   `NSEvent` into a key event, runs the input method and draws its preedit,
   and keeps Ghostty's macOS editing bindings (⌘←, ⌥← and the rest), which
   send fixed bytes. It does not encode: its terminal is one round trip behind
   the program, so a key encoded against it uses modes the program may already
   have changed.

### What gets deleted

`TerminalKeyframeHold` and every timer listed under *Why*; `noteSurfaceGrid` and
the surface-report plumbing; the letterbox's half-cell slack;
`TermioSnapshot.render` for `vt_stream` clients; the resize barrier for
`vt_stream` clients; the settle nudge, if parity tests show the in-band reflow
leaves nothing for it to repair.

### What stays

The sidecar VT, the `execve` handoff, the §12 size policy and the write token.
Rex's size owner rule is not adopted: it hands the size away when the owner's
connection drops, which is the phone-lock reflow §12 removed.

## The renderer is the cost

libghostty-vt provides the terminal, a render state with dirty rows, snapshots,
key and mouse encoders, selection gestures, search, a formatter and Kitty image
placements. It does not provide font shaping or GPU drawing. Rex wrote those as
`GhosttyRender`, and that package is not public.

termio's embedded surface gives all of the following today, and the new stack
must reach parity before it can be the default:

- text: CoreText shaping, ligatures, wide and combining characters, emoji,
  bold and italic faces, the font-size shortcuts;
- cursor styles and blinking, selection and copy;
- IME preedit and its candidate-window position;
- mouse reporting, scroll and the alternate-scroll mode;
- links: hover detection, ⌘-click, path clicks inside mouse-capturing TUIs;
- the actions termio consumes today: title, PWD, progress (OSC 9;4), bell,
  desktop notifications, command finished, clipboard read and write;
- Kitty graphics;
- themes and the dark/light switch.

## Phases

Each phase ends at a gate. A failed gate stops the work.

0. **Engine bump.** Move both forks to a ghostty at or after 2026-10-21, so the
   client and the daemon get `vt_write_until`, snapshot Kitty data and the
   current render-state API. Follow the three-repo bump procedure. Gate: the
   existing test suites pass.
   **Done 2026-10-25 (#761):** ghostty cec8b92 everywhere. ghostty needs Zig
   0.17 since 2026-10-20, and stock Zig 0.17 cannot build iOS without
   ghostty's own patch to its std, which libghostty-swift CI now applies.
1. **Renderer spike.** A test window that decodes a snapshot taken by termiod
   and draws it, then streams `cat` of a large file. Gate: frame time and
   throughput within 20% of the embedded surface on the same machine.
   **Passed 2026-10-25** (branch `spike/vt-renderer`, numbers in its README).
   Throughput while rendering, median of 5: 276 vs 201 MB/s on a scrolling
   log, 769 vs 581 MB/s on full-screen redraws. Frame CPU p99 1.2–1.9 ms. The
   spike draws less than a real renderer (no shaping, decorations, colour
   emoji or render hold), so these are a ceiling, not a forecast. One finding
   carries into phase 3: NSLock let a writer looping over chunks starve the
   renderer for up to 34 ms, so the writer must yield when the renderer is
   waiting. libghostty-vt for Swift is one upstream command,
   `zig build -Demit-lib-vt`, which emits an xcframework for macOS and iOS.
2. **Daemon `vt_stream`.** Capability, in-place `E resized` with `mode`, native
   snapshot on attach. Gate: a parity test feeds one recorded PTY stream with
   resizes to the sidecar and to a second libghostty-vt terminal that applies
   the markers; the two screens must be byte-identical after every marker.
3. **Mac client stack behind a setting.** Gate: the parity list above, plus the
   relaunch and resize harnesses used for #755 (app VT against termiod's VT).
   Milestones:
   - M0, libghostty-swift 1.2.0 ships `GhosttyVt` beside GhosttyKit. **Done (#13).**
   - M1, the client terminal and a parity fixture written by termiod. **Done (#769).**
   - M2, the Metal renderer and the stream view, behind `TermioStreamTerminal`. **Done (#771).**
   - M3, input as events that termiod encodes (daemon items 6 and 7); IME
     preedit; `termio sessions send` and `read` on a stream pane. **Done (#782).**
   - M4a, what the program tells the terminal that the app acts on: the
     title, the working directory, the bell, desktop notifications, and OSC 52
     clipboard writes and reads.
   - M4b, selection and copy, the scrollback view and Ghostty's scrolling
     keys. Search is not part of it: the embedded surface offers no ⌘F in
     termio today, so there is nothing to match yet.
   - M4c, links: OSC 8 hyperlinks, detected URLs and paths, hover and ⌘-click.
   - M4d, Kitty images. Both VTs must take an image the same way, or the
     cursor diverges after it: same cell size (8 by 16), same storage limit,
     the same media (direct only; file, temp file and shared memory are off
     on both). Raw RGB and RGBA ship first, because both engines decode them
     alike. PNG follows once termiod decodes PNG too: a PNG only the client
     can decode moves only the client's cursor. The parity fixture places an
     image, so a client that diverges here fails the test. An image is drawn
     over the cells the VT gave it, scaled per axis from 8 by 16 to the
     font's cell: a font whose cell is not 1:2 stretches it slightly, the
     price of one layout for every client of a session. **Raw done (#791).**
     PNG: the `png` crate and ImageIO are lenient about different damage, so
     neither decides. One rule, written the same in Rust and Swift, accepts a
     PNG and gives its size: the signature, IHDR first, every chunk whole
     with its CRC up to an empty IEND, and at most 10 MB decoded. Pixels a
     library then cannot decode are stored as zeros at that size, so only
     pixels can differ, never the cursor. The fixture covers each refusal.

   Rex's server sends the title, PWD, bell, notifications, progress and OSC 52
   to clients as events, because its consumers include clients that do not
   render. termio takes them from the stream pane's own terminal instead: it
   parses the same bytes in the same order as the daemon's, so its callbacks
   fire at the same byte, and the daemon already derives on its own what a
   client without a screen needs (the status engine). Selection follows the
   Mac client, not the server: Rex's server keeps a selection for clients
   that forward the mouse and reports only `selection_copied`, which carries
   no selection to draw, and its Mac client links libghostty's selection
   gestures.
   - M5, the gate.
4. **Default on the Mac.** Delete the hold machinery.
5. **The daemon answers queries.** As Rex's server does, the daemon's VT
   replies to device attributes, cursor and size reports, XTVERSION and the
   color-scheme query, and no client answers any more. A session then gets
   its answers with no window open. The color replies need each client's
   theme, which the client sends to the daemon. Gate: the
   `TerminalDeviceReport` cases pass against the daemon alone.

   Mechanism. A client that negotiates `vt_answers` answers no query while it
   writes, and sends an `answers` event: its XTVERSION name (the daemon's
   engine reports its own crate version, not Ghostty's), its theme, and
   whether that theme is dark. The daemon's VT answers while the writer
   negotiated `vt_answers` or nobody writes, never for the replay of a
   previous image's output, and never once it is stale, when `vt_stale` hands
   answering back to the writer. A writer without `vt_answers` answers for
   itself, so a program never reads one answer twice. The answers are the
   embedded surface's: Ghostty's DA1 and DA2, size reports in 8 by 16 cells,
   the writer's colors and scheme. XTGETTCAP is not answered on either side
   of the stream yet: libghostty-vt carries no terminfo table.
   **Daemon done:** a session with no window open is answered DA1, DA2 and a
   cursor report (`termiod/tests/vt_answers.rs`). The Mac client follows.
6. **iOS.** The phone's mirror is a live surface fed through the companion
   bridge, so the marker must cross the bridge in order.
7. **Resume by byte offset**, as Rex's `RESUME` does: a reconnect continues the
   stream with no snapshot.

## Risks

- **Renderer parity is the largest risk.** It is a full terminal renderer for
  two platforms. Phase 1's gate exists to fail early.
- libghostty's C API is unversioned and still moving; snapshot format version 1
  has no compatibility promise. The daemon and the clients already pin one
  engine together, which holds as long as that rule does.
- Client and daemon apply resizes with different cell pixel sizes (termiod_vt
  uses 8×16). Anything that depends on pixel size, such as Kitty placements and
  size reports, must be checked by the parity test.
- Both the client and the daemon can answer terminal queries. Today only the
  writer's surface answers (`TerminalDeviceReport`); the new client keeps that
  rule until phase 5 moves the answers to the daemon.
- Each attach decodes a fresh terminal from termiod's snapshot, which holds
  termiod's own scrollback (about a thousand lines). A reconnect, a wake from
  sleep or a handoff therefore drops older history the pane had kept, where the
  embedded surface keeps it. Phase 7's resume by byte offset removes this.
- A remote daemon and the app can run different releases for a while, so input
  events name keys by Ghostty's key names (`arrow_up`), never by the C enum's
  numbers.

## Open questions

- Whether Rex sets `automaticallyResizesTerminal = false` for server blocks was
  not found. The design does not depend on it.
- How a grid larger than the view should look: clip, scale, or follow the
  cursor.
- Whether `swift-ghostty` will be published. If it is, phases 1 and 3 shrink to
  an adoption.
