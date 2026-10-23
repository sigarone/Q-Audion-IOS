import Foundation
import UIKit
import QAudionEngine

/// What the user can do with a position on a card (docs/LOCATION_SHARING.md 1.6, iOS). The exact text of every output is the engine's
/// (`LocationOpenLinks`, pinned by `open_cases`); this file only hands it to the system. Nothing is uploaded, no map framework is linked,
/// no custom URL scheme is used and `LSApplicationQueriesSchemes` stays absent: the two links are https.
///
/// The position goes to the application the user chooses and to nobody else. The GPX file is a temporary file in its own folder, removed
/// when the share sheet closes and swept at every launch.
enum LocationCardActions {

    /// The fixed text for a shared position, localised: never a name, an address or the name of the contact.
    static var sharedPositionLabel: String {
        String(localized: "location.label.shared", defaultValue: "Posizione condivisa", comment: "Name of a shared position in a map application, in a GPX file and for VoiceOver: never the name of the contact.")
    }

    // MARK: Open

    /// "Apri in Mappe": the Apple Maps link, opened with the system.
    @MainActor
    static func openInAppleMaps(latE7: Int32, lonE7: Int32) {
        let text: String = LocationOpenLinks.appleMapsURL(latE7: latE7, lonE7: lonE7, label: sharedPositionLabel)
        guard let url = URL(string: text) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// "Apri in Google Maps": the universal link, which opens the application when it is installed and a web page otherwise.
    @MainActor
    static func openInGoogleMaps(latE7: Int32, lonE7: Int32) {
        let text: String = LocationOpenLinks.googleMapsURL(latE7: latE7, lonE7: lonE7)
        guard let url = URL(string: text) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: GPX

    private static var gpxFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qa-geo", isDirectory: true)
    }

    /// Writes the GPX file of a position and returns its URL, for the share sheet. The file name carries no content.
    static func writeGpxFile(latE7: Int32, lonE7: Int32) -> URL? {
        let text: String = LocationOpenLinks.gpx(latE7: latE7, lonE7: lonE7, label: sharedPositionLabel)
        let folder: URL = gpxFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
            let name: String = "posizione-" + UUID().uuidString + ".gpx"
            let url: URL = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    static func removeGpxFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Launch: whatever an earlier run left in the GPX folder goes.
    static func sweepGpxFolder() {
        try? FileManager.default.removeItem(at: gpxFolder)
    }

    // MARK: Copy

    /// The text copied by "Copia coordinate": `DEC7(lat), DEC7(lon)`.
    static func coordinateText(latE7: Int32, lonE7: Int32) -> String {
        let lat: String = LocationConversion.dec7(Int64(latE7))
        let lon: String = LocationConversion.dec7(Int64(lonE7))
        return lat + ", " + lon
    }

    /// The pasteboard is set local-only (it does not travel to the user's other devices) with a two-minute expiry.
    @MainActor
    static func copyCoordinates(latE7: Int32, lonE7: Int32) {
        let text: String = coordinateText(latE7: latE7, lonE7: lonE7)
        let item: [String: Any] = ["public.utf8-plain-text": text]
        let expiry: Date = Date().addingTimeInterval(120)
        UIPasteboard.general.setItems([item], options: [.localOnly: true, .expirationDate: expiry])
    }
}
