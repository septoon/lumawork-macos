// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EngineerCore",
    platforms: [.macOS("15.6.1")],
    products: [.library(name: "EngineerCore", targets: ["EngineerCore"])],
    targets: [
        .target(name: "EngineerCore"),
        .testTarget(name: "EngineerCoreTests", dependencies: ["EngineerCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
