import XCTest
@testable import PortCore

final class DeviceServiceTests: XCTestCase {
    func testModernCoreDeviceSchemaExcludesSimulatorsAndNonIOSDevices() throws {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"physical-phone","properties":{
            "hardware":{"reality":"physical","platform":"iOS","deviceType":"iPhone","marketingName":"iPhone 16 Pro","udid":"device-udid"},
            "connection":{"pairingState":"paired","state":"connected","transportType":"localNetwork"},
            "state":{"name":"Test phone","visibilityClass":"default","developerModeStatus":{"enabled":{"mode":1}}},
            "software":{"osVersionNumber":{"stringValue":"26.1"}}
          }},
          {"identifier":"simulator","properties":{
            "hardware":{"reality":"simulated","platform":"iOS","deviceType":"iPhone"},
            "state":{"visibilityClass":"simulators"}
          }},
          {"identifier":"tv","hardwareProperties":{"reality":"physical","platform":"tvOS","deviceType":"AppleTV"}}
        ]}}
        """#
        let devices = try DeviceService.parseDevices(Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        let phone = try XCTUnwrap(devices.first)
        XCTAssertEqual(phone.id, "physical-phone")
        XCTAssertEqual(phone.udid, "device-udid")
        XCTAssertEqual(phone.connectionLabel, "Wi-Fi")
        XCTAssertEqual(phone.osVersion, "26.1")
        XCTAssertEqual(phone.developerModeEnabled, true)
        XCTAssertTrue(phone.canInstall)
    }

    func testModernDisabledDeveloperModePreventsInstallation() throws {
        let json = #"""
        {"result":{"devices":[{"identifier":"phone","properties":{
          "hardware":{"reality":"physical","platform":"iOS","deviceType":"iPhone"},
          "connection":{"pairingState":"paired","state":"connected","transportType":"wired"},
          "state":{"name":"Test phone","developerModeStatus":{"disabled":{}}},
          "software":{"osVersionNumber":{"stringValue":"27.0.1"}}
        }}]}}
        """#
        let phone = try XCTUnwrap(DeviceService.parseDevices(Data(json.utf8)).first)
        XCTAssertEqual(phone.developerModeEnabled, false)
        XCTAssertFalse(phone.canInstall)
    }

    func testLegacySchemaKeepsOfflinePairedDeviceUnavailable() throws {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"tablet","hardwareProperties":{"reality":"physical","platform":"iOS","deviceType":"iPad","marketingName":"iPad Pro","udid":"tablet-udid"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"disconnected","transportType":"network"},
           "deviceProperties":{"name":"Test tablet","osVersionNumber":"26.0","developerModeStatus":"enabled"}},
          {"identifier":"usb-phone","hardwareProperties":{"reality":"physical","platform":"iOS","deviceType":"iPhone"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"connected","transportType":"usb"},
           "deviceProperties":{"name":"Test phone","osVersionNumber":"25.0","developerModeStatus":"disabled"}}
        ]}}
        """#
        let devices = try DeviceService.parseDevices(Data(json.utf8))
        let tablet = try XCTUnwrap(devices.first { $0.id == "tablet" })
        XCTAssertTrue(tablet.isPaired)
        XCTAssertFalse(tablet.isConnected)
        XCTAssertFalse(tablet.canInstall)
        let phone = try XCTUnwrap(devices.first { $0.id == "usb-phone" })
        XCTAssertEqual(phone.connectionLabel, "USB")
        XCTAssertFalse(phone.supportsRequiredOS)
        XCTAssertFalse(phone.canInstall)
    }

    func testEmptyResponseIsValidButSchemaChangesAreReported() throws {
        XCTAssertEqual(try DeviceService.parseDevices(Data(#"{"result":{"devices":[]}}"#.utf8)), [])
        XCTAssertThrowsError(try DeviceService.parseDevices(Data(#"{"result":{}}"#.utf8)))
    }

    func testDeploymentPlanPreservesPathsAndEnablesSigningExplicitly() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("Game files/xcode/DmIOS.xcodeproj")
        try writeProject(in: project, identifier: "org.nxnative.010015100b514000")
        // build_ipa.sh replaces '/' and ':' in the display name and adds the title ID.
        let generatedScheme = "Test__ Adventure (010015100B514000)"
        try writeScheme(named: generatedScheme, in: project)
        let phone = AppleDevice(id: "core-device", udid: "phone-udid", name: "Phone", model: "iPhone",
                                osVersion: "26.0", transport: "usb", isPaired: true,
                                isConnected: true, developerModeEnabled: nil)
        let plan = try DeviceService.deploymentPlan(projectURL: project, teamID: "abcdefgh12", device: phone,
            derivedDataURL: temporary.appendingPathComponent("Signed build"))
        XCTAssertTrue(plan.buildCommand.arguments.contains("DEVELOPMENT_TEAM=ABCDEFGH12"))
        XCTAssertTrue(plan.buildCommand.arguments.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(plan.buildCommand.arguments.contains("platform=iOS,id=phone-udid"))
        XCTAssertTrue(plan.buildCommand.arguments.contains(project.path))
        XCTAssertTrue(plan.buildCommand.arguments.contains("PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.abcdefgh12.010015100b514000"))
        let schemeFlag = try XCTUnwrap(plan.buildCommand.arguments.firstIndex(of: "-scheme"))
        XCTAssertEqual(plan.buildCommand.arguments[schemeFlag + 1], generatedScheme)
        XCTAssertTrue(plan.installCommand.arguments.contains("core-device"))
        XCTAssertTrue(plan.installCommand.arguments.contains(plan.signedApplicationURL.path))
        XCTAssertFalse(plan.installCommand.arguments.contains("--timeout"))
        XCTAssertEqual(plan.signedApplicationURL.lastPathComponent, "DmIOS.app")
        XCTAssertThrowsError(try DeviceService.deploymentPlan(projectURL: project, teamID: "bad\nsetting", device: phone,
            derivedDataURL: temporary))
    }

    func testBundleIdentifierNamespacePreservesCustomIDsAndOtherTargets() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("DmIOS.xcodeproj")
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try writeProject(in: project, identifier: "org.nxnative.0100152000022000")
        XCTAssertEqual(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"),
                       "org.nxnative.9x76y99ygd.0100152000022000")
        try writeProject(in: project, identifier: "com.example.my-mario-kart")
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
        try writeProject(in: project, identifier: "org.nxnative.9x76y99ygd.0100152000022000")
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
        try writeProject(in: project, identifier: "org.nxnative.0100152000022000", includesOtherTarget: true)
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
        try writeProject(in: project, identifier: "org.nxnative.0100152000022000", infoIdentifier: "com.example.explicit")
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
    }

    private func writeProject(in project: URL, identifier: String, includesOtherTarget: Bool = false,
                              infoIdentifier: String = "$(PRODUCT_BUNDLE_IDENTIFIER)") throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pbxproj = """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          objectVersion = 77;
          objects = {
            ROOT = { isa = PBXProject; targets = (APP, \(includesOtherTarget ? "OTHER," : "")); };
            APP = { isa = PBXNativeTarget; name = DmIOS; productType = "com.apple.product-type.application"; buildConfigurationList = CONFIGURATIONS; };
            OTHER = { isa = PBXNativeTarget; name = AnotherApp; };
            CONFIGURATIONS = { isa = XCConfigurationList; buildConfigurations = (RELEASE,); };
            RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = {
              PRODUCT_BUNDLE_IDENTIFIER = "\(identifier)";
              INFOPLIST_FILE = Gen/Info.plist;
            }; };
          };
          rootObject = ROOT;
        }
        """
        try Data(pbxproj.utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        let info = project.deletingLastPathComponent().appendingPathComponent("Gen/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": infoIdentifier],
                                                       format: .xml, options: 0)
        try bytes.write(to: info)
    }

    func testPreparedSchemeRejectsMissingOrAmbiguousGameSchemes() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("DmIOS.xcodeproj")
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        XCTAssertThrowsError(try DeviceService.preparedScheme(in: project)) { error in
            guard case DeviceServiceError.missingPreparedScheme = error else {
                return XCTFail("Expected a missing prepared game scheme error.")
            }
        }
        try writeScheme(named: "Unrelated", in: project, target: "OtherApp")
        XCTAssertThrowsError(try DeviceService.preparedScheme(in: project))
        try writeScheme(named: "A game (010015100B514000)", in: project)
        XCTAssertEqual(try DeviceService.preparedScheme(in: project), "A game (010015100B514000)")
        try writeScheme(named: "A duplicate game", in: project)
        XCTAssertThrowsError(try DeviceService.preparedScheme(in: project)) { error in
            guard case DeviceServiceError.ambiguousPreparedScheme = error else {
                return XCTFail("Expected an ambiguous prepared game scheme error.")
            }
        }
    }

    private func writeScheme(named name: String, in project: URL, target: String = "DmIOS") throws {
        let directory = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="2700" version="1.3">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES">
              <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TEST-TARGET" BuildableName="\(target).app" BlueprintName="\(target)" ReferencedContainer="container:DmIOS.xcodeproj"/>
            </BuildActionEntry></BuildActionEntries>
          </BuildAction>
        </Scheme>
        """
        try Data(xml.utf8).write(to: directory.appendingPathComponent(name + ".xcscheme"))
    }

    func testFailedBuildNeverReachesInstallCommand() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let marker = temporary.appendingPathComponent("unexpected-install")
        let plan = DeploymentPlan(
            buildCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/false")),
            installCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]),
            signedApplicationURL: temporary.appendingPathComponent("DmIOS.app"))
        do {
            _ = try await DeviceService.buildAndInstall(plan, using: ProcessRunner())
            XCTFail("A failed Xcode build must be reported as failure.")
        } catch DeviceServiceError.commandFailed { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMissingBuildProductNeverReachesInstallCommand() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let marker = temporary.appendingPathComponent("unexpected-install")
        let plan = DeploymentPlan(
            buildCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/true")),
            installCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]),
            signedApplicationURL: temporary.appendingPathComponent("DmIOS.app"))
        do {
            _ = try await DeviceService.buildAndInstall(plan, using: ProcessRunner())
            XCTFail("A successful process without its signed app must not report installation success.")
        } catch DeviceServiceError.missingSignedApplication { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
