// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "v2s",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift",
            exact: "1.1.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "v2s",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/V2SApp",
            resources: [
                .copy("Resources/AppIcon/AppIcon-512.png"),
                .copy("Resources/SileroVAD.mlpackage"),
                .copy("Resources/TWPhrases.txt"),
                .copy("Resources/BreezeASR26Tokenizer.json"),
                .copy("Resources/BreezeASR26TokenizerConfig.json"),
            ]
        ),
        .testTarget(
            name: "v2sTests",
            dependencies: ["v2s"],
            path: "Tests/V2STests"
        ),
    ]
)
