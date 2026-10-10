import Foundation
import ImageIO

/// Dimensioni di un'immagine come si vedono (con l'orientamento applicato), lette dall'intestazione senza decodificare i pixel. Servono
/// al log (`side` lato lungo, `min` lato corto) e ai controlli di dimensione degli avatar.
enum AvatarImageGeometry {

    struct Size: Equatable {
        let longSide: Int
        let shortSide: Int
    }

    /// `nil` se ImageIO non riconosce i byte come immagine.
    static func measure(_ data: Data) -> Size? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = FileV2ImageCleaner.readInfo(of: source) else { return nil }
        let width = info.displayWidth
        let height = info.displayHeight
        return Size(longSide: max(width, height), shortSide: min(width, height))
    }
}
