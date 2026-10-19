// swift-tools-version:6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed, SwiftPM doesn't hand the Swift Testing
// macro plugin to every compile step, so `swift test` fails with
// "plugin for module 'TestingMacros' not found". Point at it explicitly when present.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] =
    FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
    : []

let package = Package(
    name: "RootBeer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RootBeer", targets: ["RootBeer"]),
    ],
    targets: [
        .target(name: "RootBeerCore"),
        .executableTarget(name: "RootBeer", dependencies: ["RootBeerCore"]),
        .testTarget(
            name: "RootBeerTests",
            dependencies: ["RootBeerCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings
        ),
    ]
)
