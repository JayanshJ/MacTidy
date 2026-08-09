// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Command Line Tools (no full Xcode) ship Swift Testing outside the
// default search paths; point the test target at it so plain `swift test`
// works. No-op when full Xcode is installed.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let usingCLT = FileManager.default.fileExists(atPath: cltFrameworks)

let testSwiftSettings: [SwiftSetting] = usingCLT
    ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testLinkerSettings: [LinkerSetting] = usingCLT
    ? [.unsafeFlags([
        "-F", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltTestingLibs,
    ])] : []

let package = Package(
    name: "MacTidy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CoreKit", targets: ["CoreKit"]),
        .executable(name: "MacTidy", targets: ["MacTidyApp"]),
    ],
    targets: [
        .target(name: "CoreKit"),
        .executableTarget(
            name: "MacTidyApp",
            dependencies: ["CoreKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["CoreKit"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
