// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoxingBuffalo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BoxingBuffalo", targets: ["BoxingBuffalo"]),
        .library(name: "FatXCore", targets: ["FatXCore"]),
    ],
    targets: [
        .target(
            name: "FatXCore",
            path: "Sources/FatXCore"
        ),
        .executableTarget(
            name: "BoxingBuffalo",
            dependencies: ["FatXCore"],
            path: "Sources/BoxingBuffalo"
        ),
        .executableTarget(
            name: "fatxcheck",
            dependencies: ["FatXCore"],
            path: "Sources/fatxcheck"
        ),
    ]
)
