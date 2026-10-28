import Foundation
import PDFKit
import AppKit
import Compression

public struct ContentTerm: Equatable {
    public let text: String
    public let caseSensitive: Bool

    public init(text: String, caseSensitive: Bool) {
        self.text = text
        self.caseSensitive = caseSensitive
    }
}

public enum ContentExtractor {
    // Maximum file sizes for text and document extraction to keep memory and CPU bounded.
    public static let maxTextFileSize: UInt64 = 2 * 1024 * 1024
    public static let maxDocumentFileSize: UInt64 = 24 * 1024 * 1024
    public static let maxStoredTextLength = 128 * 1024

    private static let textExtensions: Set<String> = Set(
        """
        txt md markdown rst adoc org log csv tsv json jsonl jsonc yaml yml toml xml plist
        ini conf cfg env properties sql graphql proto
        swift c h m mm cpp hpp cc cxx js jsx mjs cjs ts tsx py pyi rb go rs java kt kts
        scala groovy gradle php html htm xhtml css scss sass less vue svelte astro
        sh zsh bash fish ps1 bat cmd lua dart cs fs vb r jl pl pm tcl el clj ex exs erl
        hs ml zig nim v sol dockerfile makefile cmake tex bib
        """.split(whereSeparator: \.isWhitespace).map(String.init)
    )

    private static let extensionlessTextNames: Set<String> = [
        "readme", "license", "licence", "copying", "changelog", "authors", "contributors",
        "makefile", "dockerfile", "gemfile", "podfile", "brewfile", "procfile", "justfile",
        ".gitignore", ".gitattributes", ".editorconfig", ".zshrc", ".bashrc", ".zprofile", ".profile"
    ]

    private static let officeZipExtensions: Set<String> = [
        "docx", "pptx", "xlsx", "odt", "ods", "odp"
    ]

    private static let richTextExtensions: Set<String> = [
        "rtf", "rtfd"
    ]

    public static func fileCategory(name: String, kind: UInt8, size: UInt64) -> FileCategory? {
        guard size > 0 else { return nil }
        let lower = name.lowercased()
        let ext: String
        if let dot = lower.lastIndex(of: "."), dot != lower.startIndex {
            ext = String(lower[lower.index(after: dot)...])
        } else {
            ext = ""
        }

        if ext == "pdf" {
            return size <= maxDocumentFileSize ? .pdf : nil
        }
        if officeZipExtensions.contains(ext) {
            return size <= maxDocumentFileSize ? .officeXML : nil
        }
        if richTextExtensions.contains(ext) {
            return size <= maxDocumentFileSize ? .richText : nil
        }
        if kind == 7 || textExtensions.contains(ext) || extensionlessTextNames.contains(lower) {
            return size <= maxTextFileSize ? .plainText : nil
        }
        return nil
    }

    public enum FileCategory {
        case plainText
        case pdf
        case officeXML
        case richText

        public var isDocument: Bool {
            switch self {
            case .plainText: return false
            case .pdf, .officeXML, .richText: return true
            }
        }
    }

