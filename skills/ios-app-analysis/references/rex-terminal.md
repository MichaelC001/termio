# Rex investigation and Termio grid correction

This case was observed on October 27, 2026. Rediscover paths, versions, device
IDs, and APIs before repeating it.

## What was inspected

The paired iPhone reported `com.superlogical.rex`, executable `Rex`, version
0.1.0, build 1542, with TestFlight distribution signing. The Mac's device tools
could query its metadata. Pulling the executable at the reported bundle path
through `pymobiledevice3 apps pull` returned `AFC OBJECT_NOT_FOUND`. The iOS
binary was not extracted, decrypted, or decompiled, and its original source
was not recovered.

The accessible reference binary was:

```text
/Applications/Rex Beta.app/Contents/MacOS/Rex
```

Its resources included `swift-ghostty_GhosttyRender.bundle` and a Metal shader
library. Swift metadata and strings exposed `RexSync`, `RexSyncTerminal`,
`RexTerminal`, `GhosttyTerminal`, and `GhosttyVT`. Useful search terms were:

```sh
strings "$rex_app_binary" > /tmp/rex-binary-strings.txt
rg -n 'TerminalReplica|TerminalSizeReporter|TerminalDesiredSize|BlockOwnership|awaitsOutputAfterResize|pendingRepaint' \
  /tmp/rex-binary-strings.txt
```

`TerminalReplica` had size and output-since-resize state; size reporting exposed
accepted and pending values. The binary also contained render-hold/snapshot
state and a message explaining that another client had resized the terminal.
These are evidence for shared machinery, not proof of the exact iOS call graph
or repaint algorithm. Symbol tables may be stripped even when reflection
metadata and strings remain.

## How the Mac server was reached

`rex` was absent from PATH. The running process list revealed its executable
inside the installed server bundle. The observed path was:

```sh
rex_binary="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
"$rex_binary" __internal skill
"$rex_binary" api describe com.superlogical.terminal.resize --json
"$rex_binary" api describe com.superlogical.terminal.size --json
```

Read the installed CLI guide before operating it. Its CLI locates the server;
these queries did not attach a debugger to iOS or establish a new iPhone-to-Mac
connection. If the path changes, locate the running server with
`ps -axo pid,comm` and a targeted `rg` search. Don't restart it to inspect it.

The live API documented these behaviors:

- `resize` applies immediately when the caller owns the block or no client
  owns it; otherwise its requested size waits until it becomes the owner.
- `size` returns the current size, its owner, and each client's last request.
- `session.own_block` and `session.disown_block` claim or release ownership.

Only descriptions were queried. No ownership changes or terminal input were
sent to Rex. The [official API documentation](https://www.superlogical.com/rex/docs/automate/server-api)
explains discovery; the connected server's description is the version-specific
contract. This confirmed the distinction between desired size and applied size
already used in Termio's size-ownership fix.

## The Termio failure and correction

The affected phone used the legacy WebSocket companion, not `vt_stream`.
The server reported a 39-row × 39-column terminal, but the phone's renderer
reported 39 × 38. Keyframes were repeatedly held out and resyncs requested.

Measured geometry was 393 × 749 UIKit points at native scale 3, or
1179 × 2247 pixels. Cells were 29 × 56 pixels. Horizontal padding was configured
as 8 Ghostty points per side; vertical padding was 2.

The pinned Ghostty source used 72 default DPI on macOS and 96 on other targets,
including iOS (`src/font/face.zig`). `Surface.scaledPadding` in
`src/Surface.zig` floored configured padding to pixels:

```text
paddingPixels = floor(configuredPoints × nativeScale × defaultDPI / 72)
paddingViewPoints = paddingPixels / nativeScale

iPhone horizontal padding = floor(8 × 3 × 96 / 72) = 32 pixels per side
actual columns = floor((1179 − 2 × 32) / 29) = 38
old prediction = floor((1179 − 2 × 24) / 29) = 39
```

The correction converted padding before both viewport measurement and explicit
shared-grid layout. Cell measurements used the embedded view's native scale;
the custom stream renderer kept its own UIKit-point padding. The shared grid
retained half-cell slack so rounding could not shorten it by a column.

Regression tests covered the measured phone geometry, macOS padding, and a
fractional content scale. `swift build`, eight grid tests, and the iOS device
build passed. Runtime logs then showed matching server/surface grids at 39 × 39
and 39 × 38 without the captured resync loop. This verifies the dimensional
correction; visual confirmation still requires the phone's screen.

## Follow-up: remote transport and reconnect races

Further inspection of Rex's Mac binary exposed `NIOControlWebSocketTransport`,
`NIODataWebSocketTransport`, `RemoteDataWebSocketConnector`, and
`URLSessionWebSocketConnector`. These identify available transport components;
they do not establish which implementation the installed iOS app selects.
Rex's [remote-access documentation](https://www.superlogical.com/rex/docs/linux/remote-access)
describes HTTP/HTTPS listeners and Tailscale connectivity. Its live
`session.attach` description says attachment returns the current view and starts
session events.

Termio's active legacy path used a roster WebSocket plus a terminal WebSocket.
JSON text frames carried authentication, attachment, and grid controls; binary
frames carried terminal bytes. The direct termiod backend used its own framed
protocol over binary WebSocket messages. Both used `ios/Sources/WebSocketLink.swift`.

Two wrapper bugs were found: an obsolete socket failure cleared the shared
open flag before checking task identity, and a delayed retry checked only
`!isUp`, so it could cancel a newer handshake. The correction tied callbacks
and retries to an attempt identifier, handled send failures through the same
reconnect path, and rejected events after stop or failure.

A local test compiled the before/after WebSocket wrapper against macOS
Foundation, with only the UIKit foreground-notification symbol substituted.
The test server closed the first connection and delayed the replacement
handshake by one second. A manual retry arrived before the old backoff expired.
The original wrapper dialed three times; the corrected wrapper dialed twice
and remained connected. This exercised actual WebSocket traffic, but was not
an iPhone network-handoff measurement.

The legacy output path also reused the existing pending-data buffer to batch
main-queue bookkeeping, while feeding renderer bytes immediately. A synthetic
10,000-chunk burst scheduled one UI drain and preserved every byte, including
fragmented UTF-8 and escape sequences. Identical viewport/visibility reports
were suppressed; explicit reconnect and foreground reassertions remained.

The Swift build, 12 grid/attempt-state tests, and iOS device build passed. The
installed app opened roster and terminal connections without a drop during an
18-second capture, and its server/surface grid remained 39 × 38. No scrolling
frame-rate or wide-area latency improvement was measured.
