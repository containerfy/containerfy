// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AppPod",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AppPod",
            path: "Sources/AppPod",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        )
    ]
)
