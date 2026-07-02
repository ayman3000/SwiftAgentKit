// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftAgentKitExamplesRunner",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ExamplesRunner", targets: ["ExamplesRunner"])],
    dependencies: [
        .package(path: "../../../SwiftAgentKit"),
        .package(url: "https://github.com/ayman3000/LLMProviderKit.git", from: "0.1.0-alpha.1"),
    ],
    targets: [
        .executableTarget(
            name: "ExamplesRunner",
            dependencies: [
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitOllama", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitGemini", package: "LLMProviderKit"),
            ]
        ),
    ]
)
