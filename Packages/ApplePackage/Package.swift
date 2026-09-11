// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// CI produces this artifact from pinned sources. Offline tests inject a signer
// and do not need to download or link the native runtime.
let runtimePath = "Artifacts/ApplePackageSAP.xcframework"
let hasRuntime = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(runtimePath).path)
let runtimeDependencies: [Target.Dependency] = hasRuntime ? [.target(name: "CApplePackageSAP")] : []
let runtimeTargets: [Target] = hasRuntime ? [.binaryTarget(name: "CApplePackageSAP", path: runtimePath)] : []
let hasBundledAssets = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/ApplePackage/Resources/SAPAssets.zip").path)
let sapResources: [Resource] = [.copy("Resources/SAPNotices")] + (hasBundledAssets ? [.copy("Resources/SAPAssets.zip")] : [])

let package = Package(
    name: "ApplePackage",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v14),
        .macOS(.v11),
    ],
    products: [
        .library(name: "ApplePackage", targets: ["ApplePackage"]),
        .executable(name: "ApplePackageTool", targets: ["ApplePackageTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0")),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.31.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(name: "ApplePackageTool", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .target(name: "ApplePackage"),
        ]),
        .target(name: "ApplePackage", dependencies: runtimeDependencies + [
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "Collections", package: "swift-collections"),
            .product(name: "Logging", package: "swift-log"),
        ], resources: sapResources,
           swiftSettings: hasBundledAssets ? [.define("ASSPP_BUNDLED_SAP_ASSETS")] : [],
           linkerSettings: hasRuntime ? [.linkedFramework("CoreFoundation"), .linkedLibrary("resolv")] : []),
        .testTarget(name: "ApplePackageTests", dependencies: ["ApplePackage"]),
    ] + runtimeTargets
)
