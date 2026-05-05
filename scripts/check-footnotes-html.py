#!/usr/bin/env python3
"""Static smoke checks for footnote support in MarkdownHTML.swift."""

from pathlib import Path

markdown_html = Path("md-preview/MarkdownHTML.swift").read_text()
markdown_webview = Path("md-preview/MarkdownWebView.swift").read_text()

checks = {
    "footnote extraction pipeline": "let footnotes = extractFootnotes(from: math.processedMarkdown)" in markdown_html,
    "reference token replacement": "renderFootnoteReferences(in: formatted, footnotes: footnotes)" in markdown_html,
    "endnotes section": 'role="doc-endnotes"' in markdown_html,
    "noteref role": 'role="doc-noteref"' in markdown_html,
    "back reference": "footnote-backref" in markdown_html and "&#8617;" in markdown_html,
    "definition parser": "footnoteDefinitionRegex" in markdown_html,
    "code span protection": "matchingInlineCodeSpanEnd" in markdown_html,
    "fenced code protection": "fenceMarker(in line: String)" in markdown_html,
    "footnote styles": "sup.footnote-ref" in markdown_html and ".footnotes" in markdown_html,
    "fragment navigation": "isInDocumentFragmentNavigation" in markdown_webview,
}

failed = [name for name, ok in checks.items() if not ok]
if failed:
    print("Footnote HTML checks failed:")
    for name in failed:
        print(f"- {name}")
    raise SystemExit(1)

print("Footnote HTML checks passed")

