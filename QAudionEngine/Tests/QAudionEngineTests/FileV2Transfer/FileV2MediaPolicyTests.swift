import XCTest
@testable import QAudionEngine

/// The pure rules of the media side of file transfer v2: who may download (`FileV2Audience`), what is fetched on arrival
/// (`FileV2AutoDownloadPolicy`), what a descriptor's display hints are worth (`FileV2MediaHints`), how a thumbnail is sized
/// (`FileV2ThumbnailPlan`), and where a received file lives (`FileV2LocalFiles`).
final class FileV2MediaPolicyTests: XCTestCase {

    // MARK: The token scope of a group

    func test_aGroupIsNamedByItsLowercaseDashedUUID_whateverFormItArrivesIn() {
        let dashed = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        XCTAssertEqual(FileV2Audience.forGroup(dashed), .group(dashed))
        XCTAssertEqual(FileV2Audience.forGroup(dashed.uppercased()), .group(dashed))
        XCTAssertEqual(FileV2Audience.forGroup("0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d"), .group(dashed))
        XCTAssertEqual(FileV2Audience.forGroup("0A1B2C3D4E5F4A6B8C7D9E0F1A2B3C4D"), .group(dashed))
    }

    func test_anIdentifierThatIsNotAUUIDIsNotAGroup() {
        let refused = [
            "",
            "group",
            "0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4",                       // 31 characters
            "0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4de",                     // 33 characters
            "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4",                   // 35 characters
            "0a1b2c3d4-e5f-4a6b-8c7d-9e0f1a2b3c4d",                  // hyphen in the wrong place
            "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4g",                  // not hex
            "0a1b2c3d-4e5f-4a6b-8c7d_9e0f1a2b3c4d",                  // wrong separator
            " 0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        ]
        for text in refused {
            XCTAssertNil(FileV2Audience.forGroup(text), "\(text) is not a group id")
        }
    }

    func test_theTokenRequestHasExactlyOneScope() {
        let user = FileV2Audience.recipient("bob").tokenRequest(maxUses: 30)
        XCTAssertEqual(user.recipientUserID, "bob")
        XCTAssertNil(user.groupID)
        XCTAssertEqual(user.maxUses, 30)

        let group = FileV2Audience.forGroup("0A1B2C3D4E5F4A6B8C7D9E0F1A2B3C4D")?.tokenRequest(maxUses: 40)
        XCTAssertEqual(group?.groupID, "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")
        XCTAssertNil(group?.recipientUserID)
        XCTAssertEqual(group?.maxUses, 40)
    }

    func test_anAudienceBuiltByHandIsCheckedBeforeAnythingIsCreated() {
        XCTAssertTrue(FileV2Audience.recipient("bob").isWellFormed)
        XCTAssertFalse(FileV2Audience.recipient("").isWellFormed)
        XCTAssertTrue(FileV2Audience.group("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d").isWellFormed)
        XCTAssertFalse(FileV2Audience.group("0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D").isWellFormed, "upper case is not the wire form")
        XCTAssertFalse(FileV2Audience.group("0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d").isWellFormed, "the hex form is not the wire form")
        XCTAssertTrue(FileV2Audience.group("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d").isGroup)
        XCTAssertFalse(FileV2Audience.recipient("bob").isGroup)
    }

    // MARK: What is fetched on arrival

    func test_avatarsThumbnailsVoiceNotesAndImagesUpTo25MiBAreFetchedOnArrival() {
        let limit = FileV2AutoDownloadPolicy.maxAutomaticBytes
        XCTAssertEqual(limit, 25 * 1024 * 1024)
        for kind in [FileV2Descriptor.Kind.avatar, .thumb, .voice, .image] {
            XCTAssertTrue(FileV2AutoDownloadPolicy.isAutomatic(kind: kind, size: 1), "\(kind)")
            XCTAssertTrue(FileV2AutoDownloadPolicy.isAutomatic(kind: kind, size: limit), "\(kind) at the limit")
            XCTAssertFalse(FileV2AutoDownloadPolicy.isAutomatic(kind: kind, size: limit + 1), "\(kind) above the limit")
        }
    }

    func test_aVideoAndADocumentWaitForATap_whateverTheirSize() {
        for size: UInt64 in [1, 1024, FileV2AutoDownloadPolicy.maxAutomaticBytes, 5 << 30] {
            XCTAssertFalse(FileV2AutoDownloadPolicy.isAutomatic(kind: .video, size: size))
            XCTAssertFalse(FileV2AutoDownloadPolicy.isAutomatic(kind: .file, size: size))
        }
    }

    func test_theThumbnailOfAnImageOrAVideoIsAlwaysFetched() {
        XCTAssertTrue(FileV2AutoDownloadPolicy.fetchesThumbnail(of: .image))
        XCTAssertTrue(FileV2AutoDownloadPolicy.fetchesThumbnail(of: .video))
        XCTAssertFalse(FileV2AutoDownloadPolicy.fetchesThumbnail(of: .voice))
        XCTAssertFalse(FileV2AutoDownloadPolicy.fetchesThumbnail(of: .avatar))
    }

    // MARK: Display hints

    func test_aReceivedHintIsLimitedBeforeTheInterfaceDrawsIt() {
        let sane = FileV2MediaHints(media: FileV2Descriptor.Media(w: 1920, h: 1080, dur: 5234, wave: [0, 10, 255]))
        XCTAssertEqual(sane, FileV2MediaHints(width: 1920, height: 1080, durationMs: 5234, wave: [0, 10, 255]))

        // a side outside the range makes the whole size unknown (an aspect ratio from one side alone would be wrong)
        for (w, h): (Int64, Int64) in [(0, 10), (10, 0), (-5, 10), (16_385, 10), (10, 1 << 40), (Int64.max, Int64.max)] {
            let hints = FileV2MediaHints(media: FileV2Descriptor.Media(w: w, h: h))
            XCTAssertNil(hints.width)
            XCTAssertNil(hints.height)
        }
        XCTAssertNil(FileV2MediaHints(media: FileV2Descriptor.Media(w: 100)).width, "a size needs both sides")
        XCTAssertEqual(FileV2MediaHints(media: FileV2Descriptor.Media(w: 16_384, h: 1)).width, 16_384)

        XCTAssertNil(FileV2MediaHints(media: FileV2Descriptor.Media(dur: -1)).durationMs)
        XCTAssertEqual(FileV2MediaHints(media: FileV2Descriptor.Media(dur: 0)).durationMs, 0)
        XCTAssertEqual(FileV2MediaHints(media: FileV2Descriptor.Media(dur: Int64.max)).durationMs, FileV2MediaHints.maxDurationMs)

        let long = (0..<100_000).map { Int64($0) - 500 }
        let wave = FileV2MediaHints(media: FileV2Descriptor.Media(wave: long)).wave
        XCTAssertEqual(wave.count, FileV2MediaHints.maxWaveSamples)
        XCTAssertTrue(wave.allSatisfy { $0 >= 0 && $0 <= FileV2MediaHints.maxWaveValue })

        XCTAssertEqual(FileV2MediaHints(media: nil), FileV2MediaHints())
    }

    func test_aSenderWritesOnlyWhatIsInRange() {
        XCTAssertNil(FileV2MediaHints.media())
        XCTAssertNil(FileV2MediaHints.media(width: 0, height: 5))
        XCTAssertNil(FileV2MediaHints.media(width: 5, height: nil))
        XCTAssertNil(FileV2MediaHints.media(durationMs: -4))

        let image = FileV2MediaHints.media(width: 2048, height: 1536)
        XCTAssertEqual(image?.w, 2048)
        XCTAssertEqual(image?.h, 1536)
        XCTAssertNil(image?.dur)
        XCTAssertNil(image?.wave)

        let voice = FileV2MediaHints.media(durationMs: 4200)
        XCTAssertEqual(voice?.dur, 4200)

        let huge = FileV2MediaHints.media(width: 20_000, height: 20_000, durationMs: Int64.max)
        XCTAssertNil(huge?.w)
        XCTAssertEqual(huge?.dur, FileV2MediaHints.maxDurationMs)
    }

    func test_aWaveformIsBroughtToAtMostTheRequestedSamples_keepingTheLoudestOfEachSlice() {
        XCTAssertEqual(FileV2MediaHints.downsample([1, 2, 3], to: 8), [1, 2, 3])
        XCTAssertEqual(FileV2MediaHints.downsample([1, 9, 3, 4, 5, 2], to: 3), [9, 4, 5])
        XCTAssertEqual(FileV2MediaHints.downsample([], to: 4), [])
        XCTAssertEqual(FileV2MediaHints.downsample([5, 6], to: 0), [5, 6], "no usable target leaves the values alone")

        let many = Array(repeating: 300, count: 1000) + [-9]
        let media = FileV2MediaHints.media(wave: many, waveSamples: 64)
        XCTAssertEqual(media?.wave?.count, 64)
        XCTAssertTrue(media?.wave?.allSatisfy { $0 >= 0 && $0 <= 255 } ?? false, "values are limited to 0...255")
        XCTAssertEqual(FileV2MediaHints.media(wave: many, waveSamples: 100_000)?.wave?.count, FileV2MediaHints.maxWaveSamples)
    }

    // MARK: Thumbnail geometry

    func test_aThumbnailKeepsTheAspectRatioAndIsNeverEnlarged() throws {
        let landscape = try XCTUnwrap(FileV2ThumbnailPlan.fitted(width: 4000, height: 3000, maxSide: 320))
        XCTAssertEqual(landscape.width, 320)
        XCTAssertEqual(landscape.height, 240)

        let portrait = try XCTUnwrap(FileV2ThumbnailPlan.fitted(width: 1000, height: 4000, maxSide: 320))
        XCTAssertEqual(portrait.width, 80)
        XCTAssertEqual(portrait.height, 320)

        let small = try XCTUnwrap(FileV2ThumbnailPlan.fitted(width: 100, height: 60, maxSide: 320))
        XCTAssertEqual(small.width, 100)
        XCTAssertEqual(small.height, 60)

        let sliver = try XCTUnwrap(FileV2ThumbnailPlan.fitted(width: 100_000, height: 1, maxSide: 320))
        XCTAssertEqual(sliver.width, 320)
        XCTAssertEqual(sliver.height, 1, "a side is never below one pixel")
    }

    func test_aDegenerateSourceHasNoThumbnail() {
        XCTAssertNil(FileV2ThumbnailPlan.fitted(width: 0, height: 100, maxSide: 320))
        XCTAssertNil(FileV2ThumbnailPlan.fitted(width: 100, height: -1, maxSide: 320))
        XCTAssertNil(FileV2ThumbnailPlan.fitted(width: .nan, height: 100, maxSide: 320))
        XCTAssertNil(FileV2ThumbnailPlan.fitted(width: .infinity, height: 100, maxSide: 320))
        XCTAssertNil(FileV2ThumbnailPlan.fitted(width: 100, height: 100, maxSide: 0))
    }

    // MARK: Where a file lives

    func test_aRowDirectoryIsOnePathComponent() {
        let uuid = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        XCTAssertEqual(FileV2LocalFiles.directoryName(rowKey: uuid), uuid)
        let hostile = ["../../etc", "a/b", "a\\b", "", "name with space", String(repeating: "a", count: 65), "é"]
        for key in hostile {
            let name = FileV2LocalFiles.directoryName(rowKey: key)
            XCTAssertTrue(name.hasPrefix("h-"), "\(key)")
            XCTAssertEqual(name.count, 34)
            XCTAssertFalse(name.contains("/"))
            XCTAssertFalse(name.contains(".."))
        }
        XCTAssertEqual(FileV2LocalFiles.directoryName(rowKey: "a/b"), FileV2LocalFiles.directoryName(rowKey: "a/b"))
        XCTAssertNotEqual(FileV2LocalFiles.directoryName(rowKey: "a/b"), FileV2LocalFiles.directoryName(rowKey: "a/c"))
    }

    func test_thePathsOfAReceivedFile() {
        let base = URL(fileURLWithPath: "/caches", isDirectory: true)
        XCTAssertEqual(FileV2LocalFiles.thumbnailURL(base: base, rowKey: "ROW-1").path, "/caches/files_v2/ROW-1/thumb/thumb.jpg")
        XCTAssertEqual(FileV2LocalFiles.fileURL(base: base, rowKey: "ROW-1", fileName: "a.pdf").path, "/caches/files_v2/ROW-1/a.pdf")
        XCTAssertEqual(FileV2LocalFiles.directory(base: base, rowKey: "ROW-1").path, "/caches/files_v2/ROW-1")
    }

    func test_aReceivedFileIsSavedUnderASafeNameWithAnExtension() {
        XCTAssertEqual(FileV2LocalFiles.fileName(name: "relazione.pdf", mimeType: "application/pdf", kind: "file"), "relazione.pdf")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: "scheda", mimeType: "application/pdf", kind: "file"), "scheda.pdf")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: "scheda", mimeType: nil, kind: "file"), "scheda")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: nil, mimeType: "image/jpeg", kind: "image"), "foto.jpg")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: nil, mimeType: "video/mp4", kind: "video"), "video.mp4")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: "", mimeType: "audio/mp4", kind: "voice"), "nota-vocale.m4a")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: nil, mimeType: nil, kind: "image"), "foto")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: nil, mimeType: nil, kind: "file"), "allegato")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: "../../x.jpg", mimeType: "image/jpeg", kind: "image"), ".._.._x.jpg")
        XCTAssertEqual(FileV2LocalFiles.fileName(name: "x.JPG", mimeType: "image/png", kind: "image"), "x.JPG", "the name wins over the mime type")
    }
}
