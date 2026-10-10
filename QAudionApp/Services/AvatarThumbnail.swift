import Foundation
import UIKit
import ImageIO

/// La miniatura di un avatar come serve alla vista: decodificata nella dimensione a cui si disegna, non a piena risoluzione.
///
/// `QAudionAvatar` faceva `Data(contentsOf:)` + `UIImage(data:)` per ogni cerchio, anche in lista: un avatar di 512 x 512 si decodifica
/// in 512 x 512 x 4 = 1 MiB, uno ricevuto grande (prima della riduzione in cache) fino a decine di MiB. Qui si decodifica con ImageIO
/// (`CGImageSourceCreateThumbnailAtIndex`), con l'orientamento applicato, in modo che il LATO CORTO abbia i pixel che servono al cerchio
/// (`scaledToFill` riempie il lato corto): per un cerchio da 44 pt a 3x sono 132 px, cioe' 132 x 132 x 4 = 68 KiB invece di 1 MiB
/// (15 volte meno). Mai ingrandita: un'immagine piu' piccola resta com'e'. L'aspetto non cambia: la stessa immagine, stessa
/// orientazione, ritagliata dallo stesso cerchio, con piu' pixel di quanti ne servano.
///
/// Le miniature decodificate si tengono in una `NSCache` (limite 16 MiB di pixel, la libera il sistema se serve memoria), con chiave
/// percorso + data di modifica + dimensione: un avatar nuovo nello stesso file ha un'altra data e si ricarica.
enum AvatarThumbnail {

    /// Pixel del lato corto che servono a un cerchio di `pointSize` punti a `scale`.
    static func targetShortSide(pointSize: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((pointSize * max(1, scale)).rounded(.up)))
    }

    /// Il valore di `kCGImageSourceThumbnailMaxPixelSize` (si applica al lato lungo) perche' il lato corto sia `targetShortSide`;
    /// mai oltre il lato lungo dell'originale.
    static func maxPixelSize(longSide: Int, shortSide: Int, targetShortSide: Int) -> Int {
        guard longSide > 0, shortSide > 0 else { return max(1, longSide) }
        if shortSide <= targetShortSide { return longSide }
        let needed = (Double(targetShortSide) * Double(longSide) / Double(shortSide)).rounded(.up)
        return min(longSide, Int(needed))
    }

    /// Memoria di un'immagine decodificata (RGBA, 4 byte per pixel).
    static func decodedBytes(width: Int, height: Int) -> Int { width * height * 4 }

    static let cacheLimitBytes = 16 * 1024 * 1024

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = cacheLimitBytes
        return cache
    }()

    /// `nil` se ImageIO non legge il file come immagine (il chiamante ripiega sul caricamento a piena risoluzione di sempre).
    static func load(url: URL, pointSize: CGFloat, scale: CGFloat) -> UIImage? {
        let target = targetShortSide(pointSize: pointSize, scale: scale)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let stamp = Int((modified?.timeIntervalSince1970 ?? 0) * 1000)
        let key = "\(url.path)|\(stamp)|\(target)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let info = FileV2ImageCleaner.readInfo(of: source) else { return nil }
        let maxPixel = maxPixelSize(
            longSide: max(info.displayWidth, info.displayHeight),
            shortSide: min(info.displayWidth, info.displayHeight),
            targetShortSide: target)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key, cost: decodedBytes(width: thumbnail.width, height: thumbnail.height))
        return image
    }
}
