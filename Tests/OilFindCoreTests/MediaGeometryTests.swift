import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OilFindCore

final class MediaGeometryTests: XCTestCase {
    func testImageOrientationRatioAndFileReplacement() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let portrait = root.appendingPathComponent("Rotated.jpg")
        try image(at: portrait, width: 160, height: 90, orientation: 6)
        try image(at: root.appendingPathComponent("Wide.jpg"), width: 160, height: 90)
        try image(at: root.appendingPathComponent("Square.jpg"), width: 80, height: 80)
        try image(at: root.appendingPathComponent("Tall.jpg"), width: 80, height: 160)
        try Data().write(to: root.appendingPathComponent("Broken.jpg"))
        try Data().write(to: root.appendingPathComponent("Text.txt"))

        let store = try index(root)
        XCTAssertEqual(try find("kind:image orientation:portrait", in: store), ["Rotated.jpg", "Tall.jpg"])
        XCTAssertEqual(try find("kind:image ratio:9:16", in: store), ["Rotated.jpg"])
        XCTAssertEqual(try find("ratio:16:9", in: store), ["Wide.jpg"])
        XCTAssertEqual(try find("orientation:square", in: store), ["Square.jpg"])
        XCTAssertEqual(try find("orientation:LANDSCAPE | orientation:square", in: store), ["Square.jpg", "Wide.jpg"])
        XCTAssertEqual(try find("kind:image !orientation:landscape", in: store), ["Rotated.jpg", "Square.jpg", "Tall.jpg"])
        XCTAssertEqual(try find("kind:image ratio:0:9", in: store), [])
        XCTAssertEqual(Query.parse("kind:image ratio:0:9").diagnostics.first?.kind, .ratio)
        let scoped = Query.parse("in:\"\(root.path)\" kind:image ratio:9:16")
        XCTAssertTrue(scoped.diagnostics.isEmpty)
        XCTAssertEqual(try find(scoped.raw, in: store), ["Rotated.jpg"])
        XCTAssertNil(Searcher.search(Query.parse("orientation:portrait"), in: store, isCancelled: { true }))

        // The metadata cache must see replacements even before the filesystem index catches up.
        try image(at: portrait, width: 160, height: 90)
        XCTAssertEqual(try find("kind:image orientation:portrait", in: store), ["Tall.jpg"])
    }

    func testContainingFoldersAndPreviewUseTheSameMatchingVideo() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let mixed = root.appendingPathComponent("Mixed")
        let unrelated = root.appendingPathComponent("Unrelated")
        let nested = unrelated.appendingPathComponent("Nested")
        for directory in [mixed, nested] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try await video(at: mixed.appendingPathComponent("Rotated.mov"), rotated: true)
        try await video(at: mixed.appendingPathComponent("Wide.mov"), rotated: false)
        try await video(at: unrelated.appendingPathComponent("Wide.mov"), rotated: false)
        try await video(at: nested.appendingPathComponent("Tall.mov"), rotated: true)
        try image(at: unrelated.appendingPathComponent("Tall.jpg"), width: 90, height: 160)

        let store = try index(root)
        XCTAssertEqual(try find("kind:video ratio:9:16", in: store), ["Rotated.mov", "Tall.mov"])
        let query = Query.parse("contains:kind:video orientation:portrait")
        XCTAssertEqual(try find(query.raw, in: store), ["Mixed", "Nested"])
        XCTAssertEqual(try find("contains:ext:mov ratio:9:16", in: store), ["Mixed", "Nested"])
        let mixedID = try XCTUnwrap(store.read { store.indexedID(forPath: mixed.path) })
        XCTAssertEqual(Searcher.folderPreviewFiles(mixedID, matching: query, in: store), ["Rotated.mov"])
        let offline = SearchSource(id: "offline", displayName: "Offline", isOnline: false, store: store)
        XCTAssertEqual(MultiSearcher.search(query, in: [offline])?.total, 0)
    }

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Oil Find Geometry " + UUID().uuidString + ".test", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func index(_ root: URL) throws -> IndexStore {
        let config = IndexConfig(rootPath: root.path)
        return IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
    }

    private func find(_ text: String, in store: IndexStore) throws -> [String] {
        let result = try XCTUnwrap(Searcher.search(Query.parse(text), in: store))
        return store.read { result.items.map { store.name($0) }.sorted() }
    }

    private func image(at url: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func video(at url: URL, rotated: Bool) async throws {
        let width = 160, height = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        if rotated {
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var frame: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &frame), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(frame)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
