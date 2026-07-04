---
name: macos-rebuild-dev
description: "Kill the running termio app, rebuild it with SwiftPM, and relaunch it as a foreground app. Invoke when the user says 'rebuild', 'rebuild app', 'restart app', 'relaunch', '重新编译', or '重启 app'."
---

# Rebuild App (local development)

Kill the running `termio` process, rebuild it **as the `termio.app` bundle**, and
relaunch — so every rebuild also reflects the current Dock icon.

termio is a plain SwiftPM executable (`Package.swift` → `executableTarget` named
`termio`); `swift build` alone produces a bare binary with **no Dock icon**, because
macOS reads the icon from a bundle's `Info.plist` + `Resources/AppIcon.icns`, and a
loose binary has neither. So this skill builds the real bundle via
`scripts/build-app.sh` (which compiles the release binary, wraps it in
`termio.app`, and generates `AppIcon.icns` from `packaging/AppIcon.png`). There is
no codesigning/entitlements/provisioning to worry about — the script ad-hoc signs
and the app runs unsandboxed with `.exec` PTYs (see `CLAUDE.md`).

The icon itself is `packaging/icon-static.svg`, rasterized to
`packaging/AppIcon.png` by `scripts/render-icon.sh` (it uses blur/gradient filters
that need headless Chrome, so plain ImageMagick can't render it).

## Instructions

When invoked, execute these steps sequentially:

1. **Kill the running app** (`-9 -x` catches both the bundle binary and any
   leftover bare `.build` binary — both are named `termio`). SIGKILL skips the
   app's `willTerminate` cleanup, so also reap the companion tunnel it spawned —
   otherwise `cloudflared`/`tunelo` is reparented to launchd and keeps advertising
   a stale URL the phone stays pinned to (the app now also reaps on launch, but
   this stops the orphan lingering between kill and relaunch):
   ```bash
   pkill -9 -x termio || true
   pkill -9 -f "cloudflared tunnel --url http://127.0.0.1:8787" || true
   pkill -9 -f "tunelo port 8787" || true
   ```

2. **Refresh the icon PNG** from the SVG (non-fatal — if the renderer is missing,
   the build just reuses the existing `AppIcon.png`):
   ```bash
   ./scripts/render-icon.sh || echo "icon render skipped (reusing existing AppIcon.png)"
   ```

3. **Build the bundle**. Show the tail of the output; if the build fails, show the
   error and **stop — do NOT relaunch**:
   ```bash
   ./scripts/build-app.sh 2>&1 | tail -12
   ```

4. **Re-register this bundle with LaunchServices, then refresh the Dock cache.**
   This is the step that makes the icon correct: macOS resolves an app's icon by
   its bundle identifier (`com.termio.app`), and if any *other* bundle (an old
   backup, a prior build elsewhere) is registered under the same id, the Dock shows
   *that* app's icon instead. `lsregister -f` forces our path to win; `killall
   Dock` drops the cached icon:
   ```bash
   LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
   "$LSREG" -f "$PWD/termio.app"
   touch ./termio.app
   killall Dock 2>/dev/null || true
   ```

5. **Relaunch via `open`** (NOT `nohup` on the inner binary — that bypasses
   LaunchServices and won't pick up the registration above). `open`'s `--stdout` /
   `--stderr` still capture logs for inspection:
   ```bash
   open ./termio.app --stdout /tmp/termio-dev.log --stderr /tmp/termio-dev.log
   echo "launched ./termio.app (logs: /tmp/termio-dev.log)"
   ```

6. **Report** the result: whether the build succeeded and the app relaunched, or
   what went wrong. If the window doesn't appear, check `/tmp/termio-dev.log`.

## Notes

- This builds **release** (via `build-app.sh`) so the bundle is real; it's a few
  seconds slower than a bare `swift build`. That's the cost of always carrying the
  icon. For a quick code-only iteration without the bundle, run `swift build` and
  launch `"$(swift build --show-bin-path)/termio"` directly — but that has no Dock
  icon.
- A concurrent SwiftPM process (e.g. an editor auto-build) holding the `.build`
  lock can make a build emit spurious errors mid-write; if that happens, just rerun.
- Do NOT modify `Package.swift` or sources during a rebuild.
- After rebuilding a UI change, pair this with the `app-screenshot-debug` skill to
  actually *see* the result.
