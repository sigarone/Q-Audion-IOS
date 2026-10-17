import Foundation

/// The visible texts of the "custody of your voice" card (header, diagram
/// labels, the cells of the bottom row). Kept apart from the layout so that
/// every text goes through the string catalog.
///
/// Not in the catalog on purpose, because they are names or symbols and not
/// language: the algorithm names "ML-KEM" and "AES-256", the check mark of
/// "SAS ✓", and the arrow glyph.
enum VoiceCustodyCopy {
    static var title: String {
        String(localized: "in_call.custody.title",
               defaultValue: "CUSTODIA DELLA TUA VOCE",
               comment: "Call security sheet, custody of the voice card — header")
    }
    static var sealedBySoftware: String {
        String(localized: "in_call.custody.sealed_by_software",
               defaultValue: "SIGILLATO DA SOFTWARE",
               comment: "Call security sheet, custody of the voice card — header tag: the voice is sealed by the app software, not by dedicated hardware")
    }
    static var boundary: String {
        String(localized: "in_call.custody.boundary",
               defaultValue: "protetto da qui →",
               comment: "Call security sheet, custody of the voice card — label on the edge of the protected zone of the diagram")
    }
    static var microphone: String {
        String(localized: "in_call.custody.microphone",
               defaultValue: "Microfono",
               comment: "Call security sheet, custody of the voice card — diagram node: the microphone")
    }
    static var exposed: String {
        String(localized: "in_call.custody.exposed",
               defaultValue: "esposto",
               comment: "Call security sheet, custody of the voice card — caption under the microphone node: outside the protected zone")
    }
    static var ciphertext: String {
        String(localized: "in_call.custody.ciphertext",
               defaultValue: "testo cifrato · in rete",
               comment: "Call security sheet, custody of the voice card — caption under the far-end node: what travels on the network is ciphertext")
    }
    static var sealedOnPhone: String {
        String(localized: "in_call.custody.sealed_on_phone",
               defaultValue: "Sigillato sul telefono",
               comment: "Call security sheet, custody of the voice card — tag under the seal at the centre of the diagram")
    }
    static var identity: String {
        String(localized: "in_call.custody.identity",
               defaultValue: "Identità",
               comment: "Call security sheet, custody of the voice card — label of the identity cell")
    }
    static var identityUnverified: String {
        String(localized: "in_call.custody.identity_unverified",
               defaultValue: "non verificata",
               comment: "Call security sheet, custody of the voice card — value of the identity cell while the security code has not been confirmed")
    }
    static var postQuantum: String {
        String(localized: "in_call.custody.post_quantum",
               defaultValue: "Post-quantistico",
               comment: "Call security sheet, custody of the voice card — label of the post-quantum cell")
    }
    static var postQuantumOff: String {
        String(localized: "in_call.custody.post_quantum_off",
               defaultValue: "non attivo",
               comment: "Call security sheet, custody of the voice card — value of the post-quantum cell when the post-quantum exchange is not active")
    }
    static var cipher: String {
        String(localized: "in_call.custody.cipher",
               defaultValue: "Cifratura",
               comment: "Call security sheet, custody of the voice card — label of the cipher cell")
    }
    static var sealPoint: String {
        String(localized: "in_call.custody.seal_point",
               defaultValue: "Punto di sigillo",
               comment: "Call security sheet, custody of the voice card — label of the cell that says where the voice is sealed")
    }
    static var phone: String {
        String(localized: "in_call.custody.phone",
               defaultValue: "Telefono",
               comment: "Call security sheet, custody of the voice card — value of the seal point cell: the voice is sealed on the phone")
    }
}
