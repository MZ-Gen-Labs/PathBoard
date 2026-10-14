// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PathBoard", platforms: [.macOS("27.0")], products: [
    .library(name: "PathBoardCore", targets: ["PathBoardCore"]),
    .executable(name: "PathBoard", targets: ["PathBoard"])
], targets: [
    .target(name: "PathBoardCore"),
    .executableTarget(name: "PathBoard", dependencies: ["PathBoardCore"]),
    .testTarget(name: "PathBoardCoreTests", dependencies: ["PathBoardCore"])
], swiftLanguageModes: [.v5])
