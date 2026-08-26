import Foundation
import TermioShared
import os

extension TermioStore {
    /// Probe-level trace for the stall detector, readable via
    /// `log stream --predicate 'category == "stall-detection"' --level info`.
    /// The thresholds ship untuned against real fleets (design doc §4.7 keeps
    /// `stalled` out of the default watch filter for exactly that reason), and
    /// this is the evidence stream tuning needs: which windows slid on output
    /// volume, and what each probe measured when one fired or held.
    private static let stallTrace = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.termio.app", category: "stall-detection")
    /// Brings up the hook socket and aligns `~/.claude/settings.json` with the
    /// current setting. The listener always runs (it is harmless when no hooks are
    /// installed); only the settings-file side is toggled.
    /// Starts the status upkeep this app still owns.
    ///
    /// It no longer *receives* status. Every hook reports to the daemon that
    /// owns its PTY, and the app reads `E status` off the session's own channel
    /// (`applyTermiodStatus`) — one path, whichever machine the agent runs on.
    ///
    /// What stays here is the half that reads a **screen**, because that is the
    /// half a daemon cannot do for a local session: the stale-working sweep
    /// below, the streak promotion, and the `OSC 0/2` title classification. For
    /// a device the authoritative VT is the daemon's; for this Mac it is the
    /// app's own surface. They are the only status signal an agent with no hook
    /// system has, so they are not leftovers to tidy away — they stay until the
    /// VT itself moves (docs/design/20260819-unify-server-plane.md). Deleting
    /// them would silently take that fallback with them.
    func startHookMonitoring() {
        installedHooksEnabled = settings.agentHooksEnabled
        syncHooksInstallation()

        // The timeout it enforces is a handful of seconds (a quiet terminal is the
        // "turn ended" signal), so the sweep has to tick at that granularity to
        // clear a stuck spinner promptly. A 2s repeating timer is negligible.
        staleWorkingSweep = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sweepStaleWorking()
                self?.sweepStalledSessions()
            }
        }
    }

    /// Whether any session is an agent (declared or detected via `effectiveAgent`). Gates
    /// the "status is off" reminder — a shell-only workspace has nothing to report.
    var isRunningAnyAgent: Bool {
        allSessions.contains { effectiveAgent(for: $0) != .terminal }
    }

    /// Re-aligns the installed hooks when, and only when, the hooks setting itself
    /// changed. Called from the shared settings observer, which fires for every
    /// preference, so the guard keeps unrelated changes from rewriting the file.
    func syncHooksInstallationIfNeeded() {
        guard installedHooksEnabled != settings.agentHooksEnabled else { return }
        installedHooksEnabled = settings.agentHooksEnabled
        syncHooksInstallation()
    }

    private func syncHooksInstallation() {
        syncAgentIntegration()
    }

    /// Brings up the control socket and aligns the agents' awareness note with the
    /// current setting. Like the hook listener, the socket always runs; only the
    /// note written into the agent instruction files is toggled.
    func startSessionControl() {
        let control = SessionControlListener(
            onRequest: { [weak self] request in
                await self?.handleSessionControl(request) ?? Data()
            },
            onWatch: { [weak self] request in
                self?.resolveWatchScope(request) ?? (nil, nil, [])
            })
        control.start()
        sessionControl = control
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    func syncSessionControlInstallationIfNeeded() {
        guard installedSessionControlEnabled != settings.sessionControlEnabled else { return }
        installedSessionControlEnabled = settings.sessionControlEnabled
        syncSessionControlInstallation()
    }

    private func syncSessionControlInstallation() {
        syncAgentIntegration()
    }

    /// Asks the local daemon to align this Mac's agent config with the two
    /// Integration switches.
    ///
    /// Both switches go in one message: the daemon writes hooks and the skill in
    /// one pass, and sending two would install twice for no reason. Fire and
    /// forget — this runs on launch, on a preference change, and on refocus, and
    /// none of those has a place to show a failure, so a failure is logged (by
    /// `AgentIntegrationInstaller`) and the previous state is left alone. The
    /// place that *does* report is Settings, where the user asked.
    func syncAgentIntegration() {
        let hooks: Termiod.AgentHalfAction =
            settings.agentHooksEnabled ? .install : .remove
        let skills: Termiod.AgentHalfAction =
            settings.sessionControlEnabled ? .install : .remove
        Task { _ = await AgentIntegrationInstaller.sync(hooks: hooks, skills: skills) }
    }

    /// Records only the first usable prompt label in a conversation. It stays a
    /// fallback: `displayTitle` gives an explicit Termio name and a meaningful native
    /// OSC title higher priority. Persisting it on `Session` keeps resumed tabs named
    /// before the agent emits any fresh terminal title.
    func recordPromptTitle(_ raw: String, for id: Session.ID) {
        guard let session = session(id),
              session.promptTitle == nil,
              session.agent != .terminal,
              session.givenTitle == nil,
              let title = AgentPromptTitle.normalized(raw)
        else { return }
        updateSession(id) { $0.promptTitle = title }
    }

    /// A reported conversation id, accepted only when it is a bare token — the ids
    /// every agent mints (UUIDs, `ses_…`) always are. The shell-hook path mines the
    /// value out of an arbitrary stdin blob, so anything else (pasted JSON, a path,
    /// whitespace) is treated as no identity rather than adopted into the pin.
    func conversationToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 128,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }
        return raw
    }

    /// Not private: the termiod status path (`applyTermiodStatus`) ends a turn
    /// through the same door, so the two cannot drift on what "stopped working"
    /// clears.
    func clearWorking(_ id: Session.ID) {
        setCurrentTool(nil, for: id)
        lastWorkingAt[id] = nil
        promotionStreak[id] = nil
    }

    /// Drops every per-session activity-tracking entry — the one place that
    /// enumerates these dictionaries, so the teardown paths (close, project
    /// removal, relaunch) can't drift out of step when a new tracker is added.
    /// `transcriptPaths` is deliberately not here: a relaunch resumes the same
    /// conversation, so only the close/remove paths clear it (inline).
    func clearActivityTracking(for id: Session.ID) {
        // Whatever banner the session had delivered no longer describes a live turn.
        TaskNotificationCenter.shared.forget(id)
        lastWorkingAt[id] = nil
        lastHookReportAt[id] = nil
        lastUserInputAt[id] = nil
        promotionStreak[id] = nil
        lastTitleActivity[id] = nil
        lastProgressActivity[id] = nil
        lastScreenActivity[id] = nil
        stallProbes[id] = nil
        blockingAttention.remove(id)
    }

    /// Light the "blocked on you" dot from a genuine, observable blocking condition
    /// (a hook / screen / title "attention" signal). Unlike a one-shot bell, these
    /// have a matching "resolved" transition, so the dot is recorded as blocking
    /// (`blockingAttention`) and survives a click in `markSeen` — looking at a
    /// permission prompt isn't answering it. Only flags a session the user isn't
    /// already watching, mirroring the raw `!isViewing` guard it replaces; the flag
    /// is still set even when the status write is a no-op, so a bell-set dot already
    /// showing gets *upgraded* to blocking when the real signal arrives.
    func flagBlockingAttention(for id: Session.ID) {
        guard !isViewing(id) else { return }
        blockingAttention.insert(id)
        setStatus(.needsAttention, for: id)
    }

    /// Marks the moment of live user input into a session's terminal. Keystroke
    /// echo and mouse-mode scrolling repaint the screen exactly like agent
    /// output, so promotion holds off while the human is the one causing the
    /// changes. Fed each status poke from `PTYProcess.lastInputAt` — the choke
    /// point every input path crosses (Mac surface, phone companion bridge,
    /// synthetic `sessions send`) — hence the monotonic guard: a poke can only
    /// carry the timestamp forward.
    func noteUserInput(_ id: Session.ID, at instant: Date) {
        if let existing = lastUserInputAt[id], existing >= instant { return }
        lastUserInputAt[id] = instant
    }

    /// Keeps a session's status honest against its live output, in both directions.
    ///
    /// *Sustain*: while `.working`, a changed rendered screen (streaming tokens, a
    /// ticking spinner) refreshes `lastWorkingAt` so `sweepStaleWorking` leaves the
    /// turn alone; a static screen lets the timestamp age out — the recovery for a
    /// turn that ended without a `Stop` hook. The screen, not raw bytes, is the
    /// primary key: a finished agent still dribbles output at an idle prompt (a
    /// redraw, a blinking cursor), which is exactly the stuck-spinner failure. The
    /// byte-rate floor is the one exception — a viewport the user scrolled away
    /// from stops changing even mid-stream (`readViewportText` follows the scroll),
    /// so a genuinely streaming byte volume also counts as liveness.
    ///
    /// *Promote*: a session whose hooks have gone quiet can also come back the
    /// other way. Hooks miss turns in the wild — an uninstalled/broken hook file, a
    /// turn the sweep cleared mid-stream, an agent whose TUI never fires them — and
    /// historically nothing could re-light the spinner until the next hook event.
    /// Two consecutive changed ticks promote `.idle` back to `.working`, guarded
    /// so precision states are never guessed over: never out of `.done` or
    /// `.needsAttention`, not while recent hooks are speaking for the session
    /// (`hookQuietWindow`), not right after launch (the banner painting), not right
    /// after user input (keystroke echo), and never for a plain terminal or an
    /// agent whose declared screen rules already own its status.
    ///
    /// Fed by a throttled once-a-second tap on the PTY stream (see
    /// `surface(for:in:)`); no-ops cost a dictionary lookup.
    func noteOutputActivity(_ id: Session.ID, screenChanged: Bool, bytes: Int) {
        if status(for: id) == .working {
            promotionStreak[id] = nil
            if screenChanged || bytes >= streamingByteFloor {
                lastWorkingAt[id] = Date()
            }
            // Feed the stall detector's output-rate suppressor (§4.7 probe 4)
            // with the raw byte volume. The rate over the whole window is what
            // discriminates: build logs scrolling through a TUI repaint far more
            // bytes per second than an idle spinner's frame updates.
            stallProbes[id]?.streamedBytes += bytes
            return
        }
        guard screenChanged else {
            promotionStreak[id] = nil
            return
        }
        guard status(for: id) == .idle,
              let session = session(id),
              effectiveAgent(for: session) != .terminal,
              effectiveAgent(for: session).statusRules == nil
        else { return }
        let now = Date()
        if let launched = session.launchedAt, now.timeIntervalSince(launched) < launchGraceWindow {
            return
        }
        if let input = lastUserInputAt[id], now.timeIntervalSince(input) < userInputQuietWindow {
            return
        }
        if let report = lastHookReportAt[id], now.timeIntervalSince(report) < hookQuietWindow {
            return
        }
        let streak = (promotionStreak[id] ?? 0) + 1
        guard streak >= 2 else {
            promotionStreak[id] = streak
            return
        }
        promotionStreak[id] = nil
        setStatus(.working, for: id)
        lastWorkingAt[id] = now
    }

    /// Drives status from an agent's own screen when it ships no hook system — the path
    /// for user agents whose `agent.json` declared `status` regex rules (see
    /// `AgentStatusRules`). Called each throttled viewport tick with the freshly
    /// classified activity. Status is only rewritten on a *transition*, so an idle
    /// screen doesn't re-emit `done` every second; a working screen refreshes the
    /// liveness timestamp every tick so the stale sweep can't clear a live turn whose
    /// screen briefly stopped changing. Mirrors `applyStatusReport`'s state mapping —
    /// `attention` only flags a session the user isn't already looking at; a turn that
    /// just ended reads `done` when unselected, `idle` when selected or merely calm.
    func applyScreenDetectedActivity(_ activity: AgentStatusRules.Activity, for id: Session.ID) {
        if activity == .working { lastWorkingAt[id] = Date() }
        guard lastScreenActivity[id] != activity else { return }
        let previous = lastScreenActivity[id]
        lastScreenActivity[id] = activity
        switch activity {
        case .working:
            setStatus(.working, for: id)
        case .attention:
            clearWorking(id)
            flagBlockingAttention(for: id)
        case .idle:
            clearWorking(id)
            if previous == .working || previous == .attention {
                setStatus(isViewing(id) ? .idle : .done, for: id)
            } else {
                setStatus(.idle, for: id)
            }
        }
    }

    /// Drives status from the agent's live `OSC 0/2` title — the in-band state
    /// broadcast some agents ship (Claude prefixes a braille spinner mid-turn,
    /// Codex/Grok flip to "Action Required" when blocked). Unlike the screen path
    /// this *coexists* with hooks: the title is the agent's own deliberate signal
    /// on a channel that cannot break, so it corrects a missed `working` hook the
    /// instant the turn starts and ends a lost turn the instant the title calms —
    /// no 12s sweep wait, no promotion evidence-gathering. Transitions only
    /// (`lastTitleActivity`), with hooks kept senior where they are more precise:
    /// a title-working never overrides `needsAttention` (a blocked agent's title
    /// can keep spinning), and a title-idle only ends a turn — an arbitrary title
    /// (which classifies idle by no-match) must not clear hook-set states.
    func applyTitleActivity(_ activity: AgentStatusRules.Activity, for id: Session.ID) {
        // Liveness first, before the transition guard — every frame of a ticking
        // title spinner is evidence the turn is still running, not just the first
        // one. Claude reprints a new braille frame several times a second and they
        // all collapse to a no-op here; refreshing only on the transition let
        // `sweepStaleWorking` clear the spinner 12s into a live turn, and because
        // the latch below still read `.working`, no later frame could raise it
        // again — the turn finished with a calm row. This mirrors what
        // `applyScreenDetectedActivity` already does with its own signal.
        if activity == .working { lastWorkingAt[id] = Date() }
        guard lastTitleActivity[id] != activity else { return }
        let previous = lastTitleActivity[id]
        lastTitleActivity[id] = activity
        switch activity {
        case .working:
            guard status(for: id) != .needsAttention else { return }
            guard let session = session(id), effectiveAgent(for: session) != .terminal
            else { return }
            setStatus(.working, for: id)
        case .attention:
            clearWorking(id)
            flagBlockingAttention(for: id)
        case .idle:
            guard previous == .working, status(for: id) == .working else { return }
            clearWorking(id)
            setStatus(isViewing(id) ? .idle : .done, for: id)
        }
    }

    /// Drives status from the agent's ConEmu-style `OSC 9;4` progress reports —
    /// the in-band busy/idle signal Grok ships natively (`9;4;1;-1` while a turn
    /// runs, `9;4;0;` when it ends). Like the title, this is a *correction* channel
    /// layered over hooks on the one channel that cannot break (the PTY byte stream),
    /// so its arbitration is deliberately identical to `applyTitleActivity` and just
    /// as subordinate: a progress-working never overrides `needsAttention` (a blocked
    /// agent can keep its busy bar lit — the herdr "blocker outranks a stale busy
    /// progress" rule), and a progress-idle only ends a turn that is genuinely
    /// working, so a lone or stale `9;4;0` can't clear a hook- or title-set state.
    /// The `OSCProgressScanner` only reaches busy/idle, never attention, so the
    /// attention arm is unreachable here but kept exhaustive for the shared enum.
    func applyProgressActivity(_ activity: AgentStatusRules.Activity, for id: Session.ID) {
        // Gate on the session's *live* agent, not a value captured when the sink was
        // built: a plain terminal promoted to a hand-started Grok now opts in, while a
        // shell that stays a shell (its `wget` bar) stays out. Re-reading the session
        // here also drops any event that outlived the pane it came from — a session
        // torn down or relaunched before this main-actor block ran no longer resolves,
        // or resolves to an agent that doesn't emit progress, so it can't repopulate a
        // cleared entry or move a replacement process's dot.
        guard let session = session(id), effectiveAgent(for: session).emitsProgressStatus else { return }
        // Repeated busy reports are liveness, same as a ticking title (see
        // `applyTitleActivity`): refresh before the transition guard so a turn the
        // agent keeps asserting can't be swept out from under it.
        if activity == .working { lastWorkingAt[id] = Date() }
        guard lastProgressActivity[id] != activity else { return }
        let previous = lastProgressActivity[id]
        lastProgressActivity[id] = activity
        switch activity {
        case .working:
            guard status(for: id) != .needsAttention else { return }
            setStatus(.working, for: id)
        case .attention:
            clearWorking(id)
            flagBlockingAttention(for: id)
        case .idle:
            guard previous == .working, status(for: id) == .working else { return }
            clearWorking(id)
            setStatus(isViewing(id) ? .idle : .done, for: id)
        }
    }

    /// Reclassifies a shell-backed session to whatever agent runs in its foreground —
    /// for real, not as a runtime overlay: a hand-started `claude` makes the session
    /// *become* a Claude Code session (persisted, so a reopened app relaunches it as
    /// that agent, resuming the conversation its hooks pinned meanwhile), and the
    /// agent exiting back to the shell demotes it to a plain terminal again. The
    /// identity always says what the pane runs. Only sessions spawned with a shell
    /// underneath ever report here (the detection sink exists solely for them), so a
    /// promoted row keeps polling and the demotion fires when its shell resurfaces.
    /// Idempotent per poll; an SSH terminal is never reclassified (its foreground is
    /// the local `ssh`, and the agents run remotely).
    func noteForegroundAgent(_ detected: AgentDefinition?, for id: Session.ID) {
        guard let home = locate(id) else { return }
        var session = self[home]
        guard !session.isSSH else { return }
        if let detected {
            // Promote a plain terminal only: an already-promoted row seeing its own
            // agent is the idempotent no-op, and a *different* foreground under a
            // promoted row is the agent's own subprocess, not a new identity.
            guard session.agent == .terminal, detected != .terminal else { return }
            // Adopt the declared-session title convention (`addSession`) so the row
            // reads `Claude Code`. Unconditional: a name the user chose lives in
            // `givenTitle` and outranks this at display time, so there is nothing
            // here to protect it from.
            session.title = detected.displayName
            session.agent = detected
            self[home] = session
        } else if session.agent != .terminal {
            demoteSessionToTerminal(id)
        }
    }

    /// The one place a session stops being an agent: reverts the row to a plain
    /// terminal (persisted) and clears the conversation-scoped runtime state — the
    /// adopted topic title and any lingering spinner — so the row can't be left
    /// mid-turn once the agent is gone. The resume pin deliberately survives: it is
    /// dormant on a terminal row, and it still names the conversation this pane last
    /// hosted. Shared by the foreground poll (agent quit back to its shell) and the
    /// clean-exit revert of an exec'd agent session (`revertSessionToShell`).
    func demoteSessionToTerminal(_ id: Session.ID) {
        guard let home = locate(id) else { return }
        var session = self[home]
        guard session.agent != .terminal else { return }
        // Back to the auto `Terminal N` convention (numbered like `addSession`,
        // counting this row itself), so display naming — cwd basename for loose
        // terminals — takes over again. A name the user chose is untouched by this:
        // it lives in `givenTitle` and still outranks the placeholder.
        let terminalCount = roster(at: home).filter { $0.agent == .terminal }.count
        session.title = "Terminal \(terminalCount + 1)"
        session.agent = .terminal
        session.liveTitle = nil
        session.promptTitle = nil
        self[home] = session
        setLiveTitle(nil, for: id)
        lastTitleActivity[id] = nil
        lastProgressActivity[id] = nil
        clearWorking(id)
        let current = status(for: id)
        if current == .working || current == .done { setStatus(.idle, for: id) }
    }

    /// Resolves a session's transcript file from disk when its hook hasn't handed
    /// termio one — the source of truth for the Info pane's trace when no hook fired.
    /// A pinned-id agent whose store is a file-per-conversation (Claude Code) names its
    /// transcript by the id termio pinned (`Session.resumeID`), so it's located directly.
    /// A discovered-id agent with a known pin is likewise looked up by that exact id —
    /// the launch-time earliest-match below would drift back to a rotated-away record —
    /// and only an unpinned session falls back to the launch-time file match
    /// (`AgentSessionStore`). For a directory-based store (Grok: `dir:{id}`), the
    /// directory itself is located and its contents scanned for a transcript file.
    /// `nil` until a matching transcript exists on disk.
    func resolveTranscriptPath(for id: Session.ID) -> String? {
        guard let session = session(id), session.launched else { return nil }
        if let store = session.agent.resumeSpec.store, !store.isDirectory,
           let resumeID = session.resumeID,
           let path = SessionStore.locate(store, id: resumeID) {
            return path
        }
        if let store = session.agent.resumeSpec.store, store.isDirectory,
           let resumeID = session.resumeID,
           let dirPath = SessionStore.locate(store, id: resumeID) {
            // Directory-based store: the session is a directory of files. Prefer the
            // manifest's `transcriptName` when set (Grok: `chat_history.jsonl`). Do not
            // fall through to sole-jsonl when a name is declared — Grok dirs routinely
            // hold several `.jsonl` files (`updates.jsonl`, `events.jsonl`, …), and a
            // briefly-missing named file must not pin a sibling. Sole-jsonl is only for
            // undeclared names where exactly one candidate exists.
            if let name = store.transcriptName {
                return transcriptFile(in: dirPath, named: name)
            }
            return soleJSONLFile(in: dirPath)
        }
        if session.agent.resumeSpec.discover != nil, let resumeID = session.resumeID {
            return AgentSessionStore.transcript(agent: session.agent, id: resumeID)
        }
        guard let directory = session.worktreePath ?? project(for: id)?.path else { return nil }
        return AgentSessionStore.discoverTranscript(
            agent: session.agent, directory: directory, after: session.launchedAt)
    }

    /// Returns the path to a named file inside a directory, or `nil` if it doesn't exist.
    private func transcriptFile(in directory: String, named name: String) -> String? {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        return candidate
    }

    /// Returns the path to the single `.jsonl` file in a directory, or `nil` when there
    /// are zero or more than one — the transcript is ambiguous with multiple candidates.
    private func soleJSONLFile(in directory: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
        else { return nil }
        let jsonlFiles = entries.filter {
            $0.pathExtension.lowercased() == "jsonl"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard jsonlFiles.count == 1 else { return nil }
        return jsonlFiles[0].path
    }

    /// Sweeps sessions stuck in `.working` with no activity for a generous window
    /// back to `.idle`. This only matters while the user is looking elsewhere —
    /// selecting a session already clears it — so the timeout is long enough never
    /// to interrupt a genuinely long turn (tool events keep refreshing it), and is
    /// purely a recovery path for an agent that died mid-turn.
    private func sweepStaleWorking() {
        let now = Date()
        for (id, since) in lastWorkingAt where now.timeIntervalSince(since) > staleWorkingTimeout {
            if status(for: id) == .working { setStatus(.idle, for: id) }
            clearWorking(id)
        }
    }

    // MARK: Loop-level stall detection (design doc §4.7)

    /// How long a session must be continuously `.working` with no progress marker
    /// before it reads as stalled — probe 1's window, and the span every other
    /// probe compares across.
    nonisolated static let stallWindow: TimeInterval =
        stallOverride("TERMIO_STALL_WINDOW_SECONDS", default: 20 * 60)
    /// Transcript lines the window must add to count as progress (probe 3's K).
    nonisolated static let stallTranscriptLineFloor: Int =
        Int(stallOverride("TERMIO_STALL_TRANSCRIPT_LINES", default: 5))
    /// The average PTY output rate (bytes/second across the window) at or above
    /// which probe 4 suppresses the alert: the agent is visibly producing —
    /// output genuinely scrolling through the terminal. Calibrated against
    /// measured Claude Code rates (2026-07): parked on a spinner ~1.4 KB/s,
    /// a tool call with collapsed output ~1.1 KB/s, streaming a text response
    /// ~1.5 KB/s averaged across its thinking pauses — while full-screen output
    /// scrolls run tens of KB/s. The default sits above every measured idle mode.
    /// Note the flip side: a TUI that collapses tool output (Claude) keeps a
    /// legitimate long build *under* this rate, so a window-length quiet build
    /// still signals — from outside the agent the two are indistinguishable,
    /// which is exactly why this plane signals and never kills (§4.7); the
    /// transcript-tail awareness of phase 4b is the planned refinement.
    nonisolated static let stallStreamByteRate: Double =
        stallOverride("TERMIO_STALL_STREAM_BYTES_PER_SECOND", default: 4096)
    /// How often the expensive probes may re-run per session once its window has
    /// elapsed. Scaled with the window so a shortened testing window still probes
    /// promptly; the 2s floor is the sweep's own tick.
    nonisolated static let stallProbeInterval: TimeInterval = max(2, stallWindow / 40)

    /// Testing-only override for the stall thresholds, so live verification does
    /// not take 20 minutes: the environment variable when a dev launch exports
    /// one, else a `defaults` key of the same name, else the shipped default.
    /// Read once at first use; deliberately not a setting.
    nonisolated private static func stallOverride(_ key: String, default value: Double) -> Double {
        if let raw = ProcessInfo.processInfo.environment[key],
           let overridden = Double(raw), overridden > 0 { return overridden }
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : value
    }

    /// The stall sweep, riding the same 2s timer as `sweepStaleWorking`. The four
    /// probes are evaluated lazily, cheapest first: the clock (probe 1) and the
    /// output-rate suppressor (probe 4) are plain arithmetic and gate everything;
    /// only a fully-elapsed, unsuppressed window pays for the off-main git +
    /// transcript measurement (probes 2 and 3). Verdict `1 AND 2 AND 3 AND NOT 4`
    /// emits one `stalled` watch event, then holds until a progress marker
    /// re-arms the window.
    func sweepStalledSessions() {
        let now = Date()
        for (id, probe) in stallProbes {
            guard status(for: id) == .working else { stallProbes[id] = nil; continue }
            guard !probe.measuring else { continue }
            guard probe.baseline != nil else {
                launchStallMeasurement(for: id, capture: true)
                continue
            }
            guard now.timeIntervalSince(probe.windowStart) >= Self.stallWindow,
                  now.timeIntervalSince(probe.lastProbeAt) >= Self.stallProbeInterval
            else { continue }
            if probe.isStreamSuppressed(at: now, bytesPerSecond: Self.stallStreamByteRate) {
                // Sustained output is progress in itself: slide the window instead
                // of alerting, and drop the baseline so the next capture compares
                // against the world as of now.
                Self.stallTrace.info(
                    "suppressed session=\(id, privacy: .public) streamed_bytes=\(probe.streamedBytes, privacy: .public) elapsed_s=\(Int(now.timeIntervalSince(probe.windowStart)), privacy: .public)")
                var slid = probe
                slid.slideWindow(to: now, baseline: nil)
                stallProbes[id] = slid
                continue
            }
            launchStallMeasurement(for: id, capture: false)
        }
    }

    /// Opens the stall window for a session that just entered `.working`: stamps
    /// `workingSince` now; the first sweep tick captures the baseline. Called
    /// only from `setStatus`, the single status choke point.
    func beginStallWatch(for id: Session.ID) {
        let now = Date()
        stallProbes[id] = StallProbe(workingSince: now, windowStart: now)
    }

    /// Runs the expensive probes off the main actor — the BranchModel
    /// main-thread-git freeze is the documented hazard — and applies the result
    /// back on it. With `capture` the result seeds a fresh window's baseline;
    /// otherwise it is judged against the existing one.
    private func launchStallMeasurement(for id: Session.ID, capture: Bool) {
        guard var probe = stallProbes[id] else { return }
        probe.measuring = true
        if !capture { probe.lastProbeAt = Date() }
        stallProbes[id] = probe
        let generation = probe.generation
        let baseline = probe.baseline
        // The baseline's directory is reused for the whole window, so an agent
        // `cd`-ing between repos can't masquerade as repo progress.
        let directory = capture ? stallProbeDirectory(for: id) : baseline?.directory
        let transcript = transcriptPaths[id] ?? resolveTranscriptPath(for: id)
        Task { [weak self] in
            let measured = await Self.measureStallEvidence(
                directory: directory, transcript: transcript, known: baseline)
            guard let self, var probe = self.stallProbes[id],
                  probe.generation == generation else { return }
            probe.measuring = false
            if capture {
                probe.baseline = StallProbe.Baseline(directory: directory, measured: measured)
                self.stallProbes[id] = probe
                return
            }
            let assessment = probe.assess(
                measured, at: Date(), transcriptLineFloor: Self.stallTranscriptLineFloor)
            self.stallProbes[id] = probe
            Self.stallTrace.info(
                "probe session=\(id, privacy: .public) verdict=\(String(describing: assessment), privacy: .public) fingerprint=\(measured.repoFingerprint, privacy: .public) transcript_lines=\(measured.transcriptLines, privacy: .public) streamed_bytes=\(probe.streamedBytes, privacy: .public)")
            if case .stalled(let linesGrown) = assessment {
                self.emitStalled(
                    id, workingSince: probe.workingSince, transcriptLinesGrown: linesGrown)
            }
        }
    }

    /// Where probe 2 fingerprints: the session's own worktree when it has one,
    /// else the live shell cwd, else the project checkout.
    private func stallProbeDirectory(for id: Session.ID) -> String? {
        guard let session = session(id) else { return nil }
        return session.worktreePath ?? runtimes[id]?.workingDirectory ?? project(for: id)?.path
    }

    /// One off-main reading of probes 2 and 3. The transcript's full line count is
    /// only paid for when its size moved (or nothing is known yet) — an unchanged
    /// `stat` answers "grew < K lines" by itself.
    nonisolated private static func measureStallEvidence(
        directory: String?, transcript: String?, known: StallProbe.Baseline?
    ) async -> StallMeasurement {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fingerprint = directory.map { GitService.stallFingerprint(in: $0) } ?? ""
                guard let transcript else {
                    return continuation.resume(returning: StallMeasurement(
                        repoFingerprint: fingerprint, transcriptPath: nil,
                        transcriptLines: 0, transcriptSize: 0))
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: transcript)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let lines: Int
                if let known, known.transcriptPath == transcript, known.transcriptSize == size {
                    lines = known.transcriptLines
                } else {
                    lines = lineCount(of: transcript)
                }
                continuation.resume(returning: StallMeasurement(
                    repoFingerprint: fingerprint, transcriptPath: transcript,
                    transcriptLines: lines, transcriptSize: size))
            }
        }
    }

    /// Broadcasts the one `stalled` event. Watch-plane only (§4.7): the session's
    /// real status stays `.working` — no new `SessionStatus` case, the sidebar and
    /// menu bar are untouched — and the default watch filter (done, needs-you)
    /// keeps the signal opt-in via `--state stalled`.
    private func emitStalled(
        _ id: Session.ID, workingSince: Date, transcriptLinesGrown: Int
    ) {
        guard let session = session(id), let project = project(for: id) else { return }
        let minutes = max(1, Int(Date().timeIntervalSince(workingSince) / 60))
        let growth = "transcript +\(transcriptLinesGrown) line"
            + (transcriptLinesGrown == 1 ? "" : "s")
        var event = SessionWatchEvent(
            projectID: project.id,
            link: sessionLink(for: session),
            status: "stalled",
            title: displayTitle(for: session),
            cwd: runtimes[id]?.workingDirectory ?? "")
        event.evidence = "working \(minutes)m, no repo change, \(growth)"
        SessionWatchHub.shared.broadcast(event)
    }

    /// A short description of a session's current agent activity, for the sidebar
    /// status tooltip: the tool in use while working, or what it is waiting on.
    /// Empty when idle, so the tooltip simply does not appear.
    func statusDescription(for sessionID: Session.ID) -> String {
        switch status(for: sessionID) {
        case .idle:
            return ""
        case .working:
            if let tool = runtimes[sessionID]?.currentTool { return "Working — \(tool)" }
            return "Working…"
        case .done:
            return "Done"
        case .needsAttention:
            return "Waiting for you"
        }
    }
}

