import Foundation

/// A physical iPhone or iPad known to Xcode, rather than an arbitrary nearby device.
public struct AppleDevice: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let udid: String
    public let name: String
    public let model: String
    public let osVersion: String
    public let transport: String
    public let isPaired: Bool
    public let isConnected: Bool
    public let developerModeEnabled: Bool?

    public init(id: String, udid: String, name: String, model: String, osVersion: String,
                transport: String, isPaired: Bool, isConnected: Bool, developerModeEnabled: Bool?) {
        self.id = id
        self.udid = udid
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.transport = transport
        self.isPaired = isPaired
        self.isConnected = isConnected
        self.developerModeEnabled = developerModeEnabled
    }

    public var connectionLabel: String {
        switch transport.lowercased() {
        case "usb", "wired": return "USB"
        case "wifi", "wi-fi", "network", "localnetwork": return "Wi-Fi"
        default: return transport.isEmpty ? "Unknown" : transport
        }
    }

    public var supportsRequiredOS: Bool {
        guard let major = Int(osVersion.split(separator: ".").first ?? "") else { return false }
        return major >= 26
    }

    /// Unknown Developer Mode is left to CoreDevice to validate at installation time.
    public var canInstall: Bool {
        isPaired && isConnected && developerModeEnabled != false && supportsRequiredOS
    }
}

public enum DeviceServiceError: LocalizedError, Sendable {
    case invalidResponse
    case invalidTeamID
    case missingProject
    case unavailableDevice
    case missingSignedApplication
    case missingPreparedScheme
    case ambiguousPreparedScheme
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Xcode returned an unrecognized device response."
        case .invalidTeamID: return "Enter the 10-character Apple Developer Team ID from Xcode."
        case .missingProject: return "Prepare the game's Xcode project before installing it."
        case .unavailableDevice: return "Connect and pair a supported iPhone or iPad, unlock it, and enable Developer Mode."
        case .missingSignedApplication: return "Xcode completed without producing a signed application."
        case .missingPreparedScheme: return "The project has no shared scheme that builds DmIOS. Prepare the game project again with nxnative."
        case .ambiguousPreparedScheme: return "The project has several shared schemes that build DmIOS. Prepare a fresh game project or select its scheme in Xcode."
        case .commandFailed(let message): return message
        }
    }
}

