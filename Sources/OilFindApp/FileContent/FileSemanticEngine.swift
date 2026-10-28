import Foundation
import NaturalLanguage
import Accelerate

final class FileSemanticEngine {
    static let shared = FileSemanticEngine()

    private let embedding: NLContextualEmbedding?
    private let fallbackSentenceEmbedding: NLEmbedding?
    private let lock = NSLock()
    private var isLoaded = false

    init() {
        if #available(macOS 14.0, *) {
            self.embedding = NLContextualEmbedding(language: .english)
            self.fallbackSentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
        } else {
            self.embedding = nil
            self.fallbackSentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
    }

    var isAvailable: Bool {
        embedding?.hasAvailableAssets == true || fallbackSentenceEmbedding != nil
    }

    private func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !isLoaded else { return }
        if #available(macOS 14.0, *), let emb = embedding {
            try? emb.load()
        }
        isLoaded = true
    }

    /// Generates a normalized Float vector for a text query or document excerpt.
    func vector(for text: String, isCancelled: () -> Bool = { false }) -> [Float]? {
        guard !text.isEmpty, !isCancelled() else { return nil }
        ensureLoaded()

        // Truncate to first 2000 chars for semantic summary
        let sample = text.count > 2000 ? String(text.prefix(2000)) : text

        if #available(macOS 14.0, *), let emb = embedding, emb.hasAvailableAssets {
            do {
                let result = try emb.embeddingResult(for: sample, language: .english)
                let dim = emb.dimension
                var sum = [Double](repeating: 0, count: dim)
                var count = 0

                result.enumerateTokenVectors(in: sample.startIndex..<sample.endIndex) { vec, _ in
                    if isCancelled() { return false }
                    vDSP_vaddD(sum, 1, vec, 1, &sum, 1, vDSP_Length(dim))
                    count += 1
                    return true
                }

                if count > 0 && !isCancelled() {
                    var factor = 1.0 / Double(count)
                    vDSP_vsmulD(sum, 1, &factor, &sum, 1, vDSP_Length(dim))
                    var norm: Double = 0
                    vDSP_svesqD(sum, 1, &norm, vDSP_Length(dim))
                    norm = sqrt(norm)
                    if norm > 0 {
                        var normFactor = 1.0 / norm
                        vDSP_vsmulD(sum, 1, &normFactor, &sum, 1, vDSP_Length(dim))
                    }
                    return sum.map { Float($0) }
                }
            } catch {
                // fallback below
            }
        }

        if let fallback = fallbackSentenceEmbedding, let doubleVec = fallback.vector(for: sample) {
            let floatVec = doubleVec.map { Float($0) }
            var norm: Float = 0
            vDSP_svesq(floatVec, 1, &norm, vDSP_Length(floatVec.count))
            norm = sqrt(norm)
            if norm > 0 {
                var normFactor = 1.0 / norm
                var normalized = [Float](repeating: 0, count: floatVec.count)
                vDSP_vsmul(floatVec, 1, &normFactor, &normalized, 1, vDSP_Length(floatVec.count))
                return normalized
            }
            return floatVec
        }

        return nil
    }

    /// Converts normalized Float vector into quantized Int8 bytes with scale 127.0.
    func quantize(_ vector: [Float]) -> (dims: Int, scale: Float, bytes: [Int8]) {
        let scale: Float = 127.0
        var bytes = [Int8](repeating: 0, count: vector.count)
        for i in 0..<vector.count {
            bytes[i] = Int8(clamping: Int(round(vector[i] * scale)))
        }
        return (dims: vector.count, scale: scale, bytes: bytes)
    }

    /// Computes cosine similarity between a normalized query vector and quantized document vector.
    func similarity(query: [Float], quantized: UnsafePointer<Int8>, count: Int, scale: Float) -> Float {
        guard count == query.count, scale > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<count {
            dot += Float(quantized[i]) * query[i]
        }
        return dot / scale
    }
}
