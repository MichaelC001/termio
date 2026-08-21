/// The built-in themes: 60 well-known Ghostty scheme names, in display order — 45
/// dark, then 15 light, by each theme's own background luminance.
///
/// Shared because the Mac's theme picker and the iPhone's offer the same set, and
/// two hand-kept copies would drift. Names only: both ends resolve them against
/// `GhosttyThemeCatalog` to render, and that meaning does not belong in this
/// package.
///
/// Curated, not exhaustive. No two entries read as the same theme — measured as
/// weighted mean CIE Lab distance over background, foreground, and ANSI 1–6, with
/// every pair clearing ΔE 12, which is what keeps near-duplicate families
/// (TokyoNight Night/Storm, Catppuccin Mocha/Macchiato, Rose Pine/Moon) down to
/// one row each. `ThemeLibraryTests` enforces the resolve, the brightness split,
/// and the distance rule.
public enum BuiltInThemes {
    public static let names: [String] = [
        "Dracula",
        "Catppuccin Mocha",
        "TokyoNight Night",
        "Nord",
        "Gruvbox Dark",
        "Atom One Dark",
        "Monokai Pro",
        "Rose Pine",
        "Ayu Mirage",
        "Night Owl",
        "Kanagawa Wave",
        "Kanagawa Dragon",
        "Everforest Dark Hard",
        "GitHub Dark Default",
        "iTerm2 Solarized Dark",
        "Cobalt2",
        "Vesper",
        "Flexoki Dark",
        "Melange Dark",
        "Xcode Dark",
        "Aura",
        "Dark Modern",
        "Oxocarbon",
        "Gruber Darker",
        "Jellybeans",
        "Horizon",
        "Embark",
        "Srcery",
        "Terafox",
        "Modus Vivendi",
        "Vercel",
        "Poimandres",
        "Matte Black",
        "Carbonfox",
        "Sonokai",
        "Shades Of Purple",
        "Zenburn",
        "Blue Matrix",
        "Homebrew",
        "IR Black",
        "Ocean",
        "Espresso",
        "traffic",
        "Miasma",
        "Arthur",
        "Catppuccin Latte",
        "GitHub Light Default",
        "Rose Pine Dawn",
        "Gruvbox Light",
        "iTerm2 Solarized Light",
        "Atom One Light",
        "Flexoki Light",
        "Kanagawa Lotus",
        "Xcode Light",
        "Monokai Pro Light",
        "Iceberg Light",
        "Melange Light",
        "One Half Light",
        "Modus Operandi",
        "Bluloco Light",
    ]
}
