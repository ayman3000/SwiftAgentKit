// swift-tools-version: 6.2
import CompilerPluginSupport
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
        .package(url: "https://github.com/ayman3000/LLMProviderKit.git", from: "0.1.0-alpha.4"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        // Macro implementation (SwiftSyntax-based, compile-time code gen)
        .macro(
            name: "SwiftAgentKitMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        // Main library — depends on the macro target
        .target(
            name: "SwiftAgentKit",
            dependencies: [
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
                "SwiftAgentKitMacros",
            ]
        ),

        // Tests
        .testTarget(
            name: "SwiftAgentKitTests",
            dependencies: [
                "SwiftAgentKit",
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
            ]
        ),
    ]
)