public enum DeviceService {
    public static func discover(using runner: ProcessRunner = ProcessRunner()) async throws -> [AppleDevice] {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxport-devices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let jsonURL = temporary.appendingPathComponent("devices.json")
        let result = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "list", "devices", "--timeout", "20", "--json-output", jsonURL.path],
            environment: ToolEnvironment.values,
            redactedDescription: "xcrun devicectl list devices"))
        guard result.exitCode == 0 else { throw DeviceServiceError.commandFailed(String(result.output.suffix(4000))) }
        return try parseDevices(Data(contentsOf: jsonURL))
    }

    public static func deploymentPlan(projectURL: URL, teamID: String, device: AppleDevice,
                                      derivedDataURL: URL) throws -> DeploymentPlan {
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw DeviceServiceError.invalidTeamID
        }
        guard projectURL.pathExtension == "xcodeproj",
              FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("project.pbxproj").path) else {
            throw DeviceServiceError.missingProject
        }
        guard device.canInstall else { throw DeviceServiceError.unavailableDevice }
        let scheme = try preparedScheme(in: projectURL)
        let products = derivedDataURL.appendingPathComponent("Build/Products/Release-iphoneos", isDirectory: true)
        let signedApp = products.appendingPathComponent("DmIOS.app", isDirectory: true)
        var buildArguments = [
            "xcodebuild", "-project", projectURL.path, "-scheme", scheme, "-configuration", "Release",
            "-destination", "platform=iOS,id=\(device.udid)", "-derivedDataPath", derivedDataURL.path,
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "DM_COPY_GAME_RESOURCES=YES",
            "CONFIGURATION_BUILD_DIR=\(products.path)"
        ]
        if let identifier = defaultBundleIdentifierOverride(in: projectURL, teamID: team) {
            buildArguments.append("PRODUCT_BUNDLE_IDENTIFIER=\(identifier)")
        }
        buildArguments.append("build")
        let build = ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: buildArguments,
            workingDirectoryURL: projectURL.deletingLastPathComponent(), environment: ToolEnvironment.values,
            redactedDescription: "xcodebuild DmIOS — sign for the selected device with the configured Xcode team")
        let install = ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: [
            "devicectl", "device", "install", "app", "--device", device.id, signedApp.path
        ], environment: ToolEnvironment.values,
            redactedDescription: "xcrun devicectl device install app — selected device")
        return DeploymentPlan(buildCommand: build, installCommand: install, signedApplicationURL: signedApp)
    }

    /// Give nxnative's shared default ID a stable per-team namespace. Custom IDs,
    /// modified Info.plists and multi-target projects retain their existing settings.
    static func defaultBundleIdentifierOverride(in projectURL: URL, teamID: String) -> String? {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let data = try? Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String,
              let project = objects[rootID], project["isa"] as? String == "PBXProject",
              let targets = project["targets"] as? [String], targets.count == 1,
              let target = objects[targets[0]], target["isa"] as? String == "PBXNativeTarget",
              target["name"] as? String == "DmIOS",
              target["productType"] as? String == "com.apple.product-type.application",
              let listID = target["buildConfigurationList"] as? String,
              let list = objects[listID], list["isa"] as? String == "XCConfigurationList",
              let configurationIDs = list["buildConfigurations"] as? [String] else { return nil }
        let releases = configurationIDs.compactMap { objects[$0] }.filter {
            $0["isa"] as? String == "XCBuildConfiguration" && $0["name"] as? String == "Release"
        }
        guard releases.count == 1,
              let settings = releases[0]["buildSettings"] as? [String: Any],
              let identifier = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String,
              identifier.range(of: "^org\\.nxnative\\.[0-9a-f]{16}$", options: .regularExpression) != nil,
              settings["INFOPLIST_FILE"] as? String == "Gen/Info.plist" else { return nil }
        let infoURL = projectURL.deletingLastPathComponent().appendingPathComponent("Gen/Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)" else { return nil }
        let titleID = identifier.dropFirst("org.nxnative.".count)
        return "org.nxnative.\(teamID.lowercased()).\(titleID)"
    }

    /// `--prepare-xcode` names schemes after the game and title ID, not the DmIOS target.
    /// Read the generated shared scheme files without invoking Xcode or contacting a service.
    public static func preparedScheme(in projectURL: URL) throws -> String {
        let directory = projectURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        let matching = entries.filter { url in
            guard url.pathExtension == "xcscheme",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { return false }
            let target = SchemeTargetParser()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = target
            return parser.parse() && target.buildsDmIOS
        }
        guard !matching.isEmpty else { throw DeviceServiceError.missingPreparedScheme }
        guard matching.count == 1 else { throw DeviceServiceError.ambiguousPreparedScheme }
        return matching[0].deletingPathExtension().lastPathComponent
    }

    /// Invoked only by the explicit Install action; Xcode manages signing using its existing account.
    public static func buildAndInstall(_ plan: DeploymentPlan, using runner: ProcessRunner,
                                       onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> URL {
        let build = try await runner.run(plan.buildCommand, onLine: onLine)
        guard build.exitCode == 0 else { throw DeviceServiceError.commandFailed(String(build.output.suffix(6000))) }
        guard FileManager.default.fileExists(atPath: plan.signedApplicationURL.appendingPathComponent("Info.plist").path) else {
            throw DeviceServiceError.missingSignedApplication
        }
        let verify = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", plan.signedApplicationURL.path],
            environment: ToolEnvironment.values, redactedDescription: "codesign --verify prepared application"), onLine: onLine)
        guard verify.exitCode == 0 else { throw DeviceServiceError.commandFailed(String(verify.output.suffix(4000))) }
        let install = try await runner.run(plan.installCommand, onLine: onLine)
        guard install.exitCode == 0 else { throw DeviceServiceError.commandFailed(String(install.output.suffix(6000))) }
        return plan.signedApplicationURL
    }

    /// Supports both the legacy CoreDevice JSON and Xcode 27's replacement `properties` schema.
    public static func parseDevices(_ data: Data) throws -> [AppleDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["devices"] as? [[String: Any]] else {
            throw DeviceServiceError.invalidResponse
        }
        return entries.compactMap { entry -> AppleDevice? in
            let properties = entry["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any]
                ?? entry["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any]
                ?? entry["connectionProperties"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any]
                ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            let software = properties["software"] as? [String: Any] ?? [:]
            let legacyDevice = entry["deviceProperties"] as? [String: Any] ?? [:]

            let reality = string(hardware["reality"]).lowercased()
            let visibility = string(state["visibilityClass"] ?? entry["visibilityClass"]).lowercased()
            guard reality != "simulated", reality != "virtual", visibility != "simulators" else { return nil }
            let platform = string(hardware["platform"]).lowercased()
            let deviceType = string(hardware["deviceType"]).lowercased()
            guard ["ios", "ipados"].contains(platform) || ["iphone", "ipad"].contains(deviceType) else { return nil }
            guard let id = entry["identifier"] as? String, !id.isEmpty else { return nil }

            let osValue = software["osVersionNumber"]
            let version: String
            if let object = osValue as? [String: Any] {
                version = string(object["stringValue"])
            } else {
                version = string(osValue ?? legacyDevice["osVersionNumber"])
            }
            let pairing = string(connection["pairingState"]).lowercased()
            let connectionState = string(connection["state"] ?? connection["tunnelState"]).lowercased()
            let developerModeValue = state["developerModeStatus"] ?? software["developerModeStatus"]
                ?? legacyDevice["developerModeStatus"]
            let developerMode: Bool?
            if let bool = developerModeValue as? Bool {
                developerMode = bool
            } else if let status = developerModeValue as? [String: Any] {
                // Xcode 27 encodes this enum as {"enabled":{"mode":1}},
                // whereas earlier releases returned the string "enabled".
                if status["enabled"] != nil && status["disabled"] == nil {
                    developerMode = true
                } else if status["disabled"] != nil && status["enabled"] == nil {
                    developerMode = false
                } else {
                    developerMode = nil
                }
            } else {
                switch string(developerModeValue).lowercased() {
                case "enabled": developerMode = true
                case "disabled": developerMode = false
                default: developerMode = nil
                }
            }
            let name = string(state["name"] ?? legacyDevice["name"])
            let model = string(hardware["marketingName"] ?? hardware["productType"])
            return AppleDevice(id: id, udid: string(hardware["udid"]).isEmpty ? id : string(hardware["udid"]),
                               name: name.isEmpty ? model : name, model: model, osVersion: version,
                               transport: string(connection["transportType"]), isPaired: pairing == "paired",
                               isConnected: ["connected", "available"].contains(connectionState),
                               developerModeEnabled: developerMode)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }
}

private final class SchemeTargetParser: NSObject, XMLParserDelegate {
    private var inBuildAction = false
    private(set) var buildsDmIOS = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "BuildAction" { inBuildAction = true }
        if inBuildAction && elementName == "BuildableReference",
           attributeDict["BlueprintName"] == "DmIOS",
           attributeDict["BuildableName"] == "DmIOS.app" {
            buildsDmIOS = true
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "BuildAction" { inBuildAction = false }
    }
}

public struct DeploymentPlan: Sendable {
    public let buildCommand: ProcessCommand
    public let installCommand: ProcessCommand
    public let signedApplicationURL: URL

    public init(buildCommand: ProcessCommand, installCommand: ProcessCommand, signedApplicationURL: URL) {
        self.buildCommand = buildCommand
        self.installCommand = installCommand
        self.signedApplicationURL = signedApplicationURL
    }
}
