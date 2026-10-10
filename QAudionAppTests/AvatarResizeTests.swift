import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import QAudionApp

/// Regola delle dimensioni dell'avatar (`AvatarImageRule`: 512 px sul lato lungo, JPEG 0,80, obiettivo 100 KB), copia ridimensionata
/// prima dell'invio (`AvatarSendCopy`) e miniatura per la vista (`AvatarThumbnail`). Le foto sono sintetiche ma non piatte: un
/// gradiente, centinaia di ellissi di tutte le dimensioni e rumore, in modo che la compressione dia numeri paragonabili a una foto.
/// Pure: nessun Keychain, nessuna rete; i file stanno in una cartella temporanea e `UserDefaults` e' un dominio privato.
///
/// Le righe `AVATAR-MEASURE` stampano le misure reali (byte e pixel) di questa esecuzione.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
enum SyntheticPhoto {

    private struct Lcg {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
    }

    enum Failure: Error { case noContext, noImage, noEncoder }

    static func image(width: Int, height: Int, shapes: Int, noise: Int, seed: UInt64 = 7) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                let i = row + x * 4
                pixels[i] = UInt8((x * 255 / width + y * 160 / height) % 256)
                pixels[i + 1] = UInt8((x * 120 / width + y * 255 / height + 40) % 256)
                pixels[i + 2] = UInt8((x + y) * 255 / (width + height))
            }
        }
        var lcg = Lcg(state: seed)
        var result: CGImage?
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            for _ in 0..<shapes {
                let size = lcg.int(8...700)
                let centerX = lcg.int(0...(width - 1))
                let centerY = lcg.int(0...(height - 1))
                let red = CGFloat(lcg.int(0...255)) / 255
                let green = CGFloat(lcg.int(0...255)) / 255
                let blue = CGFloat(lcg.int(0...255)) / 255
                let alpha = CGFloat(lcg.int(120...255)) / 255
                context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
                context.fillEllipse(in: CGRect(x: centerX - size / 2, y: centerY - size / 3, width: size, height: size * 2 / 3))
            }
            result = context.makeImage()
        }
        guard result != nil else { throw Failure.noContext }
        guard noise > 0 else { return try require(result) }
        // The noise pass works on the pixels the context drew into (the buffer is still the context's backing store).
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var index = 0
            while index < width * height * 4 {
                for channel in 0..<3 {
                    let value = Int(bytes[index + channel]) + lcg.int((-noise)...noise)
                    bytes[index + channel] = UInt8(max(0, min(255, value)))
                }
                index += 4
            }
            guard let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            result = context.makeImage()
        }
        return try require(result)
    }

    private static func require(_ image: CGImage?) throws -> CGImage {
        guard let image else { throw Failure.noImage }
        return image
    }

    /// A JPEG of the picture, optionally carrying an orientation tag, a position and a make/model (what a camera writes).
    static func jpeg(
        _ image: CGImage, quality: Double, orientation: Int? = nil, withMetadata: Bool = false
    ) throws -> Data {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.noEncoder }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if withMetadata {
            let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "MakeXYZ", kCGImagePropertyTIFFModel: "Model9"]
            let gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: 45.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 12.5, kCGImagePropertyGPSLongitudeRef: "E"
            ]
            properties[kCGImagePropertyTIFFDictionary] = tiff
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.noEncoder }
        return encoded as Data
    }

    /// The test photo of about 4 MB: 3000 x 2250, 600 shapes, noise of 30 levels, JPEG at 0,95.
    static let large: Data = {
        guard let picture = try? image(width: 3000, height: 2250, shapes: 600, noise: 30),
              let data = try? jpeg(picture, quality: 0.95) else { return Data() }
        return data
    }()

    /// A mid-size picture above the 512 px rule, quick to make.
    static func medium(seed: UInt64) throws -> Data {
        try jpeg(try image(width: 1200, height: 900, shapes: 150, noise: 12, seed: seed), quality: 0.9)
    }

    /// A small picture inside the rule.
    static func small(width: Int = 320, height: Int = 240, orientation: Int? = nil, withMetadata: Bool = false) throws -> Data {
        try jpeg(try image(width: width, height: height, shapes: 30, noise: 4), quality: 0.8,
                 orientation: orientation, withMetadata: withMetadata)
    }
}

final class AvatarImageResizerTests: XCTestCase {

    // MARK: - la scala di qualita'

