import Foundation

/// Remote call flags live in a main-actor store, but the call setup that consumes them
/// (`QAudionPeerConnection.init`) runs on the global executor after awaits, where a
/// main-thread guard always fails. The flag is therefore read once, on the thread that
/// wires the controller (the main actor), and the provider only hands back that value.
public enum CallFlagProviders {
    public static func snapshot(_ read: () -> Bool) -> () -> Bool {
        let value = read()
        return { value }
    }
}
