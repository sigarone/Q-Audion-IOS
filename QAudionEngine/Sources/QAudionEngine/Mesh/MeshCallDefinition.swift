import Foundation

/// What counts as a call for the Bluetooth pause (docs/mesh/MESH_LINK_SPEC.md section 2.1), as a pure definition.
///
/// A call is any connected voice or video call on the device, of this app or of any other app, including a cellular
/// call, from the moment it connects until it ends. A call that is only ringing is not a call, and neither is one
/// that is only being dialled: it has not connected yet.
///
/// The app's own connected call is a flag the app keeps; every other call comes from the platform's call list (on
/// iOS the `CXCall` objects of a `CXCallObserver`, which needs no entitlement). The owner reads both on one thread
/// and combines them here, so the rule has one definition and can be tested without a call.
public enum MeshCallDefinition {

    /// What the platform reports about one call of the device.
    public struct SystemCall: Equatable, Sendable {
        /// The call has connected (answered, or the other side answered).
        public let hasConnected: Bool
        /// The call has ended.
        public let hasEnded: Bool

        public init(hasConnected: Bool, hasEnded: Bool) {
            self.hasConnected = hasConnected
            self.hasEnded = hasEnded
        }
    }

    /// True from the moment the call connects until it ends. A call on hold has connected and not ended, so it still counts.
    public static func isConnected(_ call: SystemCall) -> Bool {
        call.hasConnected && !call.hasEnded
    }

    /// True if the app's own call is connected, or any call of the device is.
    public static func callActive(ownCallConnected: Bool, systemCalls: [SystemCall]) -> Bool {
        ownCallConnected || systemCalls.contains { isConnected($0) }
    }
}