    func testTheLadderStopsAtTheFirstQualityThatFits() {
        var asked: [Double] = []
        let result = AvatarImageResizer.smallestJPEG(qualities: [0.8, 0.7, 0.6, 0.5], targetBytes: 100) { quality in
            asked.append(quality)
            return Data(repeating: 1, count: Int(quality * 150))
        }
        XCTAssertEqual(asked, [0.8, 0.7, 0.6])
        XCTAssertEqual(result?.count, 90)
    }

    func testTheLadderKeepsTheFirstQualityWhenItAlreadyFits() {
        var asked: [Double] = []
        let result = AvatarImageResizer.smallestJPEG(qualities: [0.8, 0.7], targetBytes: 100) { quality in
            asked.append(quality)
            return Data(repeating: 1, count: 50)
        }
        XCTAssertEqual(asked, [0.8])
        XCTAssertEqual(result?.count, 50)
    }

    func testTheLadderFallsBackToTheSmallestWhenNothingFits() {
        let result = AvatarImageResizer.smallestJPEG(qualities: [0.8, 0.7, 0.6, 0.5], targetBytes: 10) { quality in
            Data(repeating: 1, count: Int(quality * 100))
        }
        XCTAssertEqual(result?.count, 50)
    }

    func testTheLadderSkipsAnEncoderThatFailsAndGivesNilIfAllFail() {
        let partial = AvatarImageResizer.smallestJPEG(qualities: [0.8, 0.7], targetBytes: 100) { quality in
            quality == 0.8 ? nil : Data(repeating: 1, count: 40)
        }
        XCTAssertEqual(partial?.count, 40)
        XCTAssertNil(AvatarImageResizer.smallestJPEG(qualities: [0.8, 0.7], targetBytes: 100) { _ in nil })
    }

    func testTheRuleValues() {
        XCTAssertEqual(AvatarImageRule.maxSide, 512)
        XCTAssertEqual(AvatarImageRule.targetBytes, 100 * 1024)
        XCTAssertEqual(AvatarImageRule.jpegQualities, [0.80, 0.70, 0.60, 0.50])
    }

    func testFitsRuleEdges() {
        XCTAssertTrue(AvatarImageResizer.fitsRule(bytes: 100 * 1024, longSide: 512))
        XCTAssertFalse(AvatarImageResizer.fitsRule(bytes: 100 * 1024 + 1, longSide: 512))
        XCTAssertFalse(AvatarImageResizer.fitsRule(bytes: 100 * 1024, longSide: 513))
        XCTAssertTrue(AvatarImageResizer.fitsRule(bytes: 1, longSide: 1))
    }

    // MARK: - una foto vera da circa 4 MB

