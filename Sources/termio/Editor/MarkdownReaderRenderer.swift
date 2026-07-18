import Foundation

/// Assembles a self-contained HTML document for `MarkdownReaderView`: the reader `<head>`
/// (viewport, theme variables, reading stylesheet) wrapped around `TraceMarkdown`'s HTML.
///
/// The stylesheet is a document-reading skin — narrow measure, generous vertical rhythm, a
/// clear type scale — the Apple-docs / iA-Writer register, distinct from the session
/// trace's dense dashboard CSS. All colors come through `var(--…)` filled from the active
/// `TraceTheme`, so the page tracks whatever chrome theme termio is on.
enum MarkdownReaderRenderer {
    static func document(_ source: String, theme: TraceTheme) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(themeVariables(theme))
        \(css)
        </style>
        </head>
        <body class="reader">
        \(TraceMarkdown.html(source))
        </body>
        </html>
        """
    }

    /// The live termio theme injected as CSS custom properties; the stylesheet references
    /// them, so the reader always matches the app's current colors.
    private static func themeVariables(_ t: TraceTheme) -> String {
        """
        :root {
          color-scheme: \(t.isDark ? "dark" : "light");
          --bg: \(t.background);
          --panel: \(t.panel);
          --fg: \(t.foreground);
          --muted: \(t.secondary);
          --accent: \(t.accent);
          --line: \(t.isDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.10)");
          --soft: \(t.isDark ? "rgba(255,255,255,0.045)" : "rgba(0,0,0,0.035)");
        }
        """
    }

    /// The reading stylesheet. Metrics follow Tailwind `prose` (measure, rhythm, scale)
    /// tuned to an Apple/iA register; system SF for now (a bundled iA Writer face is a
    /// later pass). Only `{`/`}` literals — interpolation is solely `\(…)`, no backslashes.
    private static let css = """
    * { box-sizing: border-box; }
    body.reader {
      max-width: 680px; margin: 0 auto; padding: 48px 32px 140px;
      background: var(--bg); color: var(--fg);
      font: 17px/1.7 -apple-system, "SF Pro Text", system-ui, sans-serif;
      -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
      font-feature-settings: "kern", "liga", "calt";
    }
    .reader > *:first-child { margin-top: 0; }
    .reader > *:last-child { margin-bottom: 0; }
    .reader h1 { font-size: 30px; font-weight: 700; letter-spacing: -0.021em; line-height: 1.15; margin: 0 0 0.5em; }
    .reader h2 { font-size: 22px; font-weight: 650; letter-spacing: -0.014em; line-height: 1.25;
      margin: 2em 0 0.6em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
    .reader h3 { font-size: 18px; font-weight: 650; margin: 1.7em 0 0.4em; }
    .reader h4, .reader h5, .reader h6 { font-size: 16px; font-weight: 650; margin: 1.5em 0 0.4em; }
    .reader p { margin: 0 0 1.15em; }
    .reader a { color: var(--accent); text-decoration: none; }
    .reader a:hover { text-decoration: underline; text-underline-offset: 2px; }
    .reader strong { font-weight: 680; }
    .reader em { font-style: italic; }
    .reader del { color: var(--muted); }
    .reader blockquote { margin: 1.3em 0; padding: 2px 0 2px 18px;
      border-left: 3px solid var(--accent); color: var(--muted); }
    .reader ul, .reader ol { margin: 0 0 1.15em; padding-left: 1.5em; }
    .reader li { margin: 0.3em 0; }
    .reader li > ul, .reader li > ol { margin: 0.3em 0; }
    .reader code { font: 0.88em ui-monospace, "SF Mono", Menlo, monospace;
      background: var(--soft); border: 1px solid var(--line); border-radius: 5px; padding: 1px 5px; }
    .reader pre { background: var(--soft); border: 1px solid var(--line); border-radius: 12px;
      padding: 16px 18px; margin: 1.3em 0; overflow-x: auto; }
    .reader pre code { background: none; border: none; padding: 0; font-size: 13.5px; line-height: 1.55; }
    .reader img { max-width: 100%; border-radius: 10px; border: 1px solid var(--line); margin: 0.5em 0; }
    .reader table { border-collapse: collapse; width: 100%; margin: 1.3em 0; font-size: 15px; display: block; overflow-x: auto; }
    .reader th, .reader td { border: 1px solid var(--line); padding: 8px 14px; text-align: left; }
    .reader th { background: var(--soft); font-weight: 600; }
    .reader hr { border: none; border-top: 1px solid var(--line); margin: 2.2em 0; }
    .reader .image { color: var(--muted); font-size: 15px; }
    """
}
