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
    version: "0.8.0",
    date: "2026-06-30",
    title: "Termio is now free",
    changes: {
      new: [
        "Termio is now free to use — no trial clock, no license key, no account, no card. Just download it and go.",
      ],
    },
  },
  {
    version: "0.7.0",
    date: "2026-06-29",
    title: "Per-project sandbox",
    changes: {
      new: [
        "Opt a project into running its sessions inside an Apple Seatbelt sandbox, contained from the rest of your Mac.",
      ],
      improved: [
        "Window chrome is now driven by a native toolbar, showing the active project and session as a title and subtitle.",
        "Window content is hosted in a native split-view controller for a full-height sidebar behind the traffic lights.",
      ],
      fixed: [
        "The project name in the sidebar now fades under the hover icons instead of overlapping them.",
      ],
    },
  },
  {
    version: "0.6.0",
    date: "2026-06-20",
    title: "Worktree folders and a command-line tool",
    changes: {
      new: [
        "Git worktrees are promoted to top-level sidebar folders, so your worktrees are grouped under their project.",
        "A bundled command-line tool lets you open projects and launch sessions from your shell.",
      ],
      improved: [
        "Reorder projects by drag and drop in the sidebar.",
      ],
    },
  },
  {
    version: "0.5.0",
    date: "2026-06-08",
    title: "Menu-bar session roster",
    changes: {
      new: [
        "A menu-bar roster lists your live agent sessions for quick switching.",
      ],
      improved: [
        "Every open session stays mounted and keeps running as you switch between them.",
        "Each folder shows its live git branch in the sidebar and title bar.",
        "Sessions auto-title themselves from the agent's live terminal title.",
      ],
    },
  },
];
