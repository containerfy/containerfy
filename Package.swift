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
        .executableTarget(
            name: "Containerfy",
            dependencies: ["Yams"],
            path: "Sources/Containerfy",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
