// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TVMirror",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CGVirtualDisplayPrivate", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(
            name: "TVMirror",
            dependencies: ["CGVirtualDisplayPrivate"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
