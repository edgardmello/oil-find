import Foundation

struct FileExtensionMatcher {
    private struct ExtensionPattern { let parts: [[[UInt32]]] }
    private var keys: Set<UInt64> = []
    private var patterns: [ExtensionPattern] = []

    init(_ extensions: some Sequence<String>) {
        for ext in extensions {
            // Uppercase variants also cover Unicode expansions such as sharp S.
            for text in [ext, ext.uppercased().precomposedStringWithCanonicalMapping] {
                let bytes = Array(("." + text).utf8)
                let key = bytes.withUnsafeBufferPointer { Classifier.extensionKey($0) }
                if key != 0 { keys.insert(key) }
            }
            let parts = ext.map { character -> [[UInt32]] in
                let text = String(character)
                let forms = [text, text.uppercased(), text.lowercased()].flatMap {
                    [$0.precomposedStringWithCanonicalMapping, $0.decomposedStringWithCanonicalMapping]
                }
                var seen = Set<[UInt32]>()
                return forms.compactMap { form in
                    let folded = form.unicodeScalars.flatMap { scalar -> [UInt32] in
                        scalar.value == 0x130 ? [0x69, 0x307] : [Self.lowercaseScalar(scalar.value)]
                    }
                    return seen.insert(folded).inserted ? folded : nil
                }
            }
            patterns.append(ExtensionPattern(parts: parts))
        }
    }
    func matches(name: UnsafeBufferPointer<UInt8>) -> Bool {
        let key = Classifier.extensionKey(name)
        if key != 0 { return keys.contains(key) }
        guard !patterns.isEmpty, let dot = name.lastIndex(of: 46), dot + 1 < name.count else { return false }
        for pattern in patterns {
            var offset = dot + 1, matches = true
            for variants in pattern.parts {
                var matchedEnd: Int?
                for variant in variants {
                    if let end = Self.matchScalars(variant, in: name, from: offset) { matchedEnd = end; break }
                }
                guard let end = matchedEnd else { matches = false; break }
                offset = end
            }
            if matches && offset == name.count { return true }
        }
        return false
    }
    private static func matchScalars(_ expected: [UInt32], in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var offset = start, position = 0
        while position < expected.count {
            guard offset < bytes.count, let scalar = nextScalar(bytes, offset: &offset),
                  lowercaseScalar(scalar) == expected[position] else { return nil }
            position += 1
            if scalar == 0x130 {
                guard position < expected.count, expected[position] == 0x307 else { return nil }
                position += 1
            }
        }
        return offset
    }
    private static func lowercaseScalar(_ scalar: UInt32) -> UInt32 {
        if scalar < 128 { return scalar >= 65 && scalar <= 90 ? scalar + 32 : scalar }
        // Case data comes from the standard library: libc's locale tables differ between macOS
        // versions and miss pairs such as capital sharp S. A one-scalar mapping stays inline.
        guard let value = Unicode.Scalar(scalar),
              let lower = value.properties.lowercaseMapping.unicodeScalars.first?.value else { return scalar }
        return lower == 0x3c2 ? 0x3c3 : lower
    }
    private static func nextScalar(_ bytes: UnsafeBufferPointer<UInt8>, offset: inout Int) -> UInt32? {
        let first = bytes[offset]; offset += 1
        if first < 128 { return UInt32(first) }
        let remaining: Int, mask: UInt8
        switch first {
        case 0xc2...0xdf: remaining = 1; mask = 0x1f
        case 0xe0...0xef: remaining = 2; mask = 0x0f
        case 0xf0...0xf4: remaining = 3; mask = 0x07
        default: return nil
        }
        guard offset + remaining <= bytes.count else { return nil }
        var value = UInt32(first & mask)
        for _ in 0..<remaining {
            let next = bytes[offset]; offset += 1
            guard next & 0xc0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(next & 0x3f)
        }
        return value
    }
}