/// Per-session state for loop-level stall detection (design doc §4.7). One value
/// exists per continuously-working session, created on the `.working` transition
/// and dropped on the way out. The window slides forward on every progress
/// marker; `alerted` is the edge-trigger latch — one `stalled` event per quiet
/// window, re-armed only by progress. A plain value type so the verdict logic is
/// testable without the store.
struct StallProbe {
    /// When the session entered `.working` — probe 1's clock, and the duration the
    /// evidence string reports.
    let workingSince: Date
    /// Start of the current no-progress window; slides to "now" on any progress.
    var windowStart: Date
    /// PTY output bytes seen since `windowStart` — probe 4's numerator, fed by
    /// `noteOutputActivity`. Volume, not tick counting: an idle agent's spinner
    /// repaints on every tick too, so only the byte *rate* separates "parked on a
    /// spinner" from "build logs scrolling through the TUI".
    var streamedBytes = 0
    /// What the window's probes compare against, captured off-main just after
    /// `windowStart`. `nil` while a capture is pending.
    var baseline: Baseline?
    /// An off-main capture or probe is in flight; the sweep must not stack another.
    var measuring = false
    /// Ties an in-flight off-main measurement back to this exact probe value, so a
    /// result landing after the session left and re-entered `.working` is
    /// discarded instead of judged against the wrong window.
    let generation = UUID()
    var lastProbeAt = Date.distantPast
    var alerted = false

