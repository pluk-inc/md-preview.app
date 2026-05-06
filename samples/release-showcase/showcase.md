---
title: Markdown Preview — what's new
---

#### Markdown Preview — what's new

<img src="images/app-icon.png" alt="App icon" width="80">

A roundup of recent improvements across the app and Quick Look extension.

###### Added

- **Relative images in Quick Look.** Sibling image files are inlined as `cid:` attachments so they show up in Finder and Spotlight previews.
- **Native printing.** `⌘P` prints the rendered document through WKWebView with proper pagination.
- **Shiki syntax highlighting.** Bundled offline, language-aware colors for fenced code:

  ```swift
  struct ContentView: View {
      var body: some View { Text("Hello").font(.headline) }
  }
  ```

- **KaTeX math.** Inline $e^{i\pi} + 1 = 0$ and display:

  $$\int_{-\infty}^{\infty} e^{-x^2}\, dx = \sqrt{\pi}$$

- **Footnotes.** Definitions and references[^a] now render as a proper footnotes section.
- **Inline markup in headings** — bold, italic, code, and links work inside heading text.
- **Homebrew install.** `brew install --cask pluk-inc/tap/markdown-preview` is the primary path.
- **More Markdown extensions** opened natively: `.mdown`, `.mkd`, `.mkdn`, `.mdwn`, `.mdtxt`, `.mdtext`, `.rmd`.

###### Fixed

- **Task lists render inline**, with no duplicate bullet next to the checkbox:
  - [x] checked
  - [ ] unchecked
- **HTML in body text and code is escaped properly** — `a < b && c > d` and `` `<div>` `` now appear literally instead of disappearing.
- **Math extraction skips code spans and fences** — `` `$PATH` `` renders verbatim.
- **Default `.md` handler claim strengthened** so Markdown Preview wins over apps with weaker associations.

[^a]: Footnotes link back to their references.