    public static func extractText(at path: String, category: FileCategory) -> String? {
        let url = URL(fileURLWithPath: path)
        let raw: String?
        switch category {
        case .plainText:
            raw = extractPlainText(url: url)
        case .pdf:
            raw = extractPDFText(url: url)
        case .officeXML:
            raw = extractOfficeXMLText(url: url)
        case .richText:
            raw = extractRichText(url: url)
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.utf8.count > maxStoredTextLength {
            return String(text.prefix(maxStoredTextLength))
        }
        return text
    }

    private static func extractPlainText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            return nil
        }
        let sampleCount = min(data.count, 4096)
        let hasNullByte = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            return memchr(base, 0, sampleCount) != nil
        }
        if hasNullByte { return nil }
        let slice = data.count > maxStoredTextLength ? data.prefix(maxStoredTextLength) : data[...]
        if let utf8 = String(data: slice, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: slice, encoding: .isoLatin1) {
            return latin1
        }
        return nil
    }

    private static func extractPDFText(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let maxPages = min(doc.pageCount, 15)
        guard maxPages > 0 else { return nil }
        var output = ""
        output.reserveCapacity(min(maxPages * 1024, maxStoredTextLength))
        for index in 0..<maxPages {
            guard let pageText = doc.page(at: index)?.string, !pageText.isEmpty else { continue }
            if !output.isEmpty { output.append("\n") }
            output.append(pageText)
            if output.utf8.count >= maxStoredTextLength { break }
        }
        return output.isEmpty ? nil : output
    }

    private static func extractRichText(url: URL) -> String? {
        guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
            return nil
        }
        return attributed.string
    }

    // Lightweight in-memory ZIP reader for .docx, .pptx, .xlsx, and .odt XML entries.
    private static func extractOfficeXMLText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 22 else {
            return nil
        }
        return data.withUnsafeBytes { raw -> String? in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let count = data.count
            var offset = 0
            var collected = ""

            func readUInt16(_ pos: Int) -> UInt16 {
                UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
            }
            func readUInt32(_ pos: Int) -> UInt32 {
                UInt32(bytes[pos]) | (UInt32(bytes[pos + 1]) << 8) | (UInt32(bytes[pos + 2]) << 16) | (UInt32(bytes[pos + 3]) << 24)
            }

            while offset + 30 <= count {
                let sig = readUInt32(offset)
                guard sig == 0x04034b50 else { break }
                let flags = readUInt16(offset + 6)
                let method = readUInt16(offset + 8)
                let compressedSize = Int(readUInt32(offset + 18))
                let uncompressedSize = Int(readUInt32(offset + 22))
                let nameLen = Int(readUInt16(offset + 26))
                let extraLen = Int(readUInt16(offset + 28))
                let nameStart = offset + 30
                let dataStart = nameStart + nameLen + extraLen
                guard nameStart + nameLen <= count, dataStart <= count else { break }
                // Skip entries with unknown data descriptor length when sizes are zero.
                if (flags & 0x0008) != 0 && compressedSize == 0 {
                    break
                }
                guard compressedSize >= 0, dataStart + compressedSize <= count else { break }

                let entryName = String(decoding: UnsafeBufferPointer(start: bytes.advanced(by: nameStart), count: nameLen), as: UTF8.self)
                let isTargetXML = entryName == "word/document.xml"
                    || entryName == "xl/sharedStrings.xml"
                    || entryName == "content.xml"
                    || (entryName.hasPrefix("ppt/slides/slide") && entryName.hasSuffix(".xml"))

                if isTargetXML, uncompressedSize > 0, uncompressedSize <= 4 * 1024 * 1024 {
                    if method == 0 && compressedSize == uncompressedSize {
                        let xml = String(decoding: UnsafeBufferPointer(start: bytes.advanced(by: dataStart), count: compressedSize), as: UTF8.self)
                        let stripped = stripXMLTags(xml)
                        if !stripped.isEmpty {
                            if !collected.isEmpty { collected.append("\n") }
                            collected.append(stripped)
                        }
                    } else if method == 8 && compressedSize > 0 {
                        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: uncompressedSize)
                        defer { dst.deallocate() }
                        let decoded = compression_decode_buffer(
                            dst, uncompressedSize,
                            bytes.advanced(by: dataStart), compressedSize,
                            nil, COMPRESSION_ZLIB
                        )
                        if decoded > 0 {
                            let xml = String(decoding: UnsafeBufferPointer(start: dst, count: decoded), as: UTF8.self)
                            let stripped = stripXMLTags(xml)
                            if !stripped.isEmpty {
                                if !collected.isEmpty { collected.append("\n") }
                                collected.append(stripped)
                            }
                        }
                    }
                }
                if collected.utf8.count >= maxStoredTextLength { break }
                offset = dataStart + compressedSize
            }
            return collected.isEmpty ? nil : collected
        }
    }

    private static func stripXMLTags(_ xml: String) -> String {
        var out = ""
        out.reserveCapacity(min(xml.utf8.count / 2, maxStoredTextLength))
        var insideTag = false
        var lastWasSpace = true
        for scalar in xml.unicodeScalars {
            if scalar == "<" {
                insideTag = true
                if !lastWasSpace { out.unicodeScalars.append(" "); lastWasSpace = true }
            } else if scalar == ">" {
                insideTag = false
            } else if !insideTag {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if !lastWasSpace { out.unicodeScalars.append(" "); lastWasSpace = true }
                } else {
                    out.unicodeScalars.append(scalar)
                    lastWasSpace = false
                }
            }
        }
        return out
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    public static func matches(body: String, clauses: [[ContentTerm]], excluded: [ContentTerm]) -> Bool {
        guard !clauses.isEmpty else { return false }
        for neg in excluded {
            let options: String.CompareOptions = neg.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
            if body.range(of: neg.text, options: options) != nil {
                return false
            }
        }
        for clause in clauses {
            let satisfied = clause.contains { term in
                let options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
                return body.range(of: term.text, options: options) != nil
            }
            if !satisfied { return false }
        }
        return true
    }

    public static func makePresentation(body: String, terms: [ContentTerm], prefix: String) -> (text: String, highlights: [NSRange]) {
        let nonEmptyTerms = terms.filter { !$0.text.isEmpty }
        guard !nonEmptyTerms.isEmpty else {
            return (prefix, [])
        }
        var firstMatch: Range<String.Index>?
        for term in nonEmptyTerms {
            let options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
            if let range = body.range(of: term.text, options: options) {
                if firstMatch == nil || range.lowerBound < firstMatch!.lowerBound {
                    firstMatch = range
                }
            }
        }
        guard let anchor = firstMatch else {
            return (prefix, [])
        }

        // Extract a window around the first match and collapse whitespace into single spaces.
        let radiusBefore = 24
        let radiusAfter = 56
        let windowStart = body.index(anchor.lowerBound, offsetBy: -radiusBefore, limitedBy: body.startIndex) ?? body.startIndex
        let windowEnd = body.index(anchor.upperBound, offsetBy: radiusAfter, limitedBy: body.endIndex) ?? body.endIndex

        var snippet = ""
        var lastSpace = true
        for ch in body[windowStart..<windowEnd] {
            if ch.isWhitespace || ch.isNewline {
                if !lastSpace { snippet.append(" "); lastSpace = true }
            } else {
                snippet.append(ch)
                lastSpace = false
            }
        }
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingEllipsis = windowStart > body.startIndex ? "…" : ""
        let trailingEllipsis = windowEnd < body.endIndex ? "…" : ""
        let fullText = prefix + leadingEllipsis + snippet + trailingEllipsis

        var highlights: [NSRange] = []
        let searchStart = fullText.index(fullText.startIndex, offsetBy: prefix.count)
        for term in nonEmptyTerms {
            let options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
            var cursor = searchStart
            while cursor < fullText.endIndex,
                  let found = fullText.range(of: term.text, options: options, range: cursor..<fullText.endIndex) {
                let nsRange = NSRange(found, in: fullText)
                if nsRange.length > 0 {
                    highlights.append(nsRange)
                }
                cursor = found.upperBound
            }
        }
        return (fullText, highlights)
    }
}