    struct Baseline {
        /// The directory fingerprinted at capture, reused for the whole window.
        let directory: String?
        let repoFingerprint: String
        let transcriptPath: String?
        let transcriptLines: Int
        let transcriptSize: Int64

        init(directory: String?, measured: StallMeasurement) {
            self.directory = directory
            repoFingerprint = measured.repoFingerprint
            transcriptPath = measured.transcriptPath
            transcriptLines = measured.transcriptLines
            transcriptSize = measured.transcriptSize
        }
    }

    enum Assessment: Equatable {
        /// A progress marker landed — the window slid forward and re-armed.
        case progress
        /// Every probe agrees: emit the one `stalled` event.
        case stalled(transcriptLinesGrown: Int)
        /// No progress, but the alert already fired — keep holding.
        case hold
    }

    /// Whether probe 4 suppresses the alert: the window's average output rate
    /// says the agent is visibly producing.
    func isStreamSuppressed(at now: Date, bytesPerSecond: Double) -> Bool {
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed > 0 else { return false }
        return Double(streamedBytes) >= elapsed * bytesPerSecond
    }

    /// Judges a fresh measurement against the baseline (probes 2 and 3) and
    /// applies the verdict: progress slides the window and re-arms; the first
    /// all-probes-agree verdict latches `alerted` so the event fires exactly once.
    mutating func assess(
        _ measured: StallMeasurement, at now: Date, transcriptLineFloor: Int
    ) -> Assessment {
        guard let baseline else { return .hold }
        let linesGrown = max(0, measured.transcriptLines - baseline.transcriptLines)
        if measured.repoFingerprint != baseline.repoFingerprint
            || linesGrown >= transcriptLineFloor {
            slideWindow(to: now, baseline: Baseline(
                directory: baseline.directory, measured: measured))
            return .progress
        }
        if alerted { return .hold }
        alerted = true
        return .stalled(transcriptLinesGrown: linesGrown)
    }

    /// Restarts the no-progress window at `now` and re-arms the alert. A `nil`
    /// baseline makes the next sweep tick capture a fresh one.
    mutating func slideWindow(to now: Date, baseline newBaseline: Baseline?) {
        windowStart = now
        streamedBytes = 0
        baseline = newBaseline
        alerted = false
    }
}

/// One off-main reading of a session's progress evidence: the repo fingerprint
/// plus the transcript's current extent.
struct StallMeasurement {
    let repoFingerprint: String
    let transcriptPath: String?
    let transcriptLines: Int
    let transcriptSize: Int64
}
