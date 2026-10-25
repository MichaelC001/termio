# termio-sim

The helper process behind the Simulator pane and `termio sim`. It holds Apple's
private simulator frameworks so that a crash or a hang inside them costs a respawn,
not the app.

## Upstream

It links the simulator libraries of [idb](https://github.com/facebook/idb)
(FBSimulatorControl, FBSimulatorAX, FBSimulatorServices and their support
libraries), MIT, Copyright (c) Meta Platforms, Inc. and affiliates. `build.sh` pins
the commit, builds idb from source once per commit into
`~/Library/Caches/termio/idb/<commit>`, and ships idb's `LICENSE` beside the helper
as `Simulator/LICENSE-idb`. `Sources/Keymap.swift` is adapted from idb's SimScope;
its header lists the deviation.

Moving the pin is the usual fix when a new Xcode breaks input or display: idb tracks
CoreSimulator's private API per Xcode release.

## Shape

- `termio-sim --service <name> --resources <dir>`, spawned by `SimulatorHost`.
- Requests and replies: one JSON object per line over stdio (`Sources/Wire.swift`).
- Display: each IOSurface is sent as a Mach send right to the service the app
  checked in (`Sources/SurfacePort.swift`); a `frame` event per presented frame
  tells the app to re-present it.
- `Simulator/SimulatorFrameworkBridge-iOS` is idb's in-simulator guest for
  accessibility reads. Re-signed with the hardened runtime it needs
  `bridge.entitlements`, or it aborts on launch inside the simulator.

Apple silicon and macOS 15 only, because idb builds for nothing else.
