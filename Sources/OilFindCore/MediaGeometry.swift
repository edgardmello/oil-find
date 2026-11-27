import AVFoundation
import Darwin
import Foundation
import ImageIO

public enum MediaGeometryFilter: Equatable {
    case portrait, landscape, square
    case ratio(width: UInt32, height: UInt32)
    case invalid

    fileprivate func matches(_ dimensions: MediaDimensions) -> Bool {
        switch self {
        case .portrait: return dimensions.width < dimensions.height && !dimensions.hasRatio(width: 1, height: 1)
        case .landscape: return dimensions.width > dimensions.height && !dimensions.hasRatio(width: 1, height: 1)
        case .square: return dimensions.hasRatio(width: 1, height: 1)
        case .ratio(let width, let height): return dimensions.hasRatio(width: width, height: height)
        case .invalid: return false
        }
    }
}

struct MediaFilters {
    struct Term {
        let filter: MediaGeometryFilter
        let negated: Bool
    }
    let clauses: [[Term]]

    init(_ query: Query) {
        clauses = query.clauses.compactMap { clause in
            var terms: [Term] = []
            for atom in clause.alternatives {
                if case .media(let filter) = atom.matcher {
                    terms.append(Term(filter: filter, negated: atom.negated))
                }
            }
            guard !terms.isEmpty else { return nil }
            // A media clause applies to an individual file, including inside a containing folder.
            guard terms.count == clause.alternatives.count else { return [Term(filter: .invalid, negated: false)] }
            return terms
        }
    }

    var isEmpty: Bool { clauses.isEmpty }
    var isInvalid: Bool { clauses.contains { $0.allSatisfy { $0.filter == .invalid } } }

    fileprivate func matches(_ dimensions: MediaDimensions) -> Bool {
        clauses.allSatisfy { clause in
            clause.contains { $0.filter.matches(dimensions) != $0.negated }
        }
    }
}

struct MediaCandidate: Sendable {
    var id: UInt32
    var path: String
    var kind: UInt8

    static func supports(_ kind: UInt8) -> Bool { kind == 4 || kind == 5 }
}

private struct MediaDimensions {
    let width: Double, height: Double

    init?(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    func hasRatio(width: UInt32, height: UInt32) -> Bool {
        let lhs = self.width * Double(height), rhs = self.height * Double(width)
        // Presentation dimensions can be fractional for non-square pixels or after a transform.
        return abs(lhs - rhs) <= max(lhs, rhs) * 1e-8
    }
}

enum MediaGeometry {
    private struct Stamp: Equatable {
        let device: Int32, inode: UInt64, size: Int64
        let seconds: Int, nanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private final class CachedDimensions {
        let stamp: Stamp
        let dimensions: MediaDimensions
        init(stamp: Stamp, dimensions: MediaDimensions) {
            self.stamp = stamp
            self.dimensions = dimensions
        }
    }

    private final class Batch: @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        var matches: [UInt32] = []
    }

    private static let cache: NSCache<NSString, CachedDimensions> = {
        let cache = NSCache<NSString, CachedDimensions>()
        cache.countLimit = 32_768
        return cache
    }()

    /// Metadata is loaded outside the index lock, with bounded parallelism and cancellable waits.
    static func matching(_ candidates: [MediaCandidate], filters: MediaFilters,
                         isCancelled: () -> Bool) -> [UInt32]? {
        guard !isCancelled() else { return nil }
        if candidates.isEmpty || filters.isInvalid { return [] }
        let batch = Batch()
        let task = Task.detached(priority: .userInitiated) {
            defer { batch.finished.signal() }
            batch.matches = await withTaskGroup(of: UInt32?.self) { group in
                let workers = min(candidates.count, 6)
                for worker in 0..<workers {
                    group.addTask { await match(candidates[worker], filters: filters) }
                }
                var matches: [UInt32] = []
                var next = workers
                for await match in group {
                    if let match { matches.append(match) }
                    if Task.isCancelled { group.cancelAll(); break }
                    if next < candidates.count {
                        let candidate = candidates[next]
                        group.addTask { await Self.match(candidate, filters: filters) }
                        next += 1
                    }
                }
                return matches
            }
        }
        while batch.finished.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
            if isCancelled() { task.cancel(); return nil }
        }
        return isCancelled() ? nil : batch.matches
    }

    private static func match(_ candidate: MediaCandidate, filters: MediaFilters) async -> UInt32? {
        guard !Task.isCancelled, let stamp = Stamp(candidate.path) else { return nil }
        let key = candidate.path as NSString
        if let cached = cache.object(forKey: key), cached.stamp == stamp {
            return filters.matches(cached.dimensions) ? candidate.id : nil
        }
        let url = URL(fileURLWithPath: candidate.path, isDirectory: false)
        let dimensions = candidate.kind == 4 ? imageDimensions(at: url) : await videoDimensions(at: url)
        guard !Task.isCancelled, Stamp(candidate.path) == stamp else { return nil }
        if let dimensions { cache.setObject(CachedDimensions(stamp: stamp, dimensions: dimensions), forKey: key) }
        return dimensions.map(filters.matches) == true ? candidate.id : nil
    }

    private static func imageDimensions(at url: URL) -> MediaDimensions? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swap = (5...8).contains(orientation)
        return MediaDimensions(width: (swap ? height : width).doubleValue, height: (swap ? width : height).doubleValue)
    }

    private static func videoDimensions(at url: URL) async -> MediaDimensions? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (natural, transform, formats) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            let dimensions = formats.first.map {
                CMVideoFormatDescriptionGetPresentationDimensions($0, usePixelAspectRatio: true, useCleanAperture: true)
            } ?? natural
            let displayed = CGRect(origin: .zero, size: dimensions).applying(transform)
            return MediaDimensions(width: displayed.width, height: displayed.height)
        } catch {
            return nil
        }
    }
}
