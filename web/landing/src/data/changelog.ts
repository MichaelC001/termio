// The changelog rendered at /changelog, newest entry first. Termio ships through
// Sparkle, so a release here corresponds to a notarized build users auto-update
// to. Keep entries short and user-facing — what changed, not how. Categories are
// optional; omit any that are empty for a release. Items may open with a short
// "Label: rest" lead — the page renders the label bold, Glaze-style.

export type ChangeKind = "new" | "improved" | "fixed";

export type ChangelogEntry = {
  version: string;
  // ISO date (YYYY-MM-DD) of the release; formatted for display at render time.
  date: string;
  // The release headline — what this version is remembered for.
  title: string;
  changes: Partial<Record<ChangeKind, string[]>>;
};

export const changelog: ChangelogEntry[] = [
  {
    version: "0.3.0",
    date: "2026-07-10",
    title: "Split panes and command palettes",
    changes: {
      new: [
        "Split panes: split a session vertically or horizontally and work in multiple terminals side by side.",
        "Command palette: drive splits, sessions and terminal actions from the keyboard, alongside a new Terminal menu.",
        "Rename a session from its right-click menu in the sidebar.",
      ],
      fixed: [
        "Opening a file in the editor no longer crashes downloaded builds.",
        "Closing a session now ends its entire process tree, so no stray agent processes are left behind.",
      ],
    },
  },
  {
    version: "0.2.4",
    date: "2026-07-09",
    title: "A welcome start page",
    changes: {
      new: [
        "A welcome page greets you when nothing is open — start a session, pick an agent, or jump back into a recent project.",
      ],
      improved: [
        "Settings now flags agents whose command-line tool isn't installed, and fresh installs start with a focused default lineup.",
      ],
    },
  },
  {
    version: "0.2.3",
    date: "2026-07-09",
    title: "Agents repaint on resize",
    changes: {
      fixed: [
        "Agents now redraw correctly when you resize the window, instead of freezing at their old layout.",
      ],
    },
  },
  {
    version: "0.2.2",
    date: "2026-07-08",
    title: "The right login shell",
    changes: {
      fixed: [
        "Sessions now resolve your login shell from the system's user directory instead of the ambient environment, so they launch with the right shell every time.",
      ],
    },
  },
  {
    version: "0.2.1",
    date: "2026-07-08",
    title: "A new app identity",
    changes: {
      improved: [
        "The app's bundle identifier is now sh.termio.app. If auto-update doesn't offer this release, download it once from the site — updates continue normally afterwards.",
      ],
    },
  },
  {
    version: "0.2.0",
    date: "2026-07-08",
    title: "Four new agents and named worktrees",
    changes: {
      new: [
        "Amp, Cursor, Droid and Kimi Code join the built-in agent lineup, each with live status and its real brand icon.",
        "New Worktree: create a named git worktree straight from a project's right-click menu.",
      ],
      fixed: [
        "The first prompt no longer appears shoved to the right after launch.",
        "The window resizes freely again when no session is selected.",
      ],
    },
  },
  {
    version: "0.1.1",
    date: "2026-07-06",
    title: "Launch fix for downloaded builds",
    changes: {
      fixed: [
        "Downloaded builds now launch reliably — 0.1.0 could crash on first open on some Macs.",
      ],
    },
  },
  {
    version: "0.1.0",
    date: "2026-07-06",
    title: "Hello, Termio",
    changes: {
      new: [
        "Termio's first public release — a native Mac terminal built for running AI coding agents, free to download.",
        "Projects and sessions live in a full-height sidebar, with live working / idle / attention status for every agent.",
        "Git worktrees are grouped as folders under their project, and each folder shows its live branch.",
        "Sandbox: opt a project into running its sessions inside an Apple Seatbelt sandbox, contained from the rest of your Mac.",
        "A menu-bar roster lists your live agent sessions for quick switching.",
        "A bundled command-line tool opens projects and launches sessions from your shell.",
      ],
    },
  },
];
