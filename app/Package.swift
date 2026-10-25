// swift-tools-version: 6.2
// NxNative Converter: a SwiftUI app over scripts/build_ipa_from_nsp.py --platform mac-app (see README.md).
import PackageDescription

let package = Package(
    name: "NxNativeConverter",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "NxNativeConverter",
            path: "Sources/NxNativeConverter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