    func testALargePhotoIsReducedToTheRule() throws {
        let input = SyntheticPhoto.large
        XCTAssertGreaterThan(input.count, 2_000_000, "the test photo is a realistic multi-megabyte JPEG")
        XCTAssertLessThan(input.count, 9_000_000)
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(input, cleanMetadata: true))
        print("AVATAR-MEASURE resize in=\(input.count) out=\(prepared.data.count) side=\(prepared.longSide) min=\(prepared.shortSide)")
        XCTAssertTrue(prepared.reencoded)
        XCTAssertEqual(prepared.longSide, 512)
        XCTAssertEqual(prepared.shortSide, 384)
        XCTAssertLessThanOrEqual(prepared.data.count, AvatarImageRule.targetBytes)
        XCTAssertEqual(AvatarImageIntegrity.check(prepared.data), .complete)
        XCTAssertNotNil(UIImage(data: prepared.data))
        XCTAssertEqual(AvatarImageGeometry.measure(prepared.data), AvatarImageGeometry.Size(longSide: 512, shortSide: 384))
    }

    func testTheReceiveSideAppliesTheSameRuleToALargePicture() throws {
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(SyntheticPhoto.large, cleanMetadata: false))
        XCTAssertTrue(prepared.reencoded)
        XCTAssertEqual(prepared.longSide, 512)
        XCTAssertLessThanOrEqual(prepared.data.count, AvatarImageRule.targetBytes)
    }

    // MARK: - un file gia' piccolo non si ricodifica

    func testASmallPictureInsideTheRuleIsLeftAlone() throws {
        let small = try SyntheticPhoto.small()
        XCTAssertLessThanOrEqual(small.count, AvatarImageRule.targetBytes)
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(small, cleanMetadata: false))
        XCTAssertFalse(prepared.reencoded)
        XCTAssertEqual(prepared.data, small)
        XCTAssertEqual(prepared.longSide, 320)
        XCTAssertEqual(prepared.shortSide, 240)
        let cleanSmall = try XCTUnwrap(AvatarImageResizer.prepare(small, cleanMetadata: true))
        XCTAssertFalse(cleanSmall.reencoded, "a clean small picture is not re-encoded either")
        XCTAssertEqual(cleanSmall.data, small)
    }

    func testAPictureAtTheEdgeOfTheRuleIsLeftAlone() throws {
        let edge = try SyntheticPhoto.small(width: 512, height: 512)
        guard edge.count <= AvatarImageRule.targetBytes else { throw XCTSkip("the 512 px test picture is above 100 KB here") }
        XCTAssertFalse(try XCTUnwrap(AvatarImageResizer.prepare(edge, cleanMetadata: true)).reencoded)
    }

    func testAPictureJustAboveTheSideLimitIsReduced() throws {
        let wide = try SyntheticPhoto.small(width: 640, height: 320)
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(wide, cleanMetadata: false))
        XCTAssertTrue(prepared.reencoded)
        XCTAssertEqual(prepared.longSide, 512)
        XCTAssertEqual(prepared.shortSide, 256)
    }

    func testAPictureIsNeverEnlarged() throws {
        let tiny = try SyntheticPhoto.small(width: 64, height: 48)
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(tiny, cleanMetadata: true))
        XCTAssertEqual(prepared.longSide, 64)
        XCTAssertEqual(prepared.shortSide, 48)
    }

    // MARK: - orientamento e metadati

    func testOrientationIsAppliedAndMetadataRemovedFromTheCopyThatLeaves() throws {
        let tagged = try SyntheticPhoto.small(width: 320, height: 240, orientation: 6, withMetadata: true)
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(tagged, cleanMetadata: true))
        XCTAssertTrue(prepared.reencoded)
        // Orientation 6 turns the 320 x 240 picture upright: 240 wide, 320 tall.
        XCTAssertEqual(prepared.longSide, 320)
        XCTAssertEqual(prepared.shortSide, 240)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 240)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 320)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
        XCTAssertTrue((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    func testAReceivedPictureInsideTheRuleIsKeptAsItIsEvenWithATag() throws {
        let tagged = try SyntheticPhoto.small(width: 320, height: 240, orientation: 6, withMetadata: true)
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(tagged, cleanMetadata: false))
        XCTAssertFalse(prepared.reencoded)
        XCTAssertEqual(prepared.data, tagged)
    }

    func testMetadataWithoutOrientationStillTriggersTheCleaningOfTheCopyThatLeaves() throws {
        let tagged = try SyntheticPhoto.small(width: 320, height: 240, withMetadata: true)
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(tagged, cleanMetadata: true))
        XCTAssertTrue(prepared.reencoded)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    // MARK: - altro

    func testNotAPictureGivesNil() {
        XCTAssertNil(AvatarImageResizer.prepare(Data([1, 2, 3, 4, 5]), cleanMetadata: true))
        XCTAssertNil(AvatarImageResizer.prepare(Data(), cleanMetadata: false))
    }

    func testATransparentPngIsFlattenedIntoAJpeg() throws {
        let side = 600
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 150, y: 150, width: 300, height: 300))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = try XCTUnwrap(AvatarImageResizer.prepare(encoded as Data, cleanMetadata: true))
        XCTAssertTrue(prepared.reencoded)
        XCTAssertEqual(prepared.longSide, 512)
        XCTAssertEqual(Array(prepared.data.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertNotNil(UIImage(data: prepared.data))
    }
}

final class AvatarSendCopyTests: XCTestCase {

    private func makeRig() throws -> (directory: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-send-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "avatar-send-copy-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        return (directory, defaults)
    }

    private func write(_ data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("self.jpg")
        try data.write(to: url)
        return url
    }

