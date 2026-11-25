// swift-tools-version:5.9
// Local build loop for DuloCore; XCTest tests run through the Xcode project/CI.
// CI runs the same tests on an iOS simulator via the XcodeGen project.
import PackageDescription

let package = Package(
    name: "Dulo",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DuloCore",
            path: "Sources",
            sources: ["Data", "Feed/ShuffledVideoQueue.swift", "Feed/PrewarmPolicy.swift"]
        ),
        .testTarget(
            name: "DuloCoreTests",
            dependencies: ["DuloCore"],
            path: "Tests"
        ),
    ]
)
