import XCTest
@testable import QAudionApp

/// The earbud hardware stack is a compile-time switch (QAUDION_EARBUD, see QAudionApp/project-earbud.yml).
/// This test bundle is built from the default spec (project-apptests.yml includes project.yml), so the BLE
/// client for the earbud must NOT be in the host app: no class registered with the Objective-C runtime (an
/// NSObject subclass is kept by the linker even when nothing references it, which is why the switch removes
/// the source file, not just its callers).
///
/// Only the "absent" half runs here. QAUDION_EARBUD is set on the QAudionApp target alone (OTHER_SWIFT_FLAGS in
/// project-earbud.yml), never on this test target, so the `#if QAUDION_EARBUD` branch below is not compiled
/// into this bundle. It is kept only so that a future test spec which sets the flag on both targets checks the
/// opposite direction too. That the earbud variant really contains the stack is proven elsewhere: the
/// `earbud-variant-build` job in ios-app-tests.yml and `assert-no-earbud.sh --require-present` in
/// ios-testflight.yml look for it in the built binary.
final class EarbudCompileConditionTests: XCTestCase {

    /// "QAudionApp", read from a class that is always compiled, so the lookups below use the module name the
    /// build really produced instead of a hard-coded one.
    private var moduleName: String {
        String(reflecting: MeshBluetoothCapabilityProbe.self).components(separatedBy: ".").first ?? ""
    }

    /// Positive control: without it, "the earbud class is absent" would also pass if the lookup could not
    /// find any class by this name at all.
    func testTheProbeFindsAnAlwaysCompiledBluetoothClass() {
        XCTAssertFalse(moduleName.isEmpty)
        XCTAssertNotNil(NSClassFromString("\(moduleName).MeshBluetoothCapabilityProbe"),
                        "the class lookup does not work in this test host, so the absence checks below prove nothing")
    }

    func testTheEarbudGattClientIsPresentExactlyWhenTheConditionIsSet() {
        let proxy: AnyClass? = NSClassFromString("\(moduleName).IOSEarbudGattProxy")
        let relay: AnyClass? = NSClassFromString("\(moduleName).CoreBluetoothSovereignRelay")
        #if QAUDION_EARBUD
        XCTAssertNotNil(proxy, "QAUDION_EARBUD is set but IOSEarbudGattProxy is not in the app")
        XCTAssertNotNil(relay, "QAUDION_EARBUD is set but CoreBluetoothSovereignRelay is not in the app")
        #else
        XCTAssertNil(proxy, "IOSEarbudGattProxy is in a build that must not have the earbud stack")
        XCTAssertNil(relay, "CoreBluetoothSovereignRelay is in a build that must not have the earbud stack")
        #endif
    }
}
