import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import QAudionEngine

/// La regola delle dimensioni di un avatar, la stessa per l'avatar che si sceglie, quello che si invia e quello che si conserva dopo
/// averlo ricevuto.
///
/// Lato lungo al massimo 512 px (non 384): un cerchio da 96 pt a 3x sono 288 px, e 512 ne da' 1,8 volte, quanto basta per la vista
/// grande del profilo e per le schermate di chiamata (fino a 240 pt) senza sgranare; 384 farebbe risparmiare circa un terzo dei
/// byte, che a questa dimensione sono comunque pochi. JPEG a qualita' 0,80 (non 0,85 come prima), con l'obiettivo di non superare
/// 100 KB: se una foto rumorosa lo supera si scende a 0,70, 0,60, 0,50 e si tiene il primo che ci sta (o l'ultimo).
enum AvatarImageRule {
    static let maxSide = 512
    static let targetBytes = 100 * 1024
    static let jpegQualities: [Double] = [0.80, 0.70, 0.60, 0.50]
}

enum AvatarImageResizer {

    struct Prepared: Equatable {
        let data: Data
        /// Lato lungo e lato corto in pixel, con l'orientamento applicato.
        let longSide: Int
        let shortSide: Int
        /// `false` se i byte sono quelli ricevuti (gia' dentro la regola).
        let reencoded: Bool
    }

    /// I byte e il lato lungo sono dentro la regola: il file non va ricodificato.
    static func fitsRule(bytes: Int, longSide: Int) -> Bool {
        bytes <= AvatarImageRule.targetBytes && longSide <= AvatarImageRule.maxSide
    }

    /// Il primo JPEG della scala di qualita' che sta nell'obiettivo di byte; se nessuno ci sta, l'ultimo (il piu' piccolo). `nil` solo
    /// se l'encoder non produce nulla.
    static func smallestJPEG(
        qualities: [Double] = AvatarImageRule.jpegQualities,
        targetBytes: Int = AvatarImageRule.targetBytes,
        encode: (Double) -> Data?
    ) -> Data? {
        var last: Data?
        for quality in qualities {
            guard let data = encode(quality) else { continue }
            last = data
            if data.count <= targetBytes { return data }
        }
        return last
    }

    /// L'immagine dentro la regola. Un file gia' piccolo non si ricodifica. Altrimenti si decodifica con l'orientamento applicato e
    /// ridotto (mai ingrandito) e si ricodifica in JPEG: nessun metadato passa all'encoder. Con `cleanMetadata` anche un file piccolo
    /// ma con orientamento, posizione o dati della fotocamera viene ricodificato: e' la copia che esce dal telefono. `nil` se i byte non sono un'immagine.
    static func prepare(_ data: Data, cleanMetadata: Bool) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = FileV2ImageCleaner.readInfo(of: source) else { return nil }
        let longSide = max(info.displayWidth, info.displayHeight)
        let shortSide = min(info.displayWidth, info.displayHeight)
        if fitsRule(bytes: data.count, longSide: longSide), !(cleanMetadata && needsCleaning(data, info: info)) {
            return Prepared(data: data, longSide: longSide, shortSide: shortSide, reencoded: false)
        }
        guard let image = FileV2ImageCleaner.decodedImage(of: source, maxSide: AvatarImageRule.maxSide),
              let encoded = smallestJPEG(encode: { jpeg(image, quality: $0) }) else { return nil }
        return Prepared(
            data: encoded, longSide: max(image.width, image.height), shortSide: min(image.width, image.height), reencoded: true)
    }

    /// Orientation other than upright, or a position or a camera make / model: what a picture from elsewhere may carry and must not
    /// leave the phone. The file `AvatarUploader` writes is redrawn, so it has none of it; other technical blocks (colour space,
    /// pixel dimensions) do not count, or every picture would be re-encoded for nothing.
    private static func needsCleaning(_ data: Data, info: FileV2ImageCleaner.Info) -> Bool {
        if info.orientation != 1 { return true }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return true }
        if properties[kCGImagePropertyGPSDictionary] != nil || properties[kCGImagePropertyIPTCDictionary] != nil { return true }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil || tiff[kCGImagePropertyTIFFArtist] != nil {
            return true
        }
        return false
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, opaque(image), options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    /// JPEG has no transparency: a picture with an alpha channel is flattened on white first.
    private static func opaque(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }
}

/// La copia ridimensionata che esce dal telefono quando il file locale dell'avatar e' piu' grande della regola (o ha orientamento o
/// metadati): rete di sicurezza prima dell'invio. Il file locale scelto con `AvatarUploader` e' gia' dentro la regola e si invia cosi'
/// com'e'. La copia si salva in un file accanto all'avatar e si riusa finche' il file locale non cambia: l'impronta del file locale che
/// l'ha generata e' ricordata in `UserDefaults`, quindi non si ricalcola a ogni invio.
enum AvatarSendCopy {

    struct Prepared {
        /// File da inviare: il locale, o la copia ridimensionata.
        let url: URL
        let data: Data
        /// Lato lungo e corto in pixel, 0 se non si e' riusciti a misurarli.
        let longSide: Int
        let shortSide: Int
        /// La copia e' stata appena generata (non riusata): da registrare nel log.
        let generated: Bool
        /// `true` se si invia una copia ridimensionata invece del file locale.
        let isCopy: Bool
    }

    static let copyFileName = "self-send.jpg"
    static let sourceHashKey = "qaudion.avatarSendCopySource.v1"

    static func prepare(
        source: URL,
        data: Data,
        directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) -> Prepared {
        guard let prepared = AvatarImageResizer.prepare(data, cleanMetadata: true) else {
            // Not a picture ImageIO understands: sent as it is, as before.
            return Prepared(url: source, data: data, longSide: 0, shortSide: 0, generated: false, isCopy: false)
        }
        if !prepared.reencoded {
            return Prepared(
                url: source, data: data, longSide: prepared.longSide, shortSide: prepared.shortSide, generated: false, isCopy: false)
        }
        let copyURL = (directory ?? source.deletingLastPathComponent()).appendingPathComponent(copyFileName)
        let sourceHash = AvatarContentHash.hex(of: data)
        if defaults.string(forKey: sourceHashKey) == sourceHash, let cached = try? Data(contentsOf: copyURL), !cached.isEmpty,
           let size = AvatarImageGeometry.measure(cached) {
            return Prepared(
                url: copyURL, data: cached, longSide: size.longSide, shortSide: size.shortSide, generated: false, isCopy: true)
        }
        do {
            try prepared.data.write(to: copyURL, options: [.atomic])
        } catch {
            // The copy could not be saved, and the sender reads a file: fall back to the local file, as before this existed.
            return Prepared(
                url: source, data: data, longSide: prepared.longSide, shortSide: prepared.shortSide, generated: false, isCopy: false)
        }
        defaults.set(sourceHash, forKey: sourceHashKey)
        return Prepared(
            url: copyURL, data: prepared.data, longSide: prepared.longSide, shortSide: prepared.shortSide, generated: true, isCopy: true)
    }
}
