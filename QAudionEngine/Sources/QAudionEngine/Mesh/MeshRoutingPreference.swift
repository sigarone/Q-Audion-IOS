import Foundation

/// Which network a conversation's messages should take.
///
/// Stored per contact. The default is ``preferMesh`` because the product
/// decision is to favour Bluetooth when it is actually available — but
/// "prefer" is the operative word, and the three values exist to keep that
/// distinct from "only".
///
/// Byte-for-byte the same three names Android stores, so a preference set on
/// one platform reads correctly if it is ever synced.
public enum MeshRoutingPreference: String, CaseIterable, Sendable {
    /// Use the mesh when this contact's device is reachable right now,
    /// otherwise the public network. The default.
    ///
    /// A preference cannot mean "hold the message until Bluetooth comes back":
    /// that turns a routing choice into an outage nobody asked for. So
    /// reachability is evaluated per message, and a contact who walks out of
    /// range simply gets the next message over the network.
    case preferMesh = "PREFER_MESH"

    /// Never the mesh, whatever is in range.
    case networkOnly = "NETWORK_ONLY"

    /// The mesh and nothing else — wait rather than fall back.
    ///
    /// This is what arming a specific device on the radar has always meant.
    /// Someone who picks a device out of a list is usually picking it FOR a
    /// reason — no network, or not wanting to use it — and silently rerouting
    /// them onto the public network defeats the only thing they asked for.
    case meshOnly = "MESH_ONLY"

    public static let `default`: MeshRoutingPreference = .preferMesh

    public static func fromStored(_ value: String?) -> MeshRoutingPreference {
        guard let value, let parsed = MeshRoutingPreference(rawValue: value) else { return .default }
        return parsed
    }
}

/// What the send path should actually do for one message.
public enum MeshRoutingDecision: Sendable {
    case sendOverMesh
    case sendOverNetwork
    /// Hold for the mesh: the user asked for that device specifically.
    case queueForMesh
}

/// Decide the route for ONE message.
///
/// Pure on purpose, and identical to the Android function of the same name:
/// routing a message off the public network should be readable in one screen
/// and testable without a radio, a database or a view model.
public func meshRoutingDecision(
    preference: MeshRoutingPreference,
    armedMeshTarget: Bool,
    peerReachableOverMesh: Bool
) -> MeshRoutingDecision {
    // An explicit choice outranks the stored default in both directions: it
    // can send over a mesh a network-only contact would otherwise refuse, and
    // it waits rather than falling back.
    if armedMeshTarget {
        return peerReachableOverMesh ? .sendOverMesh : .queueForMesh
    }
    switch preference {
    case .networkOnly:
        return .sendOverNetwork
    case .meshOnly:
        return peerReachableOverMesh ? .sendOverMesh : .queueForMesh
    case .preferMesh:
        // The whole point is that it never strands a message.
        return peerReachableOverMesh ? .sendOverMesh : .sendOverNetwork
    }
}

/// Where a contact's routing preference lives on this device.
///
/// UserDefaults keyed by user id, not the contact store: the preference is a
/// local UI choice about this phone's radio, it is not part of the contact's
/// identity, and it must not travel in a contact sync that would overwrite it
/// with somebody else's idea of the right network.
public struct MeshRoutingPreferenceStore {
    private static let keyPrefix = "qaudion.mesh.routing."

    public init() {}

    public func preference(for userId: String) -> MeshRoutingPreference {
        MeshRoutingPreference.fromStored(
            UserDefaults.standard.string(forKey: Self.keyPrefix + userId)
        )
    }

    /// Records a choice. Writing the default is still a write: "I looked at
    /// this and chose to prefer Bluetooth" is a different fact from "nobody
    /// ever decided", and only the first should survive a change of default.
    public func setPreference(_ preference: MeshRoutingPreference, for userId: String) {
        UserDefaults.standard.set(preference.rawValue, forKey: Self.keyPrefix + userId)
    }
}
