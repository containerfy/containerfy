// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Containerfy",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
    ],
    targets: [
        .target(
            name: "ContainerfyCore",
            dependencies: ["Yams"],
            path: "Sources/ContainerfyCore",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "Containerfy",
            dependencies: ["ContainerfyCore"],
            path: "Sources/Containerfy"
        ),
        .testTarget(
            name: "ContainerfyTests",
            dependencies: ["ContainerfyCore", "Yams"],
            path: "Tests/ContainerfyTests"
        ),
    ]
)
