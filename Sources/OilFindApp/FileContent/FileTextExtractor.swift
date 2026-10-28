import Foundation
import PDFKit
import AppKit

enum FileTextExtractor {
    static let maxTextFileSize: Int = 8 * 1024 * 1024
    static let maxPDFFileSize: Int = 16 * 1024 * 1024
    static let maxPDFPages: Int = 200

    /// Reads text from a file at the given URL if it matches supported text, code, RTF, or PDF formats.
    static func extractText(from url: URL, ext: String, isCancelled: () -> Bool = { false }) -> String? {
        guard !isCancelled() else { return nil }
        let extLower = ext.lowercased()

        if extLower == "pdf" {
            return extractPDF(from: url, isCancelled: isCancelled)
        } else if extLower == "rtf" || extLower == "rtfd" {
            return extractRTF(from: url, isCancelled: isCancelled)
        } else {
            return extractPlainText(from: url, isCancelled: isCancelled)
        }
    }

    private static func extractPlainText(from url: URL, isCancelled: () -> Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let firstChunk = try? handle.read(upToCount: 4096), !firstChunk.isEmpty else { return nil }
        // Check for binary null bytes
        if firstChunk.contains(0) { return nil }

        var fullData = firstChunk
        if firstChunk.count == 4096 {
            if let rest = try? handle.read(upToCount: maxTextFileSize - firstChunk.count), !rest.isEmpty {
                if rest.contains(0) { return nil }
                fullData.append(rest)
            }
        }

        if isCancelled() { return nil }
        if let text = String(data: fullData, encoding: .utf8) {
            return clean(text)
        }
        if let text = String(data: fullData, encoding: .isoLatin1) {
            return clean(text)
        }
        return nil
    }

    private static func extractPDF(from url: URL, isCancelled: () -> Bool) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let count = min(doc.pageCount, maxPDFPages)
        var text = ""
        text.reserveCapacity(min(count * 512, 128 * 1024))

        for i in 0..<count {
            if isCancelled() { return nil }
            if let page = doc.page(at: i), let pageString = page.string {
                text.append(pageString)
                text.append("\n")
            }
        }
        return text.isEmpty ? nil : clean(text)
    }

    private static func extractRTF(from url: URL, isCancelled: () -> Bool) -> String? {
        autoreleasepool {
            guard !isCancelled() else { return nil }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: url.pathExtension.lowercased() == "rtfd" ? NSAttributedString.DocumentType.rtfd : NSAttributedString.DocumentType.rtf
            ]
            guard let attrString = try? NSAttributedString(url: url, options: options, documentAttributes: nil) else { return nil }
            return clean(attrString.string)
        }
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
