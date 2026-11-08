// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TVMirror",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TVMirror",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
