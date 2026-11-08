// swift-tools-version:5.10
import PackageDescription

let targets: [Target] = [
    .target(name: "COilFind", publicHeadersPath: "include"),
    .target(name: "OilFindCore", dependencies: ["COilFind"]),
    .target(name: "OilFindApp", dependencies: ["OilFindCore"], resources: [.copy("Resources")]),
    .target(name: "OilFindPro", dependencies: ["OilFindApp", "OilFindCore"], path: "Pro/Sources/OilFindPro",
            resources: [.copy("Resources")]),
    .executableTarget(name: "OilFind", dependencies: ["OilFindApp", "OilFindPro"]),
    .executableTarget(name: "oilfind-cli", dependencies: ["OilFindCore"]),
    .testTarget(name: "OilFindCoreTests", dependencies: ["OilFindCore", "COilFind"]),
    .testTarget(name: "OilFindUITests", dependencies: ["OilFindApp", "OilFindCore"]),
    .testTarget(name: "OilFindProTests", dependencies: ["OilFindPro", "OilFindApp", "OilFindCore"], path: "Pro/Tests/OilFindProTests")
]

let package = Package(
    name: "OilFind",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OilFindCore", targets: ["OilFindCore"]), .library(name: "OilFindApp", targets: ["OilFindApp"]), .executable(name: "oilfind-cli", targets: ["oilfind-cli"])],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
