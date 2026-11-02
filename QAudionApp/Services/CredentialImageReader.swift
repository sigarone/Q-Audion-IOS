import Foundation
import UIKit
import Vision
import PDFKit
import UniformTypeIdentifiers

/// Reads an extension and a password from a photo, an image file, a PDF or a text file, entirely on the device.
/// It only returns values; it never signs in and never logs what it read.
enum CredentialImageReader {

    /// Upper bound for a text file we are willing to read.
    private static let maxTextBytes = 256 * 1024

    // MARK: - Entry points

    static func read(imageData: Data) async -> CredentialExtraction {
        guard let image = UIImage(data: imageData) else { return .notFound }
        return await read(image: image)
    }

    static func read(image: UIImage) async -> CredentialExtraction {
        await Task.detached(priority: .userInitiated) {
            recognize(image: image)
        }.value
    }

    /// `url` must already be accessible (security scope opened by the caller).
    static func read(fileURL url: URL) async -> CredentialExtraction {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return .notFound }
        if type.conforms(to: .pdf) {
            guard let image = firstPageImage(ofPDFAt: url) else { return .notFound }
            return await read(image: image)
        }
        if type.conforms(to: .image) {
            guard let data = try? Data(contentsOf: url) else { return .notFound }
            return await read(imageData: data)
        }
        if type.conforms(to: .text) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .notFound }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxTextBytes),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return .notFound
            }
            return CredentialTextParser.extract(structuredPayloads: [], text: text,
                                                serverAccepted: { PinnedServerHost.accepts($0) })
        }
        return .notFound
    }

    // MARK: - Vision

    private static func recognize(image: UIImage) -> CredentialExtraction {
        guard let cgImage = image.cgImage else { return .notFound }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

        // (a) structured payload in a QR code
        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.qr]
        try? handler.perform([barcodes])
        let payloads = (barcodes.results ?? []).compactMap { $0.payloadStringValue }

        // (b) text, printed or handwritten
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        let wanted = ["it-IT", "en-US"]
        if let supported = try? text.supportedRecognitionLanguages() {
            let usable = wanted.filter { supported.contains($0) }
            if !usable.isEmpty { text.recognitionLanguages = usable }
        }
        try? handler.perform([text])
        let observations = (text.results ?? []).sorted { a, b in
            // top to bottom, then left to right (Vision's origin is the bottom-left corner)
            let dy = a.boundingBox.midY - b.boundingBox.midY
            if abs(dy) > 0.015 { return dy > 0 }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }

        return CredentialTextParser.extract(structuredPayloads: payloads,
                                            text: lines.joined(separator: "\n"),
                                            serverAccepted: { PinnedServerHost.accepts($0) })
    }

    // MARK: - PDF

    private static func firstPageImage(ofPDFAt url: URL) -> UIImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(3.0, 2400 / max(box.width, box.height))
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
