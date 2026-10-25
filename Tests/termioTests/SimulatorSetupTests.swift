import XCTest
@testable import termio

/// The Simulator pane names the one step of Xcode's setup still to do. Each
/// state is a real Mac someone has: Command Line Tools only, Xcode installed
/// but not selected, a license not accepted, a first launch not finished, no
/// iOS platform downloaded. These pin which step each reads as.
final class SimulatorSetupTests: XCTestCase {
    private let xcode = "/Applications/Xcode.app"

    func testCommandLineToolsAloneIsNoXcode() {
        XCTAssertEqual(SimulatorSetupProblem.diagnose(
            developerFolder: "/Library/Developer/CommandLineTools", installedXcode: nil, simctlError: nil, iOSRuntimes: 0),
            .noXcode)
        XCTAssertEqual(SimulatorSetupProblem.diagnose(
            developerFolder: nil, installedXcode: nil, simctlError: nil, iOSRuntimes: 0), .noXcode)
    }

    func testAnInstalledXcodeNotSelectedSaysHowToSelectIt() {
        let problem = SimulatorSetupProblem.diagnose(
            developerFolder: "/Library/Developer/CommandLineTools", installedXcode: xcode, simctlError: nil, iOSRuntimes: 0)
        XCTAssertEqual(problem, .xcodeNotSelected(xcode: xcode))
        XCTAssertEqual(problem?.command, "sudo xcode-select -s \(xcode)")
    }

    func testSimctlsOwnWordsTellLicenseFromFirstLaunch() {
        XCTAssertEqual(SimulatorSetupProblem.diagnose(
            developerFolder: xcode, installedXcode: xcode,
            simctlError: "You have not agreed to the Xcode license agreements.", iOSRuntimes: 0), .license)
        XCTAssertEqual(SimulatorSetupProblem.diagnose(
            developerFolder: xcode, installedXcode: xcode,
            simctlError: "xcrun: error: unable to find utility \"simctl\"", iOSRuntimes: 0), .firstLaunch)
    }

    func testAReadyXcodeWithoutAPlatformAndWithOne() {
        XCTAssertEqual(SimulatorSetupProblem.diagnose(
            developerFolder: xcode, installedXcode: xcode, simctlError: nil, iOSRuntimes: 0), .noRuntime)
        XCTAssertNil(SimulatorSetupProblem.diagnose(
            developerFolder: xcode, installedXcode: xcode, simctlError: nil, iOSRuntimes: 2))
    }
}
