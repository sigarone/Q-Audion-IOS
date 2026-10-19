import XCTest
@testable import QAudionApp
import QAudionEngine

/// The Bluetooth mesh and Enigma mode ship ON, and their remote flags are kill switches: the public flags file may take
/// the feature away, it can never give a build a feature the build was compiled without. What the store reviews is
/// therefore the most the build can ever do.
///
/// The rule is `FeatureFlags.resolveKillSwitch(compiledDefault:remote:)`, tested here over plain values (the singleton's
/// cache cannot be filled from a test). `killSwitch(_:compiledDefault:)` is checked for a key the file never carries.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class FeatureFlagKillSwitchTests: XCTestCase {

    // MARK: - The rule

    func test_aRemoteTrueCannotEnableAFeatureThatIsCompiledOff() {
        XCTAssertFalse(FeatureFlags.resolveKillSwitch(compiledDefault: false, remote: true),
                       "the flag file must never turn on what the build was compiled without")
    }

    func test_aFeatureCompiledOffStaysOffWhateverTheRemoteSaysOrDoesNotSay() {
        XCTAssertFalse(FeatureFlags.resolveKillSwitch(compiledDefault: false, remote: false))
        XCTAssertFalse(FeatureFlags.resolveKillSwitch(compiledDefault: false, remote: nil))
    }

    func test_aRemoteFalseSwitchesACompiledOnFeatureOff() {
        XCTAssertFalse(FeatureFlags.resolveKillSwitch(compiledDefault: true, remote: false))
    }

    func test_aFeatureCompiledOnStaysOnWhenTheRemoteIsTrueOrAbsent() {
        XCTAssertTrue(FeatureFlags.resolveKillSwitch(compiledDefault: true, remote: true))
        XCTAssertTrue(FeatureFlags.resolveKillSwitch(compiledDefault: true, remote: nil),
                      "an absent or non-Bool value leaves the compiled default in force")
    }

    // MARK: - Through the typed lookup

    func test_aKeyTheFlagsFileNeverCarriesFollowsTheCompiledDefault() {
        let key = "test.killswitch.absent." + UUID().uuidString
        XCTAssertTrue(FeatureFlags.killSwitch(key, compiledDefault: true))
        XCTAssertFalse(FeatureFlags.killSwitch(key, compiledDefault: false))
    }

    // MARK: - What ships

    func test_theMeshAndEnigmaShipOnAndKeepTheirFlagKeys() {
        XCTAssertTrue(MeshFeature.compiledDefault, "the mesh is part of the release")
        XCTAssertEqual(MeshFeature.flagKey, "mesh_ble.enabled")
        XCTAssertTrue(EnigmaSettings.flagDefault, "Enigma mode is part of the release")
        XCTAssertEqual(EnigmaSettings.flagKey, "enigma_mode.enabled")
    }
}
