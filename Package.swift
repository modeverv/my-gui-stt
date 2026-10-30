// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalSpeechSTT",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "LocalSpeechSTT", targets: ["LocalSpeechSTT"])
    ],
    targets: [
        .executableTarget(
            name: "LocalSpeechSTT",
            path: "Sources/LocalSpeechSTT",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
