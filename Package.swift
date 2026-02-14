// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AppPod",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
    ],
    targets: [
        .executableTarget(
            name: "AppPod",
            dependencies: ["Yams"],
            path: "Sources/AppPod",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
