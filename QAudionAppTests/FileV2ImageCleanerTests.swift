import XCTest
import ImageIO
import UniformTypeIdentifiers
import QAudionEngine
@testable import QAudionApp

/// The cleaned copy of a picture (`FileV2ImageCleaner`): the formats the engine's stripper copies stay as they are but for their
/// metadata, everything else goes through ImageIO with the orientation applied and no metadata handed to the encoder, and what is not
/// a picture is not cleanable (it is never sent as it is). The pictures are made here with ImageIO and carry a position, a make, a
/// model and a comment; the OUTPUT is searched for them. Pure: no Keychain, no network, no device.
final class FileV2ImageCleanerTests: XCTestCase {

    private enum TestError: Error {
        case noContext
        case noImage
        case noEncoder
    }

    /// A picture whose left half is red and right half blue, so that a turned copy differs from an upright one.
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo) else { throw TestError.noContext }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = context.makeImage() else { throw TestError.noImage }
        return image
    }

    /// What a camera writes that must not leave the device: a position, a make and a model, a comment.
    private func secretProperties(orientation: Int) -> [CFString: Any] {
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "CanonXYZ-Make", kCGImagePropertyTIFFModel: "EOS-Model-9000"]
        let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "COMMENT-SECRET"]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 45.5, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 12.5, kCGImagePropertyGPSLongitudeRef: "E"
        ]
        return [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyGPSDictionary: gps
        ]
    }

    private func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw TestError.noEncoder
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestError.noEncoder }
        return data as Data
    }

    private func properties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private func assertClean(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let found = properties(of: data) ?? [:]
        XCTAssertNil(found[kCGImagePropertyGPSDictionary], "no position", file: file, line: line)
        let tiff = found[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake], "no make", file: file, line: line)
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel], "no model", file: file, line: line)
        for secret in ["CanonXYZ-Make", "EOS-Model-9000", "COMMENT-SECRET"] {
            XCTAssertNil(data.range(of: Data(secret.utf8)), "a secret survived: \(secret)", file: file, line: line)
        }
    }

    private func sizeAndOrientation(of data: Data) -> (width: Int, height: Int, orientation: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let info = FileV2ImageCleaner.readInfo(of: source) else {
            return nil
        }
        return (info.width, info.height, info.orientation)
    }

    // MARK: A format the stripper copies

    func test_aJpegWithLocationAndDeviceDataLeavesWithoutThem_keepsItsOrientation_andIsCopiedNotReencoded() throws {
        let input = try encode(makeImage(width: 40, height: 20), as: .jpeg, properties: secretProperties(orientation: 6))
        XCTAssertNotNil(properties(of: input)?[kCGImagePropertyGPSDictionary], "the test picture really holds a position")
        XCTAssertNotNil(input.range(of: Data("CanonXYZ-Make".utf8)), "and a make")

        let cleaned = try FileV2ImageCleaner.clean(input, policy: .chatPhoto)

        XCTAssertEqual(cleaned.format, .jpeg)
        assertClean(cleaned.data)
        XCTAssertEqual(sizeAndOrientation(of: cleaned.data)?.orientation, 6, "still shown the right way up")
        XCTAssertEqual(cleaned.data, try ImageMetadataStripper.strip(input).data, "copied by the stripper, not encoded again")
    }

    func test_aPictureSentAsAFileKeepsItsSize_andIsStillCopiedWithoutReencoding() throws {
        let input = try encode(makeImage(width: 3000, height: 1500), as: .jpeg, properties: secretProperties(orientation: 1))
        let cleaned = try FileV2ImageCleaner.clean(input, policy: .pickedFile)
        assertClean(cleaned.data)
        XCTAssertEqual(cleaned.data, try ImageMetadataStripper.strip(input).data)
        let size = try XCTUnwrap(sizeAndOrientation(of: cleaned.data))
        XCTAssertEqual(size.width, 3000)
        XCTAssertEqual(size.height, 1500)
    }

    // MARK: Above the limits of the chat, and formats the stripper does not handle

    func test_aLargePhotoIsScaledToTheLimitsOfTheChat_turnedUpright_andHasNoMetadata() throws {
        // 3000 x 1500 pixels shot sideways (orientation 6): shown as 1500 x 3000
        let input = try encode(makeImage(width: 3000, height: 1500), as: .jpeg, properties: secretProperties(orientation: 6))
        let cleaned = try FileV2ImageCleaner.clean(input, policy: .chatPhoto)
        XCTAssertEqual(cleaned.format, .jpeg)
        assertClean(cleaned.data)
        let size = try XCTUnwrap(sizeAndOrientation(of: cleaned.data))
        XCTAssertEqual(max(size.width, size.height), FileV2MediaPreparer.maxImageSide)
        XCTAssertGreaterThan(size.height, size.width, "the orientation was applied to the pixels")
        XCTAssertEqual(size.orientation, 1)
    }

    func test_aFormatTheStripperDoesNotHandleIsReencodedWithoutMetadata_theOrientationAppliedToThePixels() throws {
        let input = try encode(makeImage(width: 40, height: 20), as: .tiff, properties: secretProperties(orientation: 6))
        XCTAssertNil(try? ImageMetadataStripper.strip(input), "a TIFF is not copied by the stripper")
        XCTAssertNotNil(properties(of: input)?[kCGImagePropertyGPSDictionary], "the test picture really holds a position")

        let cleaned = try FileV2ImageCleaner.clean(input, policy: .pickedFile)

        XCTAssertTrue([PictureFormat.jpeg, .png].contains(cleaned.format), "JPEG, or PNG when the encoder saw transparency")
        XCTAssertEqual(ImageMetadataStripper.sniff(cleaned.data), cleaned.format, "the bytes are of the format they say")
        assertClean(cleaned.data)
        let size = try XCTUnwrap(sizeAndOrientation(of: cleaned.data))
        XCTAssertEqual(size.width, 20)
        XCTAssertEqual(size.height, 40)
        XCTAssertEqual(size.orientation, 1)
    }

    // MARK: What is not a picture

    func test_somethingThatIsNotAPictureIsNotCleanable_neverReturnedAsIs() {
        let inputs: [Data] = [
            Data(),
            Data("hello".utf8),
            Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8),
            Data("%PDF-1.7".utf8)
        ]
        for input in inputs {
            XCTAssertThrowsError(try FileV2ImageCleaner.clean(input, policy: .pickedFile)) { error in
                XCTAssertEqual(error as? FileV2ImageCleaner.CleanError, .notCleanable)
            }
        }
    }

    // MARK: Names and files

    func test_theNameOfACleanedCopyFollowsItsFormat() {
        XCTAssertEqual(FileV2ImageCleaner.name(for: "Photo.HEIC", format: .jpeg), "Photo.jpg")
        XCTAssertEqual(FileV2ImageCleaner.name(for: "scan.final.png", format: .png), "scan.final.png")
        XCTAssertEqual(FileV2ImageCleaner.name(for: "", format: .gif), "IMG.gif")
        XCTAssertEqual(FileV2ImageCleaner.name(for: "noextension", format: .webp), "noextension.webp")
    }

    func test_aFileIsAPictureWhenItsNameOrItsFirstBytesSayItIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        func file(_ name: String, _ content: Data) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try content.write(to: url)
            return url
        }
        let jpegBytes = try encode(makeImage(width: 8, height: 8), as: .jpeg, properties: [:])
        XCTAssertTrue(FileV2ImageCleaner.isPicture(at: try file("holiday.jpg", jpegBytes)), "by its name")
        XCTAssertTrue(FileV2ImageCleaner.isPicture(at: try file("holiday.heic", Data([0, 0, 0, 0]))), "by its name, whatever it holds")
        XCTAssertTrue(FileV2ImageCleaner.isPicture(at: try file("holiday", jpegBytes)), "by its first bytes")
        XCTAssertTrue(FileV2ImageCleaner.isPicture(at: try file("holiday.bin", jpegBytes)), "by its first bytes, whatever its name says")
        XCTAssertFalse(FileV2ImageCleaner.isPicture(at: try file("contract.pdf", Data("%PDF-1.7 text".utf8))))
        XCTAssertFalse(FileV2ImageCleaner.isPicture(at: try file("notes.txt", Data("plain text, not a picture".utf8))))
        XCTAssertFalse(FileV2ImageCleaner.isPicture(at: directory.appendingPathComponent("missing.dat")))
    }
}
