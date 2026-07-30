## Superlogical facts (sourced)

- **Company and launch:** Mitchell Hashimoto announced Superlogical on **July 29, 2026** as a new company. The company is currently collecting sign-ups for a terminal-multiplexer beta; no public release date has been announced. [Mitchell’s announcement](https://mitchellh.com/writing/superlogical), [launch post on X](https://x.com/mitchellh/status/2082489600715661389)

- **Cofounders:**
  - Mitchell Hashimoto — creator of Ghostty; cofounder and former CEO/CTO of HashiCorp.
  - Jack Pearkes — HashiCorp’s first employee and former VP of Engineering/R&D.
  - Alasdair Monk — former Head of Experience at Poolside and VP of Design at Vercel.
  - Hector Simpson — former Poolside designer/builder, with prior work at Heroku, HashiCorp, Clearbit, and Vercel.
  - Hashimoto says all four will play an equal role. [Superlogical team](https://www.superlogical.com/), [Mitchell’s announcement](https://mitchellh.com/writing/superlogical)

- **Funding:** Superlogical names **Notable Capital** and **Amplify Partners**, plus angels including Aaron Levie, Armon Dadgar, Guillermo Rauch, Mario Zechner, Patrick Collison, Tobias Lütke, and others. The amount, round, valuation, and financing date have **not been publicly disclosed** in the primary sources reviewed. [Superlogical funding list](https://www.superlogical.com/)

- **Vision:** The company describes its goal as building the **“multiplexer for all work.”** The proposed abstraction is a durable session spanning local development, remote hosts, background jobs, agents, production applications, debugging, incident response, operational history, and multiplayer work. [Superlogical](https://www.superlogical.com/)

- **Product sequence:**
  1. Build a high-quality multiplexer.
  2. Make its contents composable.
  3. Make it safe and operable in production.
  
  The terminal multiplexer is the starting product, not the final scope. [Superlogical](https://www.superlogical.com/)

- **Initial terminal product:** Announced capabilities include long-lived sessions, reconnecting from another device, multiple terminal blocks, web access, native macOS/iOS clients, built-in live sharing, and native-feeling scrollback, selection, and scrolling. These are announced intentions, not verified shipped functionality. [Superlogical](https://www.superlogical.com/)

- **Technical stack:** Hashimoto states: **“The server/networking components are Go, native apps are Swift (Apple), and the low level bits and bobs are Zig.”** The Zig pieces expose bindings upward. A web-client implementation language has not been officially specified. [Stack reply on X](https://x.com/mitchellh/status/2082623830510710865)

- **Open-source posture:** The site promises unspecified OSS releases during development, but does not say the complete product or server will be open source. Superlogical will use the same public, MIT-licensed libghostty components available to other developers and intends to upstream shared terminal work. [Mitchell’s announcement](https://mitchellh.com/writing/superlogical)

## Design intentions (from Mitchell replies, quote where possible)

- **Platform rather than an agent-specific tool**
  - Superlogical includes coding agents and parallel agents, but it is deliberately **not positioned as agent-first**. The launch thesis says AI exposed and increased the cost of fragmentation but “did not create it.”
  - Its unit of abstraction is work and durable sessions, covering humans, automation, agents, and production systems. It is therefore closer to a general execution/session platform than an agent harness such as an agent sidebar, coding workflow manager, or PR orchestrator.
  - “Not agent-first” should not be read as “agents are unimportant.” The planned system explicitly supports software-driven sessions, structured actions, parallel agents, and human visibility/control. [Superlogical](https://www.superlogical.com/), [Mitchell’s replies](https://x.com/mitchellh/with_replies)

- **Architecture versus tmux, Herdr, and cmux**
  - In launch-day replies, Hashimoto distinguished Superlogical from terminal-within-a-terminal muxes such as tmux and Herdr. His position is that cloning that architecture is a **dead end for Superlogical’s goals**, because it preserves the nested terminal boundary rather than making the durable session and its state the primary system.
  - The stated direction is a dedicated mux server/network layer with purpose-built clients. The mux **“owns SSH”** rather than treating remote work solely as an external `ssh → remote tmux` composition.
  - cmux is closer in UI technology because it is a native application built on libghostty, but Superlogical’s intended boundary is broader: durable network sessions, multiple client types, discovery, reconnection, sharing, and eventually non-terminal work.
  - **Inference:** This points toward a structured, reconnectable client/server protocol and server-owned session lifecycle instead of merely replaying one terminal byte stream. Superlogical has not published its wire protocol, terminal-state authority, snapshot/diff model, SSH credential design, or conflict semantics, so those details should not be stated as facts. [Mitchell’s replies](https://x.com/mitchellh/with_replies), [Superlogical](https://www.superlogical.com/)

- **SSH ownership**
  - “The mux owns SSH” suggests remote connections are durable session resources managed by the mux rather than transient processes established independently by every client.
  - Likely consequences include reconnectable SSH-backed blocks, unified local/remote session identity, and integrated remote discovery.
  - **Speculation:** It is not yet known whether SSH executes inside each user-controlled server, whether a Superlogical-hosted control plane participates, how keys are stored, or whether system OpenSSH remains available as a backend.

- **Client matrix**
  - Explicitly announced: web, native macOS, and native iOS.
  - Apple applications are being written in Swift.
  - No firm Linux-native, Windows-native, Android, or terminal/TUI client commitment was found in the primary launch materials.
  - The intended model is multiple clients attaching to the same durable session, rather than each client owning an independent terminal process. [Superlogical](https://www.superlogical.com/), [stack reply](https://x.com/mitchellh/status/2082623830510710865)

- **Networking and discovery**
  - Superlogical already has a direct Tailscale integration that Hashimoto says will probably ship.
  - Hashimoto writes: **“Servers can automatically join a tailscale … and clients can automatically find them with one config.”**
  - Other integrations are reportedly in development, but they have not been named.
  - This makes remote discovery and connectivity a product concern, rather than leaving users to assemble hostnames, SSH configuration, tunnels, and mux attachment manually. [Tailscale reply on X](https://x.com/mitchellh/status/2082634453474795885)

- **Ghostty and libghostty**
  - The Superlogical application is not Ghostty. Hashimoto previewed it as **“Not Ghostty btw (but, libghostty).”** [UI preview on X](https://x.com/mitchellh/status/2079327969416482859)
  - Ghostty remains owned by a nonprofit, with its mission, governance, license, roadmap, and technical goals unchanged.
  - Superlogical receives no private libghostty entitlement: it will consume public MIT-licensed components and upstream generally useful terminal work.
  - libghostty is therefore shared infrastructure, not an exclusive Superlogical moat. [Mitchell’s announcement](https://mitchellh.com/writing/superlogical)

## Competitive implications for termio

- **Where Superlogical directly overlaps termio**
  - Durable terminal sessions surviving client closure and reconnection.
  - A daemon/server boundary separate from the viewing client.
  - Native macOS and iOS access to the same sessions.
  - Remote hosts and cross-device attachment.
  - Tailscale-assisted networking and discovery.
  - libghostty-based terminal behavior.
  - Multiple simultaneous clients, live sharing, and multiplayer control.
  - Agents running in persistent terminal sessions.
  - A future structured API through which software can inspect or drive sessions.
  - Native scrollback, selection, and terminal interaction rather than tmux-style nested terminal behavior.

- **Competitive conclusion:** Superlogical should now be treated as a **direct competitor at termio’s session-mux layer**, not merely a distant “platform peer.” Its broader platform ambition does not reduce the near-term overlap: its first product is almost exactly the durable, cross-device terminal foundation described in termio’s design.

- **Where Superlogical deliberately does not position itself**
  - It is not presented as an agent-specific coding harness or agent-only IDE.
  - It does not currently describe first-class `working`, `idle`, `needs-you`, approval, or failure states for coding agents.
  - It does not announce opinionated worktree, repository, prompt, review, or pull-request workflows.
  - It does not announce a multi-agent supervisory CLI comparable to `termio sessions`.
  - It is not commercializing or replacing the Ghostty terminal emulator.
  - These are current positioning differences, not durable guarantees; its composability goal could eventually support many of these workflows.

- **Where termio can still win**
  - **Agent-native ADE:** Make the managed object an agent workstream with repository, branch/worktree, task, status, approvals, and artifacts—not just a terminal block.
  - **Reliable agent status:** Treat `working`, `idle`, `needs-you`, `failed`, and `done` as protocol-level state with explicit events and notifications. Avoid relying only on terminal-output heuristics.
  - **Multi-agent CLI:** Keep `termio sessions` as a stable automation and delegation surface for humans and agents. Structured, scriptable supervision is a clearer wedge than terminal multiplexing alone.
  - **Local-first trust model:** Run the daemon and durable history on user-controlled machines by default; use existing system SSH or user-selected networks without requiring a hosted control plane.
  - **Mac+iOS ADE integration:** Native Apple clients are no longer differentiating by themselves. The defensible combination is native Apple UX plus agent state, approvals, project context, voice/mobile intervention, and fast handoff between observation and action.
  - **Narrower scope and faster delivery:** Superlogical is pursuing terminals, automation, production systems, multiplayer work, and a general platform. Termio can make a smaller set of agent-development workflows excellent sooner.
  - **Interoperability:** Existing SSH configuration, keys, Tailscale/Headscale networks, shells, agents, and repositories can remain user-owned. Avoid forcing users into a proprietary execution environment.
  - **Transparent protocol and self-hosting:** If termiod’s protocol and daemon are open and independently deployable, that can become a meaningful distinction. Superlogical has announced some OSS releases but not an open-source product.
  - **Caveat:** Superlogical has an unusually experienced, funded infrastructure-and-design team. “Local-first” or “agent-native” will only differentiate termio if they produce visibly better workflows and simpler trust boundaries, not merely different architecture labels.

## Suggested updates to docs/design/termiod-session-mux.md

- **Replace the “Why we can beat Superlogical” premise.**
  - Remove or soften the characterization of Superlogical as merely a Go platform foundation whose “partners become remote.”
  - Replace it with: Superlogical is a direct durable-session competitor with a broader long-term platform scope; termio’s differentiation is an agent-native ADE, local-first ownership, and multi-agent supervision.
  - Rationale: the current wording understates the announced native Apple clients, remote discovery, sharing, libghostty use, and terminal-first product.

- **Correct the competitive matrix.**
  - Record the stack as Go for server/networking, Swift for Apple apps, and Zig for low-level components.
  - Mark web, macOS, and iOS as explicitly announced clients.
  - Add built-in live sharing/multiplayer.
  - Add direct Tailscale server enrollment and client discovery.
  - Change “agent status: not product focus” to “not agent-first; specific agent-state UX not announced.”
  - Mark all Superlogical product capabilities as announced/pre-beta until shipped.
  - Add “unknown” rows for pricing, hosted-control-plane requirements, self-hosting, complete OSS scope, Linux/Windows clients, and SSH credential ownership.
  - Rationale: avoid converting missing public information into negative claims.

- **Change “platform peer, not product twin” to a more precise conclusion.**
  - Suggested claim: “Direct session-layer competitor; differentiated product thesis.”
  - Rationale: the products overlap strongly at the mux layer even if termio remains more opinionated about agent development.

- **Define “agent-native” operationally.**
  - Add explicit protocol objects/events for agent identity, task, project, worktree, status, `needs-you`, approval requests, completion, errors, and notification routing.
  - Define which state comes from agent integrations and which may be inferred from PTY output.
  - Rationale: this is termio’s clearest remaining wedge and must be architectural, not a sidebar added to a generic mux.

- **Revisit the raw-PTY-first protocol decision before freezing it.**
  - A raw byte stream is useful for bootstrap compatibility, but make terminal snapshots/diffs and authoritative reconnect state an early design decision rather than an optional distant optimization.
  - Rationale: heterogeneous web/macOS/iOS clients, late attachment, native scrollback, session sharing, and resynchronization become harder if the protocol assumes one continuously connected emulator.
  - **Inference from Superlogical’s architecture comments:** terminal-in-terminal compatibility is valuable, but should not become termiod’s permanent semantic boundary.

- **Reconcile this document with `session-daemon-architecture.md`.**
  - One document currently favors raw PTY bytes with grid diffs deferred; the other describes a server-side libghostty terminal model as authoritative.
  - Choose and document a staged contract, for example:
    - raw byte passthrough for bring-up and compatibility;
    - server-side terminal state for persistence and resync;
    - snapshot plus incremental diff protocol for full clients;
    - optional raw stream for debugging or simple clients.
  - Rationale: the contradiction affects protocol stability, scrollback ownership, reconnect correctness, and mobile-client complexity.

- **Clarify the SSH boundary.**
  - Replace “Superlogical owns SSH as product: yes” with a sourced, narrower statement: integrated SSH/remote connectivity is part of its mux architecture, but implementation and custody details are unpublished.
  - Describe termio’s use of system SSH as a deliberate trust and compatibility choice, not merely missing functionality.
  - Rationale: system SSH reduces security scope and preserves user configuration, while integrated SSH may offer smoother discovery and reconnection. The trade-off should be explicit.

- **Promote discovery to a first-class subsystem.**
  - Define a provider interface for static SSH config, Bonjour/local discovery, Tailscale, and future integrations.
  - Keep Tailscale optional and avoid making a vendor account part of the core session protocol.
  - Rationale: Superlogical is productizing one-config server discovery; a transport table alone does not address that experience.

- **Strengthen the local-first security model.**
  - State where PTYs, scrollback, metadata, agent events, credentials, and project context reside.
  - State that no hosted service is required for local or direct SSH/Tailscale operation, if that remains the intended design.
  - Document daemon user permissions, Unix-socket authorization, remote-client authorization, and relay limitations.
  - Rationale: local ownership is only a competitive advantage when its trust boundaries are concrete.

- **Add a client-capability matrix.**
  - Cover macOS, iOS, CLI, and possible web clients across attach/control, read-only monitoring, input, scrollback, file links, approvals, notifications, background reconnect, and session creation.
  - Rationale: “Mac+iOS support” is now table stakes against Superlogical; termio should specify the ADE actions each client uniquely enables.

- **Make iOS intervention a product-level differentiator.**
  - Specify low-friction approval, `needs-you` response, voice input, safe command dispatch, reconnect, and read-only monitoring modes.
  - Rationale: running a full terminal on iOS is less distinctive than resolving an agent blockage safely in seconds.

- **Add sharing and concurrent-control semantics to either scope or non-goals.**
  - Decide whether multiple clients may observe, type concurrently, request control, or share a session with another identity.
  - Rationale: Superlogical says live sharing is built in from the start; termiod should not leave its concurrency semantics accidental.

- **Avoid treating libghostty as a competitive moat.**
  - Reframe it as shared terminal infrastructure.
  - Identify termio’s moat as agent-aware state, workflow protocol, local-first deployment, Apple interaction design, and multi-agent automation.
  - Rationale: Superlogical and other applications can consume the same library, and shared improvements may be upstreamed.

- **Add explicit non-goals relative to Superlogical.**
  - Unless termio intends otherwise, list production application multiplexing, incident response, live production debugging, CI replacement, and a general “multiplexer for all work” as out of scope.
  - Rationale: prevents Superlogical’s broader vision from pulling termio away from its sharper ADE opportunity.

- **Add a competitive-evidence policy.**
  - Label statements as shipped, announced, inferred, or unknown.
  - Revisit the comparison after Superlogical’s first beta or protocol devlog.
  - Rationale: the company is one day into public launch, and most architectural, security, pricing, and distribution details remain undisclosed.

## Sources

- https://www.superlogical.com/
- https://mitchellh.com/writing/superlogical
- https://x.com/mitchellh/status/2082489600715661389
- https://x.com/mitchellh/status/2082623830510710865
- https://x.com/mitchellh/status/2082634453474795885
- https://x.com/mitchellh/status/2079327969416482859
- https://x.com/mitchellh/with_replies
- https://news.ycombinator.com/item?id=49098965