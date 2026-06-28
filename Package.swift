// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftAgentKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftAgentKit", targets: ["SwiftAgentKit"]),
    ],
    dependencies: [
        .package(path: "../LLMProviderKit"),
    ],
    targets: [
        .target(
            name: "SwiftAgentKit",
            dependencies: [
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
            ]
        ),
        .testTarget(
            name: "SwiftAgentKitTests",
            dependencies: [
                "SwiftAgentKit",
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
            ]
        ),
    ]
)