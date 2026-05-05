//
//  MarkdownHTML.swift
//  md-preview
//

import Foundation
import Markdown

enum MarkdownHTML {
    struct RenderedHTML {
        let html: String
        let containsMath: Bool
        let containsMermaid: Bool
    }

    static func makeHTML(from markdown: String,
                         allowsScroll: Bool = false,
                         assetBaseHref: String? = nil) -> String {
        render(markdown: markdown,
               allowsScroll: allowsScroll,
               assetBaseHref: assetBaseHref).html
    }

    static func render(markdown: String,
                       allowsScroll: Bool = false,
                       assetBaseHref: String? = nil) -> RenderedHTML {
        let body = MarkdownFrontmatter.split(markdown).body
        let math = extractMath(from: body)
        let footnotes = extractFootnotes(from: math.processedMarkdown)
        let formatted = EscapingHTMLFormatter.format(footnotes.markdown)
        let withFootnoteReferences = renderFootnoteReferences(in: formatted, footnotes: footnotes)
        let withFootnotes = appendFootnoteSection(to: withFootnoteReferences, footnotes: footnotes)
        let mermaidResult = renderMermaidBlocks(in: withFootnotes)
        let mathResult = renderMathBlocks(in: mermaidResult.html, with: math)
        let bodyHTML = injectHeadingIDs(in: mathResult.html)
        let scrollOverride = allowsScroll ? """
        <style>
        html, body { overflow: auto !important; }
        ::-webkit-scrollbar { display: initial !important; width: auto !important; height: auto !important; }
        </style>
        """ : ""
        let baseTag = assetBaseHref.map { "<base href=\"\($0)\">" } ?? ""
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(baseTag)
        <style>\(stylesheet)</style>
        \(scrollOverride)
        \(mathResult.containsMath ? katexHead : "")
        \(mermaidResult.containsMermaid ? mermaidScript : "")
        </head>
        <body>
        <article class="markdown-body">
        \(bodyHTML)
        </article>
        </body>
        </html>
        """
        return RenderedHTML(
            html: html,
            containsMath: mathResult.containsMath,
            containsMermaid: mermaidResult.containsMermaid
        )
    }

    // MARK: - Footnotes

    private struct FootnoteExtraction {
        let markdown: String
        let definitions: [String: FootnoteDefinition]
        let references: [FootnoteReference]
        let orderedLabels: [String]
        let noteIDsByLabel: [String: String]
        let referenceIDsByLabel: [String: [String]]
    }

    private struct FootnoteDefinition {
        let label: String
        let markdown: String
    }

    private struct FootnoteDefinitionExtraction {
        let markdown: String
        let definitions: [String: FootnoteDefinition]
    }

    private struct FootnoteReference {
        let token: String
        let canonicalLabel: String
        let displayNumber: Int
        let noteID: String
        let referenceID: String
    }

    private struct MarkdownFence {
        let marker: Character
        let length: Int
    }

    private struct FootnoteIDAllocator {
        private var usedSlugs: Set<String> = []

        mutating func slug(for label: String) -> String {
            var slug = ""
            var previousWasSeparator = false

            for scalar in label.lowercased().unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    slug.unicodeScalars.append(scalar)
                    previousWasSeparator = false
                } else if scalar.value == 45 || scalar.value == 95 {
                    if !slug.isEmpty {
                        slug.unicodeScalars.append(scalar)
                        previousWasSeparator = false
                    }
                } else if !slug.isEmpty, !previousWasSeparator {
                    slug.append("-")
                    previousWasSeparator = true
                }
            }

            slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            if slug.isEmpty {
                slug = "note"
            }

            let base = slug
            var suffix = 2
            while usedSlugs.contains(slug) {
                slug = "\(base)-\(suffix)"
                suffix += 1
            }
            usedSlugs.insert(slug)
            return slug
        }
    }

    private static let footnoteDefinitionRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^[ \t]{0,3}\[\^([^\]\r\n]+)\]:[ \t]?(.*)$"#)
    }()

    private static func extractFootnotes(from markdown: String) -> FootnoteExtraction {
        let definitionExtraction = extractFootnoteDefinitions(from: markdown)
        guard !definitionExtraction.definitions.isEmpty else {
            return FootnoteExtraction(
                markdown: definitionExtraction.markdown,
                definitions: [:],
                references: [],
                orderedLabels: [],
                noteIDsByLabel: [:],
                referenceIDsByLabel: [:]
            )
        }

        var references: [FootnoteReference] = []
        var orderedLabels: [String] = []
        var noteIDsByLabel: [String: String] = [:]
        var referenceIDsByLabel: [String: [String]] = [:]
        var referenceCountsByLabel: [String: Int] = [:]
        var allocator = FootnoteIDAllocator()

        let processedMarkdown = replaceFootnoteReferences(
            in: definitionExtraction.markdown,
            definitions: definitionExtraction.definitions
        ) { canonicalLabel, originalLabel in
            if noteIDsByLabel[canonicalLabel] == nil {
                let slug = allocator.slug(for: originalLabel)
                noteIDsByLabel[canonicalLabel] = "fn-\(slug)"
                orderedLabels.append(canonicalLabel)
            }

            let count = (referenceCountsByLabel[canonicalLabel] ?? 0) + 1
            referenceCountsByLabel[canonicalLabel] = count

            let noteID = noteIDsByLabel[canonicalLabel] ?? "fn-note"
            let referenceID = count == 1
                ? "fnref-\(String(noteID.dropFirst(3)))"
                : "fnref-\(String(noteID.dropFirst(3)))-\(count)"
            let displayNumber = orderedLabels.firstIndex(of: canonicalLabel).map { $0 + 1 } ?? 1
            let token = "MdPreviewFootnoteRef\(references.count)Token"

            references.append(FootnoteReference(
                token: token,
                canonicalLabel: canonicalLabel,
                displayNumber: displayNumber,
                noteID: noteID,
                referenceID: referenceID
            ))
            referenceIDsByLabel[canonicalLabel, default: []].append(referenceID)
            return token
        }

        return FootnoteExtraction(
            markdown: processedMarkdown,
            definitions: definitionExtraction.definitions,
            references: references,
            orderedLabels: orderedLabels,
            noteIDsByLabel: noteIDsByLabel,
            referenceIDsByLabel: referenceIDsByLabel
        )
    }

    private static func extractFootnoteDefinitions(from markdown: String) -> FootnoteDefinitionExtraction {
        let lines = markdown.components(separatedBy: "\n")
        var outputLines: [String] = []
        outputLines.reserveCapacity(lines.count)

        var definitions: [String: FootnoteDefinition] = [:]
        var activeFence: MarkdownFence?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let fence = activeFence {
                outputLines.append(line)
                if closesFence(line, opening: fence) {
                    activeFence = nil
                }
                index += 1
                continue
            }

            if let fence = fenceMarker(in: line) {
                activeFence = fence
                outputLines.append(line)
                index += 1
                continue
            }

            guard let definitionStart = parseFootnoteDefinitionStart(line) else {
                outputLines.append(line)
                index += 1
                continue
            }

            let canonicalLabel = canonicalFootnoteLabel(definitionStart.label)
            guard !canonicalLabel.isEmpty else {
                outputLines.append(line)
                index += 1
                continue
            }

            var contentLines = [definitionStart.body]
            index += 1

            while index < lines.count {
                let continuation = lines[index]
                if isFootnoteContinuationLine(continuation) {
                    contentLines.append(stripFootnoteContinuationIndent(continuation))
                    index += 1
                    continue
                }

                if continuation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   index + 1 < lines.count,
                   isFootnoteContinuationLine(lines[index + 1]) {
                    contentLines.append("")
                    index += 1
                    continue
                }

                break
            }

            if definitions[canonicalLabel] == nil {
                let definitionMarkdown = contentLines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                definitions[canonicalLabel] = FootnoteDefinition(
                    label: definitionStart.label,
                    markdown: definitionMarkdown
                )
            }
        }

        return FootnoteDefinitionExtraction(
            markdown: outputLines.joined(separator: "\n"),
            definitions: definitions
        )
    }

    private static func parseFootnoteDefinitionStart(_ line: String) -> (label: String, body: String)? {
        let nsLine = line as NSString
        guard let match = footnoteDefinitionRegex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: nsLine.length)
        ) else { return nil }

        let label = nsLine
            .substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = nsLine.substring(with: match.range(at: 2))
        return (label, body)
    }

    private static func replaceFootnoteReferences(
        in markdown: String,
        definitions: [String: FootnoteDefinition],
        replacement: (String, String) -> String
    ) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var outputLines: [String] = []
        outputLines.reserveCapacity(lines.count)
        var activeFence: MarkdownFence?

        for line in lines {
            if let fence = activeFence {
                outputLines.append(line)
                if closesFence(line, opening: fence) {
                    activeFence = nil
                }
                continue
            }

            if let fence = fenceMarker(in: line) {
                activeFence = fence
                outputLines.append(line)
                continue
            }

            outputLines.append(replaceFootnoteReferencesInLine(
                line,
                definitions: definitions,
                replacement: replacement
            ))
        }

        return outputLines.joined(separator: "\n")
    }

    private static func replaceFootnoteReferencesInLine(
        _ line: String,
        definitions: [String: FootnoteDefinition],
        replacement: (String, String) -> String
    ) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var index = line.startIndex

        while index < line.endIndex {
            if line[index] == "`" {
                if let codeEnd = matchingInlineCodeSpanEnd(in: line, from: index) {
                    result += line[index..<codeEnd]
                    index = codeEnd
                    continue
                }

                let runEnd = backtickRunEnd(in: line, from: index)
                result += line[index..<runEnd]
                index = runEnd
                continue
            }

            if line[index] == "[",
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)] == "^",
               !isImageAltTextStart(in: line, at: index),
               let close = line[line.index(after: index)..<line.endIndex].firstIndex(of: "]") {
                let labelStart = line.index(index, offsetBy: 2)
                let label = String(line[labelStart..<close])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let canonicalLabel = canonicalFootnoteLabel(label)

                if !canonicalLabel.isEmpty, definitions[canonicalLabel] != nil {
                    result += replacement(canonicalLabel, label)
                    index = line.index(after: close)
                    continue
                }
            }

            result.append(line[index])
            index = line.index(after: index)
        }

        return result
    }

    private static func renderFootnoteReferences(in html: String,
                                                 footnotes: FootnoteExtraction) -> String {
        guard !footnotes.references.isEmpty else { return html }
        var rendered = html

        for reference in footnotes.references {
            let referenceHTML = """
            <sup id="\(htmlEscape(reference.referenceID))" class="footnote-ref"><a href="#\(htmlEscape(reference.noteID))" role="doc-noteref" aria-label="Footnote \(reference.displayNumber)">\(reference.displayNumber)</a></sup>
            """
            rendered = rendered.replacingOccurrences(of: reference.token, with: referenceHTML)
        }

        return rendered
    }

    private static func appendFootnoteSection(to html: String,
                                              footnotes: FootnoteExtraction) -> String {
        guard !footnotes.orderedLabels.isEmpty else { return html }

        var section = """

        <section class="footnotes" role="doc-endnotes">
        <ol>

        """

        for canonicalLabel in footnotes.orderedLabels {
            guard let definition = footnotes.definitions[canonicalLabel],
                  let noteID = footnotes.noteIDsByLabel[canonicalLabel] else { continue }

            let referenceIDs = footnotes.referenceIDsByLabel[canonicalLabel] ?? []
            let renderedDefinition = renderFootnoteDefinition(
                definition.markdown,
                referenceIDs: referenceIDs
            )
            section += """
            <li id="\(htmlEscape(noteID))">
            \(renderedDefinition)
            </li>

            """
        }

        section += """
        </ol>
        </section>

        """
        return html + section
    }

    private static func renderFootnoteDefinition(_ markdown: String,
                                                 referenceIDs: [String]) -> String {
        let rendered = EscapingHTMLFormatter.format(markdown)
        let backlinks = referenceIDs.enumerated().map { index, referenceID in
            let suffix = index == 0 ? "" : "<sup>\(index + 1)</sup>"
            return """
            <a href="#\(htmlEscape(referenceID))" class="footnote-backref" aria-label="Back to reference \(index + 1)">&#8617;\(suffix)</a>
            """
        }.joined(separator: " ")

        guard !backlinks.isEmpty else { return rendered }
        guard let insertionPoint = rendered.range(of: "</p>", options: .backwards) else {
            return rendered + backlinks
        }

        var result = rendered
        result.insert(contentsOf: " \(backlinks)", at: insertionPoint.lowerBound)
        return result
    }

    private static func canonicalFootnoteLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isFootnoteContinuationLine(_ line: String) -> Bool {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var spaces = 0
        for character in line {
            if character == "\t" { return true }
            if character == " " {
                spaces += 1
                if spaces >= 2 { return true }
            } else {
                return false
            }
        }
        return false
    }

    private static func stripFootnoteContinuationIndent(_ line: String) -> String {
        guard let first = line.first else { return line }
        if first == "\t" {
            return String(line.dropFirst())
        }

        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces >= 2 else { return line }
        return String(line.dropFirst(min(leadingSpaces, 4)))
    }

    private static func fenceMarker(in line: String) -> MarkdownFence? {
        var index = line.startIndex
        var leadingSpaces = 0

        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return nil }
            index = line.index(after: index)
        }

        guard index < line.endIndex, line[index] == "`" || line[index] == "~" else {
            return nil
        }

        let marker = line[index]
        var length = 0
        while index < line.endIndex, line[index] == marker {
            length += 1
            index = line.index(after: index)
        }

        guard length >= 3 else { return nil }
        return MarkdownFence(marker: marker, length: length)
    }

    private static func closesFence(_ line: String, opening: MarkdownFence) -> Bool {
        guard let marker = fenceMarker(in: line), marker.marker == opening.marker else {
            return false
        }
        return marker.length >= opening.length
    }

    private static func isImageAltTextStart(in line: String, at index: String.Index) -> Bool {
        guard index > line.startIndex else { return false }
        return line[line.index(before: index)] == "!"
    }

    private static func matchingInlineCodeSpanEnd(in line: String,
                                                  from start: String.Index) -> String.Index? {
        let openingLength = backtickRunLength(in: line, from: start)
        var index = line.index(start, offsetBy: openingLength)

        while index < line.endIndex {
            if line[index] != "`" {
                index = line.index(after: index)
                continue
            }

            let closingLength = backtickRunLength(in: line, from: index)
            let runEnd = line.index(index, offsetBy: closingLength)
            if closingLength == openingLength {
                return runEnd
            }
            index = runEnd
        }

        return nil
    }

    private static func backtickRunEnd(in line: String, from start: String.Index) -> String.Index {
        line.index(start, offsetBy: backtickRunLength(in: line, from: start))
    }

    private static func backtickRunLength(in line: String, from start: String.Index) -> Int {
        var index = start
        var length = 0
        while index < line.endIndex, line[index] == "`" {
            length += 1
            index = line.index(after: index)
        }
        return length
    }

    private static let headingTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "<h([1-6])>")
    }()

    private static func injectHeadingIDs(in html: String) -> String {
        let nsHtml = html as NSString
        let matches = headingTagRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return html }

        var result = ""
        result.reserveCapacity(html.count + matches.count * 24)
        var cursor = 0

        for (index, match) in matches.enumerated() {
            let level = nsHtml.substring(with: match.range(at: 1))
            let prefix = nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            result += prefix
            result += "<h\(level) id=\"md-heading-\(index)\">"
            cursor = match.range.location + match.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }
    // MARK: - Math (KaTeX)

    private struct MathExtraction {
        let processedMarkdown: String
        let blocks: [String]
        let inlines: [String]
    }

    private struct MathRenderResult {
        let html: String
        let containsMath: Bool
    }

    private static let blockMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$"#)
    }()

    // Reject leading `\$` (escaped) and require non-whitespace adjacent to
    // delimiters so prose like "$5 and $10" doesn't match.
    private static let inlineMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\$(?=\S)([^\$\n]+?)(?<=\S)\$"#)
    }()

    // Fenced code block. Group 1 = backtick run, group 2 = info string, group 3 = body.
    private static let codeFenceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?m)^(`{3,})[ \t]*([^\n`]*)\n([\s\S]*?)\n\1[ \t]*$"#
        )
    }()

    // Inline code span: matched-length backtick runs that are not adjacent to other
    // backticks. Mirrors CommonMark so spans like `` ` ```math ` `` (single-backtick
    // delimiters around three inner backticks) tokenize correctly.
    private static let inlineCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)([^\n]*?)(?<!`)\1(?!`)"#)
    }()

    // First alternative captures kind+index for a paragraph-wrapped block token
    // (the common case after swift-markdown wraps the standalone token); the
    // second captures a bare token. The wrapper is stripped in either case for
    // block kind to keep the resulting `<div>` out of an enclosing `<p>`.
    private static let mathTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<p>MdPreviewMath(Block|Inline)(\d+)Token</p>|MdPreviewMath(Block|Inline)(\d+)Token"#
        )
    }()

    private static func extractMath(from markdown: String) -> MathExtraction {
        var blocks: [String] = []
        var inlines: [String] = []
        var protected: [String] = []

        let nsMarkdown = markdown as NSString
        let fenceMatches = codeFenceRegex.matches(
            in: markdown,
            range: NSRange(location: 0, length: nsMarkdown.length)
        )
        var afterFences = ""
        afterFences.reserveCapacity(markdown.count)
        var fenceCursor = 0
        for match in fenceMatches {
            afterFences += nsMarkdown.substring(with: NSRange(
                location: fenceCursor,
                length: match.range.location - fenceCursor
            ))
            let info = nsMarkdown
                .substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if info == "math" {
                let body = nsMarkdown.substring(with: match.range(at: 3))
                blocks.append(body)
                // Surround with blank lines so swift-markdown wraps the standalone
                // token in its own <p>, which mathTokenRegex then strips.
                afterFences += "\n\nMdPreviewMathBlock\(blocks.count - 1)Token\n\n"
            } else {
                protected.append(nsMarkdown.substring(with: match.range))
                afterFences += "MdPreviewProtect\(protected.count - 1)Token"
            }
            fenceCursor = match.range.location + match.range.length
        }
        afterFences += nsMarkdown.substring(from: fenceCursor)

        // Inline code spans next, so $..$ inside `` `$x$` `` is not extracted.
        let afterInlineCode = replaceFullMatches(of: inlineCodeRegex, in: afterFences) { full in
            protected.append(full)
            return "MdPreviewProtect\(protected.count - 1)Token"
        }

        let afterBlockMath = replaceMatches(of: blockMathRegex, in: afterInlineCode) { capture in
            defer { blocks.append(capture) }
            return "MdPreviewMathBlock\(blocks.count)Token"
        }
        let afterInlineMath = replaceMatches(of: inlineMathRegex, in: afterBlockMath) { capture in
            defer { inlines.append(capture) }
            return "MdPreviewMathInline\(inlines.count)Token"
        }

        var processed = afterInlineMath
        for (i, original) in protected.enumerated() {
            processed = processed.replacingOccurrences(
                of: "MdPreviewProtect\(i)Token",
                with: original
            )
        }

        return MathExtraction(processedMarkdown: processed, blocks: blocks, inlines: inlines)
    }

    private static func renderMathBlocks(in html: String,
                                         with math: MathExtraction) -> MathRenderResult {
        guard !math.blocks.isEmpty || !math.inlines.isEmpty else {
            return MathRenderResult(html: html, containsMath: false)
        }

        let nsHtml = html as NSString
        let matches = mathTokenRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        var rebuilt = ""
        rebuilt.reserveCapacity(html.count)
        var cursor = 0
        for match in matches {
            rebuilt += nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            let kindRange = match.range(at: 1).location != NSNotFound
                ? match.range(at: 1) : match.range(at: 3)
            let indexRange = match.range(at: 2).location != NSNotFound
                ? match.range(at: 2) : match.range(at: 4)
            let isBlock = nsHtml.substring(with: kindRange) == "Block"
            let index = Int(nsHtml.substring(with: indexRange)) ?? 0
            let latex = isBlock ? math.blocks[index] : math.inlines[index]
            let escaped = htmlEscape(latex)
            rebuilt += isBlock
                ? "<div class=\"math math-display\">\(escaped)</div>"
                : "<span class=\"math math-inline\">\(escaped)</span>"
            cursor = match.range.location + match.range.length
        }
        rebuilt += nsHtml.substring(from: cursor)
        return MathRenderResult(html: rebuilt, containsMath: true)
    }

    private static let katexHead: String = {
        guard let js = bundledVendorResource("katex.min", ext: "js", subdir: "Vendor/KaTeX") else {
            return """
            <script>
            window.addEventListener('load', () => {
                document.querySelectorAll('.math').forEach((node) => {
                    node.classList.add('math-error');
                    node.textContent = 'KaTeX renderer is unavailable.\\n\\n' + node.textContent;
                });
            });
            </script>
            """
        }
        let css = bundledVendorResource("katex.min", ext: "css", subdir: "Vendor/KaTeX") ?? ""
        let copyTex = bundledVendorResource("copy-tex.min", ext: "js", subdir: "Vendor/KaTeX") ?? ""
        let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script")
        let safeCopyTex = copyTex.replacingOccurrences(of: "</script", with: "<\\/script")

        return """
        <style>\(css)</style>
        <script>\(safeJS)</script>
        <script>
        (function() {
            function renderMath() {
                document.querySelectorAll('.math').forEach((el) => {
                    const tex = el.textContent;
                    const display = el.classList.contains('math-display');
                    try {
                        katex.render(tex, el, {
                            displayMode: display,
                            throwOnError: false,
                            output: 'htmlAndMathml'
                        });
                    } catch (err) {
                        el.classList.add('math-error');
                        el.textContent = String((err && err.message) || err);
                    }
                });
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', renderMath, { once: true });
            } else {
                renderMath();
            }
        })();
        </script>
        \(safeCopyTex.isEmpty ? "" : "<script>\(safeCopyTex)</script>")
        """
    }()

    private static func bundledVendorResource(_ name: String,
                                              ext: String,
                                              subdir: String) -> String? {
        let bundles = [Bundle.main, Bundle(for: MarkdownHTMLBundleToken.self)]
        for bundle in bundles {
            let urls = [
                bundle.url(forResource: name, withExtension: ext, subdirectory: subdir),
                bundle.url(forResource: name, withExtension: ext),
            ]
            for url in urls.compactMap({ $0 }) {
                if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            }
        }
        return nil
    }

    private static func replaceMatches(of regex: NSRegularExpression,
                                       in source: String,
                                       transform: (String) -> String) -> String {
        rewrite(matchesOf: regex, in: source, captureGroup: 1, transform: transform)
    }

    private static func replaceFullMatches(of regex: NSRegularExpression,
                                           in source: String,
                                           transform: (String) -> String) -> String {
        rewrite(matchesOf: regex, in: source, captureGroup: 0, transform: transform)
    }

    private static func rewrite(matchesOf regex: NSRegularExpression,
                                in source: String,
                                captureGroup: Int,
                                transform: (String) -> String) -> String {
        let nsSource = source as NSString
        let matches = regex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        guard !matches.isEmpty else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var cursor = 0
        for match in matches {
            result += nsSource.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            result += transform(nsSource.substring(with: match.range(at: captureGroup)))
            cursor = match.range.location + match.range.length
        }
        result += nsSource.substring(from: cursor)
        return result
    }

    private static func htmlEscape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Mermaid

    private struct MermaidRenderResult {
        let html: String
        let containsMermaid: Bool
    }

    private static let mermaidRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<pre><code class="language-mermaid">([\s\S]*?)</code></pre>"#
        )
    }()

    private static func renderMermaidBlocks(in html: String) -> MermaidRenderResult {
        guard html.contains("language-mermaid") else {
            return MermaidRenderResult(html: html, containsMermaid: false)
        }
        let rendered = replaceMatches(of: mermaidRegex, in: html) { diagram in
            """
            <div class="mermaid" role="img" aria-label="Mermaid diagram">
            \(diagram)
            </div>
            """
        }
        return MermaidRenderResult(html: rendered, containsMermaid: true)
    }

    private static let mermaidScript: String = {
        guard let script = bundledVendorResource("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") else {
            return """
            <script>
            window.addEventListener('load', () => {
                document.querySelectorAll('.mermaid').forEach((node) => {
                    node.classList.add('mermaid-error');
                    node.textContent = 'Mermaid renderer is unavailable.\\n\\n' + node.textContent;
                });
            });
            </script>
            """
        }
        let safeScript = script.replacingOccurrences(of: "</script", with: "<\\/script")
        return """
        <script>
        \(safeScript)

        window.addEventListener('load', async () => {
            const darkMode = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
            try {
                mermaid.initialize({
                    startOnLoad: false,
                    theme: darkMode ? 'dark' : 'default',
                    securityLevel: 'strict',
                    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif'
                });
                await mermaid.run({ querySelector: '.mermaid' });
            } catch (error) {
                document.querySelectorAll('.mermaid').forEach((node) => {
                    node.classList.add('mermaid-error');
                });
                console.error('Mermaid rendering failed', error);
            }
        });
        </script>
        """
    }()

    private final class MarkdownHTMLBundleToken {}


    // Mirrors MarkdownUI's Theme.docC. Top-only margins (bottom: 0), Apple SF
    // palette (text #1d1d1f / #f5f5f7, link #0066cc / #2997ff, grid #d2d2d7 /
    // #424245, code bg #f5f5f7 / #2A2828, aside bg #f5f5f7 / #323232), 15px continuous container
    // radius, horizontal-only table borders.
    private static let stylesheet = """
    :root {
        color-scheme: light dark;
        --text: #1d1d1f;
        --secondary: #6e6e73;
        --link: #0066cc;
        --aside-bg: #f5f5f7;
        --aside-border: #696969;
        --code-bg: #f5f5f7;
        --grid: #d2d2d7;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --text: #f5f5f7;
            --secondary: #86868b;
            --link: #2997ff;
            --aside-bg: #323232;
            --aside-border: #9a9a9e;
            --code-bg: #2A2828;
            --grid: #424245;
        }
    }