    func testALargeLocalFileIsSentAsAResizedCopyMadeOnce() throws {
        let rig = try makeRig()
        let big = SyntheticPhoto.large
        let source = try write(big, in: rig.directory)
        let first = AvatarSendCopy.prepare(source: source, data: big, defaults: rig.defaults)
        print("AVATAR-MEASURE sendcopy in=\(big.count) out=\(first.data.count) side=\(first.longSide) min=\(first.shortSide)")
        XCTAssertTrue(first.isCopy)
        XCTAssertTrue(first.generated)
        XCTAssertEqual(first.url.lastPathComponent, AvatarSendCopy.copyFileName)
        XCTAssertEqual(try Data(contentsOf: first.url), first.data)
        XCTAssertLessThanOrEqual(first.data.count, AvatarImageRule.targetBytes)
        XCTAssertEqual(first.longSide, 512)

        let second = AvatarSendCopy.prepare(source: source, data: big, defaults: rig.defaults)
        XCTAssertTrue(second.isCopy)
        XCTAssertFalse(second.generated, "the copy is reused, not made again")
        XCTAssertEqual(second.data, first.data)
        XCTAssertEqual(second.url, first.url)
        // The source file is left untouched.
        XCTAssertEqual(try Data(contentsOf: source), big)
    }

    func testAChangedLocalFileMakesANewCopy() throws {
        let rig = try makeRig()
        let first = try SyntheticPhoto.medium(seed: 1)
        let second = try SyntheticPhoto.medium(seed: 2)
        let source = try write(first, in: rig.directory)
        let a = AvatarSendCopy.prepare(source: source, data: first, defaults: rig.defaults)
        let b = AvatarSendCopy.prepare(source: source, data: second, defaults: rig.defaults)
        XCTAssertTrue(a.generated)
        XCTAssertTrue(b.generated)
        XCTAssertNotEqual(a.data, b.data)
        XCTAssertEqual(try Data(contentsOf: b.url), b.data)
    }

    func testASmallLocalFileIsSentAsItIsWithoutACopy() throws {
        let rig = try makeRig()
        let small = try SyntheticPhoto.small()
        let source = try write(small, in: rig.directory)
        let prepared = AvatarSendCopy.prepare(source: source, data: small, defaults: rig.defaults)
        XCTAssertFalse(prepared.isCopy)
        XCTAssertFalse(prepared.generated)
        XCTAssertEqual(prepared.url, source)
        XCTAssertEqual(prepared.data, small)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.directory.appendingPathComponent(AvatarSendCopy.copyFileName).path))
    }

    func testAFileThatIsNotAPictureIsSentAsItWas() throws {
        let rig = try makeRig()
        let junk = Data([9, 8, 7, 6])
        let source = try write(junk, in: rig.directory)
        let prepared = AvatarSendCopy.prepare(source: source, data: junk, defaults: rig.defaults)
        XCTAssertFalse(prepared.isCopy)
        XCTAssertEqual(prepared.url, source)
        XCTAssertEqual(prepared.data, junk)
    }

    func testASmallFileWithAnOrientationTagIsSentAsACleanCopy() throws {
        let rig = try makeRig()
        let tagged = try SyntheticPhoto.small(orientation: 6, withMetadata: true)
        let source = try write(tagged, in: rig.directory)
        let prepared = AvatarSendCopy.prepare(source: source, data: tagged, defaults: rig.defaults)
        XCTAssertTrue(prepared.isCopy)
        XCTAssertNotEqual(prepared.data, tagged)
    }
}

final class AvatarThumbnailTests: XCTestCase {

    func testTargetShortSideForTheCommonCircles() {
        XCTAssertEqual(AvatarThumbnail.targetShortSide(pointSize: 44, scale: 3), 132)
        XCTAssertEqual(AvatarThumbnail.targetShortSide(pointSize: 96, scale: 3), 288)
        XCTAssertEqual(AvatarThumbnail.targetShortSide(pointSize: 44, scale: 2), 88)
        XCTAssertEqual(AvatarThumbnail.targetShortSide(pointSize: 44.4, scale: 3), 134)
        XCTAssertEqual(AvatarThumbnail.targetShortSide(pointSize: 44, scale: 0), 44, "a missing scale counts as 1")
        XCTAssertEqual(AvatarThumbnail.targetShortSide(pointSize: 0, scale: 3), 1)
    }

    func testMaxPixelSizeKeepsTheShortSideAtTheTarget() {
        XCTAssertEqual(AvatarThumbnail.maxPixelSize(longSide: 512, shortSide: 512, targetShortSide: 132), 132)
        XCTAssertEqual(AvatarThumbnail.maxPixelSize(longSide: 512, shortSide: 384, targetShortSide: 132), 176)
        XCTAssertEqual(AvatarThumbnail.maxPixelSize(longSide: 4000, shortSide: 3000, targetShortSide: 132), 176)
    }

