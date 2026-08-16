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
        .library(name: "SwiftAgentKitTools", targets: ["SwiftAgentKitTools"]),
        .library(name: "SwiftAgentKitMCP", targets: ["SwiftAgentKitMCP"]),
        .library(name: "SwiftAgentKitReplay", targets: ["SwiftAgentKitReplay"]),
        .library(name: "SwiftAgentKitSimulator", targets: ["SwiftAgentKitSimulator"]),
        .library(name: "SwiftAgentKitMac", targets: ["SwiftAgentKitMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ayman3000/LLMProviderKit.git", from: "0.1.0-alpha.14"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
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
                // Used only by the gated live-model smoke test (real Ollama provider).
                .product(name: "LLMProviderKitOllama", package: "LLMProviderKit"),
            ]
        ),

        // Built-in native tools — optional product (filesystem, shell, PDF).
        // Foundation-only core; shell is macOS-gated, PDF is PDFKit-gated.
        .target(
            name: "SwiftAgentKitTools",
            dependencies: ["SwiftAgentKit"]
        ),

        // Native-tools tests
        .testTarget(
            name: "SwiftAgentKitToolsTests",
            dependencies: [
                "SwiftAgentKitTools",
                "SwiftAgentKit",
                // Used only by the gated live-model test (real Ollama provider).
                .product(name: "LLMProviderKitOllama", package: "LLMProviderKit"),
            ]
        ),

        // MCP integration — optional product, depends on the MCP Swift SDK
        .target(
            name: "SwiftAgentKitMCP",
            dependencies: [
                "SwiftAgentKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        // MCP tests
        .testTarget(
            name: "SwiftAgentKitMCPTests",
            dependencies: [
                "SwiftAgentKitMCP",
                "SwiftAgentKit",
            ]
        ),

        // Deterministic offline replay/eval harness for the runtime.
        .target(
            name: "SwiftAgentKitReplay",
            dependencies: [
                "SwiftAgentKit",
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
            ]
        ),

        // Replay-harness tests + the four seed regression scenarios. Depends on the
        // concrete providers whose wire encoding the seeds snapshot (Gemini, Anthropic).
        .testTarget(
            name: "SwiftAgentKitReplayTests",
            dependencies: [
                "SwiftAgentKitReplay",
                "SwiftAgentKit",
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitGemini", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitAnthropic", package: "LLMProviderKit"),
            ]
        ),

        // Native iOS-simulator driving — persistent XCUITest driver + sim_* tools.
        // Host-side code is macOS-gated; the driver project ships as a resource.
        .target(
            name: "SwiftAgentKitSimulator",
            dependencies: ["SwiftAgentKit"],
            resources: [.copy("Resources/SimDriverProject")]
        ),
        .testTarget(
            name: "SwiftAgentKitSimulatorTests",
            dependencies: ["SwiftAgentKitSimulator", "SwiftAgentKit"]
        ),

        // Native macOS app driving via the Accessibility APIs. macOS-gated.
        .target(
            name: "SwiftAgentKitMac",
            dependencies: ["SwiftAgentKit"]
        ),
        .testTarget(
            name: "SwiftAgentKitMacTests",
            dependencies: ["SwiftAgentKitMac", "SwiftAgentKit"]
        ),

        // Examples runner — `swift run Runner 01`, `swift run Runner 02`, etc.
        .executableTarget(
            name: "Runner",
            dependencies: [
                "SwiftAgentKit",
                "SwiftAgentKitMCP",
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitOllama", package: "LLMProviderKit"),
            ],
            path: "Examples/Runner"
        ),
    ]
)
