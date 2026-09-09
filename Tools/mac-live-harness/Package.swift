// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "macharness", platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../..")],
  targets: [.executableTarget(name: "macharness", dependencies: [.product(name: "SwiftAgentKitMac", package: "SwiftAgentKit")])])