    * { box-sizing: border-box; }
    mark.md-search-highlight {
        background: #ffd84d;
        color: #1d1d1f;
        -webkit-box-decoration-break: clone;
    }
    mark.md-search-highlight-current {
        background: #ffbf00;
    }
    html, body {
        margin: 0;
        padding: 0;
        overflow: hidden;
    }
    ::-webkit-scrollbar {
        display: none;
        width: 0;
        height: 0;
    }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        font-size: 15px;
        line-height: 1.52;
        color: var(--text);
        background: transparent;
        padding: 32px 40px 48px;
        -webkit-font-smoothing: antialiased;
    }

    article.markdown-body > *:first-child { margin-top: 0 !important; }

    p {
        margin: 0.8em 0 0;
    }

    h1, h2, h3, h4, h5, h6 {
        font-weight: 600;
        line-height: 1.18;
        margin: 1.6em 0 0;
    }
    h1 { font-size: 2em; margin-top: 0.8em; }
    h2 { font-size: 1.88em; line-height: 1.06; }
    h3 { font-size: 1.65em; line-height: 1.07; }
    h4 { font-size: 1.41em; line-height: 1.08; }
    h5 { font-size: 1.29em; line-height: 1.09; }
    h6 { font-size: 1em; line-height: 1.24; }

    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    sup.footnote-ref {
        font-size: 0.72em;
        line-height: 0;
        margin-left: 1px;
        vertical-align: super;
    }
    sup.footnote-ref a {
        text-decoration: none;
    }

    code {
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.88em;
        padding: 0.18em 0.42em;
        background: var(--code-bg);
        border-radius: 6px;
    }
    pre {
        margin: 0.8em 0 0;
        padding: 10px 14px;
        background: var(--code-bg);
        border-radius: 15px;
        overflow-x: auto;
        line-height: 1.45;
    }
    pre code {
        padding: 0;
        background: transparent;
        font-size: 0.88em;
    }
    .mermaid {
        margin: 1.6em 0 0;
        padding: 16px;
        background: var(--code-bg);
        border-radius: 15px;
        overflow-x: auto;
        text-align: center;
    }
    .mermaid svg {
        max-width: 100%;
        height: auto;
    }
    .mermaid-error {
        text-align: left;
        white-space: pre-wrap;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.88em;
    }
    .math-display {
        margin: 1.2em 0 0;
        overflow-x: auto;
        overflow-y: hidden;
    }
    .math-display .katex-display {
        margin: 0;
    }
    .math-error {
        color: #b00020;
        background: var(--code-bg);
        padding: 4px 8px;
        border-radius: 6px;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.88em;
        white-space: pre-wrap;
    }
    @media (prefers-color-scheme: dark) {
        .math-error { color: #ff6e6e; }
    }

    blockquote {
        margin: 1.6em 0 0;
        padding: 14px 16px;
        background: var(--aside-bg);
        border-radius: 15px;
        color: var(--text);
    }
    blockquote > *:first-child { margin-top: 0; }

    ul, ol { margin: 0.8em 0 0; padding-left: 1.6em; }
    li { margin-top: 0.4em; }
    li:first-child { margin-top: 0.8em; }
    li > ul, li > ol { margin-top: 0.4em; }
    li > p:first-child { margin-top: 0; }

    table {
        margin: 1.6em 0 0;
        border-collapse: collapse;
        display: block;
        overflow-x: auto;
        max-width: 100%;
    }
    th, td {
        padding: 9px 10px;
        border-top: 1px solid var(--grid);
        border-bottom: 1px solid var(--grid);
        text-align: left;
    }
    th { font-weight: 600; }

    hr {
        border: 0;
        height: 1px;
        background: var(--grid);
        margin: 2.35em 0;
    }
    .footnotes {
        margin: 2.35em 0 0;
        padding-top: 0.9em;
        border-top: 1px solid var(--grid);
        color: var(--secondary);
        font-size: 0.9em;
    }
    .footnotes ol {
        margin-top: 0;
        padding-left: 1.35em;
    }
    .footnotes li {
        margin-top: 0.45em;
    }
    .footnotes li:first-child {
        margin-top: 0;
    }
    .footnotes p {
        margin-top: 0.35em;
    }
    .footnotes p:first-child {
        margin-top: 0;
    }
    .footnote-backref {
        margin-left: 0.25em;
        white-space: nowrap;
    }
    .footnote-backref sup {
        font-size: 0.72em;
    }

    img {
        display: block;
        max-width: 100%;
        height: auto;
        margin: 1.6em auto;
        border-radius: 10px;
    }
    p img {
        display: inline-block;
        vertical-align: middle;
        margin: 0 0.35em 0.35em 0;
    }
    p > img:only-child {
        display: block;
        margin: 1.6em auto;
    }

    strong { font-weight: 600; }
    em { font-style: italic; }

    """
}
