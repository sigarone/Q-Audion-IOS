import XCTest
import AVFoundation
@testable import QAudionApp
import QAudionEngine

/// The second fact behind the Bluetooth mesh pause during a call (docs/mesh/MESH_LINK_SPEC.md section 2.1): does the audio
/// route use a Bluetooth device? Any Bluetooth input or output port counts (the hands-free link of a car kit or a headset,
/// LE Audio and hearing aids, the stereo profile); built-in, wired, USB, AirPlay and CarPlay ports do not. The decision that
/// uses it (`MeshBtCallPause`) and the retry backoff (`MeshConnectBackoff`) are pure and are tested in QAudionEngineTests.
///
/// Also pinned here: the runtime collects the call state (the app's own connected call, any connected call of the device)
/// and the route on the main thread, keeps them without a radio, and a call flag never brings the radio up by itself
/// (the pause can only suspend an antenna that is on, never switch one on).
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class MeshAudioRouteTests: XCTestCase {

    private let bluetooth: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]

    private let notBluetooth: [AVAudioSession.Port] = [
        .builtInMic, .builtInReceiver, .builtInSpeaker, .headphones, .headsetMic, .usbAudio, .airPlay, .carAudio,
        .HDMI, .lineOut, .lineIn,
    ]

    func test_theBluetoothPortsAreExactlyHandsFreeStereoAndLowEnergy() {
        XCTAssertEqual(MeshAudioRoute.bluetoothPorts, [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE])
    }

    func test_aBluetoothPortOnTheOutputCounts() {
        for port in bluetooth {
            XCTAssertTrue(MeshAudioRoute.usesBluetooth(inputs: [.builtInMic], outputs: [port]), "\(port.rawValue) as output")
            XCTAssertTrue(MeshAudioRoute.usesBluetooth(inputs: [], outputs: [port]), "\(port.rawValue) as the only output")
        }
    }

    func test_aBluetoothPortOnTheInputCounts() {
        for port in bluetooth {
            XCTAssertTrue(MeshAudioRoute.usesBluetooth(inputs: [port], outputs: [.builtInSpeaker]), "\(port.rawValue) as input")
            XCTAssertTrue(MeshAudioRoute.usesBluetooth(inputs: [port], outputs: []), "\(port.rawValue) as the only input")
        }
    }

    func test_theHandsFreeLinkOfACarKitCounts() {
        XCTAssertTrue(MeshAudioRoute.usesBluetooth(inputs: [.bluetoothHFP], outputs: [.bluetoothHFP]))
    }

    func test_otherPortsDoNotCount() {
        for port in notBluetooth {
            XCTAssertFalse(MeshAudioRoute.usesBluetooth(inputs: [port], outputs: [port]), "\(port.rawValue)")
        }
        // The usual call routes without a Bluetooth device: the earpiece, the speaker, a wired headset.
        XCTAssertFalse(MeshAudioRoute.usesBluetooth(inputs: [.builtInMic], outputs: [.builtInReceiver]))
        XCTAssertFalse(MeshAudioRoute.usesBluetooth(inputs: [.builtInMic], outputs: [.builtInSpeaker]))
        XCTAssertFalse(MeshAudioRoute.usesBluetooth(inputs: [.headsetMic], outputs: [.headphones]))
        XCTAssertFalse(MeshAudioRoute.usesBluetooth(inputs: [.builtInMic], outputs: [.carAudio]))
    }

    func test_anEmptyRouteIsNotBluetooth() {
        XCTAssertFalse(MeshAudioRoute.usesBluetooth(inputs: [], outputs: []))
    }

    // MARK: - The runtime

    @MainActor
    private func makeRuntime(
        systemCalls: @escaping @MainActor () -> [MeshCallDefinition.SystemCall] = { [] },
        bluetoothRoute: @escaping @MainActor () -> Bool = { false }
    ) throws -> (runtime: MeshRuntime, cleanup: () -> Void) {
        let name = "MeshAudioRouteTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let consent = MeshConsent(store: MeshConsentStore(defaults: defaults))
        consent.accept()
        let runtime = MeshRuntime(forTesting: consent, systemCalls: systemCalls, bluetoothRoute: bluetoothRoute)
        return (runtime, { UserDefaults.standard.removePersistentDomain(forName: name) })
    }

    @MainActor
    func test_theRuntimeRemembersTheCallFlagWithoutARadioAndNeverStartsOneForIt() throws {
        let (runtime, cleanup) = try makeRuntime()
        defer { cleanup() }
        XCTAssertFalse(runtime.callActive)

        runtime.setCallActive(true)
        XCTAssertTrue(runtime.callActive)
        XCTAssertTrue(runtime.ownCallConnected)
        runtime.setCallActive(true)
        XCTAssertTrue(runtime.callActive, "the same value again changes nothing")

        // The consent was given, but a call flag is not a reason to switch an antenna on.
        XCTAssertFalse(runtime.antennaOn)
        XCTAssertNil(runtime.requestedMode)

        runtime.setCallActive(false)
        XCTAssertFalse(runtime.callActive)
        XCTAssertFalse(runtime.antennaOn)
        XCTAssertNil(runtime.requestedMode)
    }

    /// Section 2.1: a call is any connected call on the device, of any app and a cellular call included; ringing is not one.
    @MainActor
    func test_aConnectedCallOfTheDeviceCountsAndARingingOneDoesNot() throws {
        var calls: [MeshCallDefinition.SystemCall] = []
        let (runtime, cleanup) = try makeRuntime(systemCalls: { calls })
        defer { cleanup() }

        runtime.refreshCallFacts()
        XCTAssertFalse(runtime.callActive, "no call at all")

        calls = [MeshCallDefinition.SystemCall(hasConnected: false, hasEnded: false)]
        runtime.refreshCallFacts()
        XCTAssertFalse(runtime.callActive, "a call that is only ringing is not a call")

        calls = [MeshCallDefinition.SystemCall(hasConnected: true, hasEnded: false)]
        runtime.refreshCallFacts()
        XCTAssertTrue(runtime.callActive, "a connected call of the device, without a call of the app")
        XCTAssertFalse(runtime.ownCallConnected)

        calls = [MeshCallDefinition.SystemCall(hasConnected: true, hasEnded: true)]
        runtime.refreshCallFacts()
        XCTAssertFalse(runtime.callActive, "the call ended")

        // The app's own connected call counts even when the platform lists nothing (a call outside CallKit).
        calls = []
        runtime.setCallActive(true)
        XCTAssertTrue(runtime.callActive)
        calls = [MeshCallDefinition.SystemCall(hasConnected: true, hasEnded: false)]
        runtime.setCallActive(false)
        XCTAssertTrue(runtime.callActive, "the own call ended, a cellular call goes on")
        XCTAssertFalse(runtime.antennaOn)
        XCTAssertNil(runtime.requestedMode)
    }

    /// The route is read where the facts are collected, on the main thread, every time the own call changes, and
    /// together with the call state; a route that changes on its own is picked up by the next refresh.
    @MainActor
    func test_theRouteIsReadOnTheMainThreadTogetherWithTheCallState() throws {
        var reads = 0
        var bluetooth = false
        let (runtime, cleanup) = try makeRuntime(bluetoothRoute: {
            XCTAssertTrue(Thread.isMainThread)
            reads += 1
            return bluetooth
        })
        defer { cleanup() }

        runtime.setCallActive(true)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(runtime.callActive)
        XCTAssertFalse(runtime.btRoute)

        bluetooth = true
        runtime.refreshCallFacts()
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(runtime.btRoute)

        runtime.setCallActive(true)
        XCTAssertEqual(reads, 2, "the same value again reads nothing")
        runtime.setCallActive(false)
        XCTAssertEqual(reads, 3)
        XCTAssertFalse(runtime.callActive)
        XCTAssertTrue(runtime.btRoute, "the route fact is the route, whatever the call state")
    }
}
