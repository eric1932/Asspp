// swift-tools-version: 5.9

import Foundation
import PackageDescription

// AssppAttest.xcframework is not in the repository. The embedded-runtime
// workflow builds it and the iOS build copies it into Artifacts/. Without it
// this package still builds, and EmbeddedAttestationRuntime.isAvailable is false.
let runtimePath = "Artifacts/AssppAttest.xcframework"
let hasRuntime = FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + runtimePath)

var targets: [Target] = [
    .target(
        name: "AssppEmbeddedAttestation",
        dependencies: hasRuntime
            ? [.target(name: "AssppAttest", condition: .when(platforms: [.iOS]))]
            : []
    ),
]

if hasRuntime {
    targets.append(.binaryTarget(name: "AssppAttest", path: runtimePath))
}

let package = Package(
    name: "AssppEmbeddedAttestation",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "AssppEmbeddedAttestation", targets: ["AssppEmbeddedAttestation"]),
    ],
    targets: targets
)