    func testMaxPixelSizeNeverEnlarges() {
        XCTAssertEqual(AvatarThumbnail.maxPixelSize(longSide: 64, shortSide: 48, targetShortSide: 132), 64)
        XCTAssertEqual(AvatarThumbnail.maxPixelSize(longSide: 132, shortSide: 132, targetShortSide: 132), 132)
        XCTAssertEqual(AvatarThumbnail.maxPixelSize(longSide: 600, shortSide: 100, targetShortSide: 132), 600)
        XCTAssertEqual(AvatarThumbnail.maxPixelSize(longSide: 0, shortSide: 0, targetShortSide: 132), 1)
    }

    func testDecodedMemoryOfAThumbnailAgainstFullResolution() {
        let thumbnail = AvatarThumbnail.decodedBytes(width: 176, height: 132)
        let full = AvatarThumbnail.decodedBytes(width: 512, height: 384)
        XCTAssertEqual(thumbnail, 92_928)
        XCTAssertEqual(full, 786_432)
        XCTAssertGreaterThan(full / thumbnail, 8)
    }

    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-thumb-\(UUID().uuidString).jpg")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAListCircleDecodesTheShortSideAtThePixelsItNeeds() throws {
        let url = try tempFile(try SyntheticPhoto.small(width: 512, height: 384))
        let image = try XCTUnwrap(AvatarThumbnail.load(url: url, pointSize: 44, scale: 3))
        let cg = try XCTUnwrap(image.cgImage)
        print("AVATAR-MEASURE thumb 512x384 list=44pt@3x px=\(cg.width)x\(cg.height) bytes=\(cg.width * cg.height * 4) full=\(512 * 384 * 4)")
        XCTAssertEqual(cg.height, 132, accuracy: 1)
        XCTAssertEqual(cg.width, 176, accuracy: 1)
    }

    func testALargeCachedFileIsDecodedAtTheCircleSizeNotAtFullResolution() throws {
        let url = try tempFile(SyntheticPhoto.large)
        let image = try XCTUnwrap(AvatarThumbnail.load(url: url, pointSize: 44, scale: 3))
        let cg = try XCTUnwrap(image.cgImage)
        print("AVATAR-MEASURE thumb 3000x2250 list=44pt@3x px=\(cg.width)x\(cg.height) bytes=\(cg.width * cg.height * 4) full=\(3000 * 2250 * 4)")
        XCTAssertEqual(cg.height, 132, accuracy: 1)
        XCTAssertLessThan(cg.width * cg.height * 4, 200_000)
    }

    func testASmallImageIsNotEnlarged() throws {
        let url = try tempFile(try SyntheticPhoto.small(width: 64, height: 48))
        let cg = try XCTUnwrap(AvatarThumbnail.load(url: url, pointSize: 96, scale: 3)?.cgImage)
        XCTAssertEqual(cg.width, 64)
        XCTAssertEqual(cg.height, 48)
    }

    func testTheOrientationTagIsApplied() throws {
        let url = try tempFile(try SyntheticPhoto.small(width: 320, height: 240, orientation: 6))
        let cg = try XCTUnwrap(AvatarThumbnail.load(url: url, pointSize: 44, scale: 3)?.cgImage)
        // Upright the picture is 240 wide and 320 tall: the short side (width) is brought to 132.
        XCTAssertEqual(cg.width, 132, accuracy: 1)
        XCTAssertEqual(cg.height, 176, accuracy: 1)
    }

    func testTheSameRequestIsServedFromTheCache() throws {
        let url = try tempFile(try SyntheticPhoto.small(width: 400, height: 300))
        let first = try XCTUnwrap(AvatarThumbnail.load(url: url, pointSize: 44, scale: 3))
        let second = try XCTUnwrap(AvatarThumbnail.load(url: url, pointSize: 44, scale: 3))
        XCTAssertTrue(first === second)
        let other = try XCTUnwrap(AvatarThumbnail.load(url: url, pointSize: 96, scale: 3))
        XCTAssertFalse(first === other)
    }

    func testAFileThatIsNotAPictureHasNoThumbnail() throws {
        let url = try tempFile(Data([1, 2, 3, 4]))
        XCTAssertNil(AvatarThumbnail.load(url: url, pointSize: 44, scale: 3))
        XCTAssertNil(AvatarThumbnail.load(url: url.appendingPathExtension("missing"), pointSize: 44, scale: 3))
    }
}
